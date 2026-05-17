//
//  CanonicalGraphFetcher.swift
//  PowderMeet
//
//  Single client entrypoint for the server-authoritative resort graph
//  pipeline. Replaces the on-device build chain
//  (GraphBuilder.buildGraph → CuratedResortLoader.applyOverlay →
//  ResortDataEnricher.enrich) with a fetch of an immutable, frozen
//  graph blob produced by the build-resort-graph edge function.
//
//  Lifecycle:
//    1. cached = GraphCacheManager.load(resortId)
//    2. resp = await get-resort-graph(resortId, cached?.manifestVersion)
//    3. if resp.status == .cacheValid:
//         apply(liveStatus from resp.liveStatusUrl) over cached
//    4. else if resp.status == .fetch:
//         download(resp.blobUrl); verify sha256; decode; persist
//    5. else if resp.status == .notBuilt:
//         caller drives build-resort-graph (out of scope here; surfaced
//         as a typed error)
//
//  Cache durability: GraphCacheManager keys by (resortId,
//  manifestVersion). The disk entry remains valid indefinitely until a
//  server-side manifest_version bump on next foreground forces a refresh.
//
//  Feature-gated: set `useCanonicalGraphFetch = true` to route through
//  this path. Default off until per-resort canonical manifests exist.
//

import Foundation
import CryptoKit
import Compression
import Supabase  // needed for Session.accessToken in invokeEdgeFunction

// MARK: - Public API

@MainActor
final class CanonicalGraphFetcher {

    static let shared = CanonicalGraphFetcher()

    /// Master switch. When false, callers (ResortDataManager) take the
    /// legacy path through GraphBuilder + CuratedResortLoader. Flip
    /// per-resort or globally once canonical manifests exist for that
    /// resort.
    var useCanonicalGraphFetch: Bool = false

    /// Per-resort opt-in. Populated automatically by
    /// `discoverEnabledResorts()` from `current_resort_canonical_manifest`
    /// at cold launch — every resort with an applied manifest is
    /// considered "online" for the canonical path. Manual additions
    /// (e.g. for testing) are also honored.
    var enabledResortIds: Set<String> = []

    /// Returns true if the canonical path should be used for this resort.
    func isEnabled(for resortId: String) -> Bool {
        useCanonicalGraphFetch || enabledResortIds.contains(resortId)
    }

    /// Hits `current_resort_canonical_manifest` (anon read via RLS) and
    /// populates `enabledResortIds` with every resort that has an
    /// applied manifest. Called from `SupabaseManager.initialize()` on
    /// cold launch. As you run `canonical_ingest apply` for new resorts,
    /// the next app launch picks them up automatically — no client code
    /// change, no manual flag flip.
    func discoverEnabledResorts() async {
        guard let url = URL(string: "\(SupabaseManager.projectURL)/rest/v1/current_resort_canonical_manifest?select=resort_id") else {
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(SupabaseManager.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseManager.anonKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct Row: Decodable { let resort_id: String }
            let rows = try JSONDecoder().decode([Row].self, from: data)
            let ids = Set(rows.map { $0.resort_id })
            self.enabledResortIds = ids
            print("[CanonicalGraphFetcher] discovered \(ids.count) canonical-enabled resort(s): \(ids.sorted().joined(separator: ", "))")
        } catch {
            // Failure is silent — the canonical path stays off for the
            // session. The legacy pipeline serves every resort, no UX
            // impact. Next launch retries.
            print("[CanonicalGraphFetcher] discoverEnabledResorts failed: \(error.localizedDescription)")
        }
    }

    /// Fetch (or refresh) the canonical graph for `resortId`. Blocks
    /// until ready. If the manifest exists but no graph blob has been
    /// built yet, transparently triggers `build-resort-graph` once and
    /// re-fetches. Throws `FetchError` on terminal failures.
    func fetch(resortId: String) async throws -> CanonicalGraphResult {
        // Up to 2 attempts: first attempt may return notBuilt; if so we
        // trigger a build, then retry. After 2 attempts give up.
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                return try await fetchOnce(resortId: resortId)
            } catch FetchError.notBuilt(let v) where attempt == 0 {
                // Manifest exists but no blob yet. Trigger the build and
                // retry. build-resort-graph is synchronous so by the time
                // it returns the blob is in place.
                try await triggerBuild(resortId: resortId)
                lastError = FetchError.notBuilt(manifestVersion: v)
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? FetchError.invalidServerResponse("fetch retry exhausted")
    }

    private func fetchOnce(resortId: String) async throws -> CanonicalGraphResult {
        let cached = await CanonicalGraphCache.load(resortId: resortId)
        let response = try await callGetResortGraph(
            resortId: resortId,
            cachedManifestVersion: cached?.manifestVersion
        )

        switch response.status {
        case .cacheValid:
            guard let cached else {
                throw FetchError.cacheClaimedValidButMissing
            }
            let liveStatus = try? await fetchLiveStatus(url: response.liveStatusUrl)
            return CanonicalGraphResult(
                graph: cached.graph,
                manifestVersion: cached.manifestVersion,
                snapshotDate: response.snapshotDate ?? cached.snapshotDate,
                liveStatus: liveStatus,
                source: CanonicalGraphResult.Source.cache
            )

        case .fetch:
            guard let blobUrl = response.blobUrl,
                  let manifestVersion = response.manifestVersion,
                  let sha256 = response.sha256 else {
                throw FetchError.invalidServerResponse("fetch status missing required fields")
            }
            let graph = try await downloadAndDecode(
                blobUrl: blobUrl,
                expectedSha256: sha256
            )
            await CanonicalGraphCache.save(
                resortId: resortId,
                graph: graph,
                manifestVersion: manifestVersion,
                snapshotDate: response.snapshotDate
            )
            let liveStatus = try? await fetchLiveStatus(url: response.liveStatusUrl)
            return CanonicalGraphResult(
                graph: graph,
                manifestVersion: manifestVersion,
                snapshotDate: response.snapshotDate,
                liveStatus: liveStatus,
                source: CanonicalGraphResult.Source.freshDownload
            )

        case .notBuilt:
            throw FetchError.notBuilt(
                manifestVersion: response.manifestVersion ?? response.currentManifestVersion ?? 0
            )
        }
    }

    /// Fetch a SPECIFIC manifest version. Used by the meet-request
    /// receiver path: when an inbound meet stamps `manifest_version =
    /// N` and our local graph is at M, we call this with N to load
    /// the exact graph the sender solved against. Server retains every
    /// historical manifest so this always succeeds for valid versions.
    func fetch(resortId: String, manifestVersion: Int) async throws -> CanonicalGraphResult {
        let response = try await callGetResortGraph(
            resortId: resortId,
            cachedManifestVersion: nil,
            forceManifestVersion: manifestVersion
        )
        guard response.status == .fetch,
              let blobUrl = response.blobUrl,
              let sha256 = response.sha256 else {
            throw FetchError.invalidServerResponse(
                "force-fetch v\(manifestVersion) returned \(response.status)"
            )
        }
        let graph = try await downloadAndDecode(
            blobUrl: blobUrl,
            expectedSha256: sha256
        )
        // Don't overwrite the cache with a stale version — only the
        // current version goes to disk. Cross-version meets are
        // session-scoped.
        return CanonicalGraphResult(
            graph: graph,
            manifestVersion: manifestVersion,
            snapshotDate: response.snapshotDate,
            liveStatus: Optional<LiveStatusBlob>.none,
            source: CanonicalGraphResult.Source.crossVersionFetch
        )
    }

    // MARK: - Networking

    private func callGetResortGraph(
        resortId: String,
        cachedManifestVersion: Int?,
        forceManifestVersion: Int? = nil
    ) async throws -> GetResortGraphResponse {
        var body: [String: Any] = ["resort_id": resortId]
        if let cachedManifestVersion {
            body["cached_manifest_version"] = cachedManifestVersion
        }
        if let forceManifestVersion {
            body["manifest_version"] = forceManifestVersion
        }
        let data = try await invokeEdgeFunction(name: "get-resort-graph", body: body)
        do {
            return try JSONDecoder().decode(GetResortGraphResponse.self, from: data)
        } catch {
            throw FetchError.invalidServerResponse("decode get-resort-graph: \(error.localizedDescription)")
        }
    }

    private func downloadAndDecode(
        blobUrl: URL,
        expectedSha256: String
    ) async throws -> MountainGraph {
        let (gzData, response) = try await URLSession.shared.data(from: blobUrl)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.blobDownloadFailed(status: http.statusCode)
        }
        let actualSha = gzData.sha256Hex
        guard actualSha == expectedSha256 else {
            throw FetchError.sha256Mismatch(expected: expectedSha256, actual: actualSha)
        }
        let jsonData = try gzData.gunzipped()
        do {
            return try JSONDecoder().decode(MountainGraph.self, from: jsonData)
        } catch {
            throw FetchError.invalidGraphBlob(error.localizedDescription)
        }
    }

    private func fetchLiveStatus(url: URL?) async throws -> LiveStatusBlob? {
        guard let url else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return nil // best-effort
        }
        return try? JSONDecoder().decode(LiveStatusBlob.self, from: data)
    }

    /// Mirrors `ResortDataManager.invokeSnapshotFunction`: raw URLRequest
    /// against `<projectURL>/functions/v1/<name>` with the project anon
    /// key in `apikey` and the user's session bearer in `Authorization`.
    /// We don't go through the Supabase Swift SDK's `functions.invoke`
    /// because the rest of the app doesn't either — this matches the
    /// proven pattern and avoids a second auth surface.
    private func invokeEdgeFunction(name: String, body: [String: Any]) async throws -> Data {
        guard let functionURL = URL(string: "\(SupabaseManager.projectURL)/functions/v1/\(name)") else {
            throw FetchError.invalidServerResponse("bad SupabaseURL — cannot build \(name) URL")
        }
        var request = URLRequest(url: functionURL, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseManager.anonKey, forHTTPHeaderField: "apikey")
        let token = SupabaseManager.shared.currentSession?.accessToken
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            // Fall back to anon. get-resort-graph has verify_jwt=true but
            // the anon JWT counts.
            request.setValue("Bearer \(SupabaseManager.anonKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidServerResponse("no HTTP response")
        }
        // 200 = OK. 404 = no manifest for resort_id.
        if http.statusCode == 404 {
            throw FetchError.invalidServerResponse("no canonical manifest for this resort")
        }
        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.invalidServerResponse("HTTP \(http.statusCode): \(text.prefix(200))")
        }
        return data
    }

    /// Triggers `build-resort-graph` for `resortId` and returns when the
    /// blob is built. Used when `fetch` returns `notBuilt`.
    func triggerBuild(resortId: String) async throws {
        let body: [String: Any] = ["resort_id": resortId]
        _ = try await invokeEdgeFunction(name: "build-resort-graph", body: body)
    }
}

// MARK: - Result types

struct CanonicalGraphResult: Sendable {
    let graph: MountainGraph
    let manifestVersion: Int
    /// Snapshot date the graph blob was built against. Used as the
    /// `graphSnapshotDate` stamp on outgoing meet requests so the
    /// existing on-device drift check still has a value (the new
    /// `manifest_version` stamp is the authoritative determinism
    /// signal — `graphSnapshotDate` is kept for backwards compat
    /// while v1 senders coexist with v2).
    let snapshotDate: String?
    let liveStatus: LiveStatusBlob?
    let source: Source

    enum Source: Sendable {
        case cache               // server confirmed our cached version is current
        case freshDownload       // server returned a new blob, we downloaded it
        case crossVersionFetch   // pinned-version fetch for an inbound meet
    }
}

// MARK: - Wire types

private struct GetResortGraphResponse: Decodable {
    let status: Status
    let manifestVersion: Int?
    let currentManifestVersion: Int?
    let blobUrl: URL?
    let sha256: String?
    let snapshotDate: String?
    let liveStatusUrl: URL?

    enum Status: String, Decodable {
        case cacheValid = "cache_valid"
        case fetch
        case notBuilt = "not_built"
    }

    enum CodingKeys: String, CodingKey {
        case status
        case manifestVersion = "manifest_version"
        case currentManifestVersion = "current_manifest_version"
        case blobUrl = "blob_url"
        case sha256
        case snapshotDate = "snapshot_date"
        case liveStatusUrl = "live_status_url"
    }
}

struct LiveStatusBlob: Decodable, Sendable {
    let resortId: String
    let builtAt: String
    let expiresAt: String
    let lifts: [String: LiveStatusEntry]
    let trails: [String: LiveStatusEntry]

    enum CodingKeys: String, CodingKey {
        case resortId = "resort_id"
        case builtAt = "built_at"
        case expiresAt = "expires_at"
        case lifts, trails
    }
}

struct LiveStatusEntry: Decodable, Sendable {
    let isOpen: Bool
    let waitMinutes: Double?

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case waitMinutes = "wait_minutes"
    }
}

// MARK: - Errors

enum FetchError: LocalizedError {
    case cacheClaimedValidButMissing
    case invalidServerResponse(String)
    case notBuilt(manifestVersion: Int)
    case blobDownloadFailed(status: Int)
    case sha256Mismatch(expected: String, actual: String)
    case invalidGraphBlob(String)
    case notWiredToSupabaseClient

    var errorDescription: String? {
        switch self {
        case .cacheClaimedValidButMissing:
            return "server said cache is valid but no local cache exists"
        case .invalidServerResponse(let msg):
            return "invalid server response: \(msg)"
        case .notBuilt(let v):
            return "graph blob v\(v) not yet built — call build-resort-graph"
        case .blobDownloadFailed(let s):
            return "blob download failed: HTTP \(s)"
        case .sha256Mismatch(let e, let a):
            return "blob sha256 mismatch (expected \(e), actual \(a))"
        case .invalidGraphBlob(let msg):
            return "invalid graph blob: \(msg)"
        case .notWiredToSupabaseClient:
            return "edge-function invocation not yet wired (see TODO in invokeEdgeFunction)"
        }
    }
}

// MARK: - Disk cache (manifest-version-keyed)

private enum CanonicalGraphCache {

    static let graphVersion = "v8"  // must match server GRAPH_VERSION

    /// Cache filename format: `{resortId}-m{manifestVersion}-{snapshotDate}-{graphVersion}.json`
    /// where `snapshotDate` is `YYYY-MM-DD` or the literal string `unknown`
    /// when the server didn't supply one (legacy paths). Encoding both
    /// fields in the filename avoids a sidecar metadata file.

    static func load(resortId: String) async -> Cached? {
        let path = cachePath(resortId: resortId)
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let parsed = parseFilename(path: path, resortId: resortId) else { return nil }
        do {
            let graph = try JSONDecoder().decode(MountainGraph.self, from: data)
            return Cached(graph: graph, manifestVersion: parsed.manifestVersion, snapshotDate: parsed.snapshotDate)
        } catch {
            return nil
        }
    }

    static func save(resortId: String, graph: MountainGraph, manifestVersion: Int, snapshotDate: String?) async {
        do {
            removeAllVersions(resortId: resortId)
            let path = cachePath(resortId: resortId, manifestVersion: manifestVersion, snapshotDate: snapshotDate ?? "unknown")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(graph)
            try data.write(to: path, options: Data.WritingOptions.atomic)
        } catch {
            // Cache miss is recoverable.
        }
    }

    private static func cachePath(resortId: String, manifestVersion: Int? = nil, snapshotDate: String = "unknown") -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = baseURL.appendingPathComponent("CanonicalResortGraphs", isDirectory: true)
        if let manifestVersion {
            return dir.appendingPathComponent("\(resortId)-m\(manifestVersion)-\(snapshotDate)-\(graphVersion).json")
        }
        // Lookup mode: find the (single) extant version for this resort.
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("\(resortId)-m") && name.hasSuffix("-\(graphVersion).json") {
                return url
            }
        }
        return dir.appendingPathComponent("\(resortId)-m0-unknown-\(graphVersion).json")
    }

    /// Parses `{resortId}-m{manifestVersion}-{snapshotDate}-{graphVersion}.json`
    /// from a URL. Returns nil if the filename doesn't match the expected pattern.
    private static func parseFilename(path: URL, resortId: String) -> (manifestVersion: Int, snapshotDate: String)? {
        let name = path.lastPathComponent
        let prefix = "\(resortId)-m"
        let suffix = "-\(graphVersion).json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let middle = String(name[start..<end])
        // middle is "{manifestVersion}-{snapshotDate}", e.g. "3-2026-04-28"
        // or "1-unknown". manifestVersion is the first dash-prefix number.
        guard let firstDash = middle.firstIndex(of: "-") else { return nil }
        let versionStr = String(middle[middle.startIndex..<firstDash])
        let snapshotStr = String(middle[middle.index(after: firstDash)..<middle.endIndex])
        guard let version = Int(versionStr) else { return nil }
        return (manifestVersion: version, snapshotDate: snapshotStr == "unknown" ? "" : snapshotStr)
    }

    private static func removeAllVersions(resortId: String) {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = baseURL.appendingPathComponent("CanonicalResortGraphs", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            if url.lastPathComponent.hasPrefix("\(resortId)-m") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    struct Cached: Sendable {
        let graph: MountainGraph
        let manifestVersion: Int
        /// `YYYY-MM-DD` or empty string when not known (legacy/unknown).
        let snapshotDate: String
    }
}

// MARK: - Crypto / gzip helpers

private extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Decompress a raw-deflate (zlib) blob using the Compression
    /// framework. Apple's `COMPRESSION_ZLIB` consumes raw deflate (RFC
    /// 1951), NOT gzip-wrapped (RFC 1952). The build-resort-graph edge
    /// function MUST emit raw deflate (e.g. `fflate.deflateSync`,
    /// not `gzipSync`) for this to round-trip.
    func gunzipped() throws -> Data {
        let count = self.count
        // 16x expansion is comfortable for ski-graph payloads (~300 KB
        // compressed → ~2 MB JSON on Whistler-scale resorts).
        let dstCapacity = Swift.max(count * 16, 1 << 20)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }
        let written = self.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return compression_decode_buffer(
                dst, dstCapacity,
                base.assumingMemoryBound(to: UInt8.self), count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0 else {
            throw NSError(domain: "CanonicalGraphFetcher", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "compression_decode_buffer returned 0 (verify server emits raw deflate, not gzip)",
            ])
        }
        return Data(bytes: dst, count: written)
    }
}
