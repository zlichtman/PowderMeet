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
//    1. cached = MountainRepository.loadCanonical(resortId)
//    2. resp = await get-resort-graph(resortId, cached?.manifestVersion)
//    3. if resp.status == .cacheValid:
//         decode MountainStatus from resp.liveStatusUrl beside cached
//    4. else if resp.status == .fetch:
//         download(resp.blobUrl); verify sha256; decode; persist
//    5. A resort without an explicitly published graph fails closed; builds
//       and publication are operator-only workflow steps.
//
//  Cache durability: MountainRepository keys by resort + exact dataset
//  identity (manifest, graph version, content SHA). Historical versions are
//  retained for exact meet-plan activation.
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

    /// Canonical is the default for every resort. A resort without an applied
    /// manifest may use the frozen legacy snapshot as a non-authoritative
    /// compatibility preview, but never a live device-specific Overpass build.
    var useCanonicalGraphFetch: Bool = true

    /// Per-resort opt-in. Populated automatically by
    /// `discoverEnabledResorts()` from `current_resort_canonical_manifest`
    /// at cold launch — every resort with a published dataset is
    /// considered "online" for the canonical path. Manual additions
    /// (e.g. for testing) are also honored.
    var enabledResortIds: Set<String> = []

    /// Returns true if the canonical path should be used for this resort.
    func isEnabled(for resortId: String) -> Bool {
        useCanonicalGraphFetch || enabledResortIds.contains(resortId)
    }

    /// Hits `current_resort_canonical_manifest` (anon read via RLS) and
    /// populates `enabledResortIds` with every resort that has an
    /// published dataset. Called from `SupabaseManager.initialize()` on
    /// cold launch. After an operator publishes a staged graph, the next app
    /// launch picks it up automatically — no client code change or flag flip.
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
            // Failure is silent. Canonical remains the default and each load
            // retries through the fetcher; discovery is only an optimization.
            print("[CanonicalGraphFetcher] discoverEnabledResorts failed: \(error.localizedDescription)")
        }
    }

    /// Fetch (or refresh) the explicitly published canonical graph for
    /// `resortId`. Staged manifests and unbuilt graphs are never visible here.
    func fetch(resortId: String) async throws -> CanonicalGraphResult {
        try await fetchOnce(resortId: resortId)
    }

    private func fetchOnce(resortId: String) async throws -> CanonicalGraphResult {
        let cached = await MountainRepository.shared.loadCanonical(resortID: resortId)
        let response = try await callGetResortGraph(
            resortId: resortId,
            cachedManifestVersion: cached?.version.manifestVersion,
            cachedContentSHA256: cached?.version.contentSHA256
        )

        switch response.status {
        case .cacheValid:
            guard let cached else {
                throw FetchError.cacheClaimedValidButMissing
            }
            guard response.manifestVersion == cached.version.manifestVersion,
                  response.currentManifestVersion == cached.version.manifestVersion,
                  response.graphVersion == cached.version.graphVersion,
                  response.sha256 == cached.version.contentSHA256 else {
                throw FetchError.invalidServerResponse(
                    "cache_valid identity does not match the local immutable dataset"
                )
            }
            let status = try? await fetchLiveStatus(
                url: response.liveStatusUrl,
                dataset: cached
            )
            return CanonicalGraphResult(
                dataset: cached,
                status: status,
                source: CanonicalGraphResult.Source.cache
            )

        case .fetch:
            guard let blobUrl = response.blobUrl,
                  let manifestVersion = response.manifestVersion,
                  let currentManifestVersion = response.currentManifestVersion,
                  let graphVersion = response.graphVersion,
                  let sha256 = response.sha256,
                  manifestVersion > 0,
                  manifestVersion == currentManifestVersion,
                  graphVersion == MountainRepository.canonicalGraphVersion,
                  Self.isValidSHA256(sha256),
                  blobUrl.scheme?.lowercased() == "https" else {
                throw FetchError.invalidServerResponse("fetch status missing required fields")
            }
            let payload = try await downloadAndDecode(
                blobUrl: blobUrl,
                expectedSha256: sha256,
                expectedResortID: resortId
            )
            let dataset = MountainDataset(
                resortID: resortId,
                version: MountainDatasetVersion(
                    manifestVersion: manifestVersion,
                    graphVersion: MountainRepository.canonicalGraphVersion,
                    contentSHA256: sha256
                ),
                snapshotDate: response.snapshotDate,
                source: .canonicalServer,
                graph: payload.graph,
                rendezvousPoints: payload.rendezvousPoints
            )
            await MountainRepository.shared.save(dataset)
            let status = try? await fetchLiveStatus(
                url: response.liveStatusUrl,
                dataset: dataset
            )
            return CanonicalGraphResult(
                dataset: dataset,
                status: status,
                source: CanonicalGraphResult.Source.freshDownload
            )

        case .notBuilt:
            throw FetchError.notBuilt(
                manifestVersion: response.manifestVersion ?? response.currentManifestVersion ?? 0
            )
        }
    }

    /// Fetches a pinned meet-request dataset. New requests carry the complete
    /// immutable dataset identifier; older requests fall back to the newest
    /// current-schema blob retained for their stamped manifest.
    func fetch(
        resortId: String,
        manifestVersion: Int,
        datasetVersionIdentifier: String? = nil
    ) async throws -> CanonicalGraphResult {
        let exactVersion: MountainDatasetVersion?
        if let datasetVersionIdentifier {
            guard let parsed = MountainDatasetVersion(
                identifier: datasetVersionIdentifier
            ),
            parsed.manifestVersion == manifestVersion,
            parsed.graphVersion == MountainRepository.canonicalGraphVersion else {
                throw FetchError.invalidRequestedDatasetVersion(
                    datasetVersionIdentifier
                )
            }
            exactVersion = parsed
        } else {
            exactVersion = nil
        }

        let cached: MountainDataset?
        if let exactVersion {
            cached = await MountainRepository.shared.loadCanonical(
                resortID: resortId,
                exactVersion: exactVersion
            )
        } else {
            cached = await MountainRepository.shared.loadCanonical(
                resortID: resortId,
                manifestVersion: manifestVersion
            )
        }
        if let cached {
            return CanonicalGraphResult(
                dataset: cached,
                status: await pinnedStatus(for: cached, manifestVersion: manifestVersion),
                source: .crossVersionFetch
            )
        }
        let response = try await callGetResortGraph(
            resortId: resortId,
            cachedManifestVersion: nil,
            cachedContentSHA256: nil,
            forceManifestVersion: manifestVersion,
            forceGraphVersion: exactVersion?.graphVersion,
            forceContentSHA256: exactVersion?.contentSHA256
        )
        guard response.status == .fetch,
              let blobUrl = response.blobUrl,
              let responseManifestVersion = response.manifestVersion,
              let graphVersion = response.graphVersion,
              let sha256 = response.sha256,
              responseManifestVersion == manifestVersion,
              graphVersion == MountainRepository.canonicalGraphVersion,
              exactVersion == nil
                || (
                    graphVersion == exactVersion?.graphVersion
                        && sha256 == exactVersion?.contentSHA256
                ),
              Self.isValidSHA256(sha256),
              blobUrl.scheme?.lowercased() == "https" else {
            throw FetchError.invalidServerResponse(
                "force-fetch v\(manifestVersion) returned \(response.status)"
            )
        }
        let payload = try await downloadAndDecode(
            blobUrl: blobUrl,
            expectedSha256: sha256,
            expectedResortID: resortId
        )
        let dataset = MountainDataset(
            resortID: resortId,
            version: MountainDatasetVersion(
                manifestVersion: manifestVersion,
                graphVersion: graphVersion,
                contentSHA256: sha256
            ),
            snapshotDate: response.snapshotDate,
            source: .canonicalServer,
            graph: payload.graph,
            rendezvousPoints: payload.rendezvousPoints
        )
        // Exact historical datasets are immutable and safe to retain. This
        // avoids a network dependency if another meet references the same
        // version later.
        await MountainRepository.shared.save(dataset)
        // Status used to be dropped here, so accepting a meet pinned to the
        // current publication failed until the next minute-tick refresh.
        let status = try? await fetchLiveStatus(
            url: response.liveStatusUrl,
            dataset: dataset
        )
        return CanonicalGraphResult(
            dataset: dataset,
            status: status,
            source: CanonicalGraphResult.Source.crossVersionFetch
        )
    }

    /// Best-effort current status for a pinned dataset served from cache.
    /// The sidecar only projects onto the manifest it was built for, so an
    /// older pinned version correctly stays without status.
    private func pinnedStatus(
        for dataset: MountainDataset,
        manifestVersion: Int
    ) async -> MountainStatus? {
        guard let response = try? await callGetResortGraph(
            resortId: dataset.resortID,
            cachedManifestVersion: dataset.version.manifestVersion,
            cachedContentSHA256: dataset.version.contentSHA256,
            forceManifestVersion: manifestVersion,
            forceGraphVersion: dataset.version.graphVersion,
            forceContentSHA256: dataset.version.contentSHA256
        ) else { return nil }
        return try? await fetchLiveStatus(url: response.liveStatusUrl, dataset: dataset)
    }

    // MARK: - Networking

    private func callGetResortGraph(
        resortId: String,
        cachedManifestVersion: Int?,
        cachedContentSHA256: String?,
        forceManifestVersion: Int? = nil,
        forceGraphVersion: String? = nil,
        forceContentSHA256: String? = nil
    ) async throws -> GetResortGraphResponse {
        var body: [String: Any] = ["resort_id": resortId]
        if let cachedManifestVersion {
            body["cached_manifest_version"] = cachedManifestVersion
        }
        if let cachedContentSHA256 {
            body["cached_content_sha256"] = cachedContentSHA256
        }
        if let forceManifestVersion {
            body["manifest_version"] = forceManifestVersion
        }
        if let forceGraphVersion {
            body["graph_version"] = forceGraphVersion
        }
        if let forceContentSHA256 {
            body["content_sha256"] = forceContentSHA256
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
        expectedSha256: String,
        expectedResortID: String
    ) async throws -> CanonicalMountainGraphDecoder.Payload {
        let (gzData, response) = try await URLSession.shared.data(from: blobUrl)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.blobDownloadFailed(status: http.statusCode)
        }
        guard gzData.count <= Self.maximumCompressedBlobBytes else {
            throw FetchError.blobSizeExceeded(
                kind: "compressed",
                actual: gzData.count,
                limit: Self.maximumCompressedBlobBytes
            )
        }
        // SHA verify + gunzip (~1.3 MB on Vail-scale resorts) + JSONDecoder
        // are CPU-bound. This type is `@MainActor`, so running them inline
        // hitches the UI exactly as a resort auto-loads at launch. Hop to a
        // detached task so the decode runs off the main actor; MountainGraph
        // is Sendable so the finished value returns cleanly to the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try Self.verifyAndDecodeBlob(
                gzData: gzData,
                expectedSha256: expectedSha256,
                expectedResortID: expectedResortID
            )
        }.value
    }

    /// Off-actor blob verification + decode. `nonisolated` + `static` so it
    /// carries no `@MainActor` isolation; invoked from a detached task above.
    nonisolated private static func verifyAndDecodeBlob(
        gzData: Data,
        expectedSha256: String,
        expectedResortID: String
    ) throws -> CanonicalMountainGraphDecoder.Payload {
        let actualSha = gzData.sha256Hex
        guard actualSha == expectedSha256 else {
            throw FetchError.sha256Mismatch(expected: expectedSha256, actual: actualSha)
        }
        let jsonData = try gzData.gunzipped()
        guard jsonData.count <= maximumDecodedBlobBytes else {
            throw FetchError.blobSizeExceeded(
                kind: "decoded",
                actual: jsonData.count,
                limit: maximumDecodedBlobBytes
            )
        }
        do {
            return try CanonicalMountainGraphDecoder.decodePayload(
                jsonData,
                expectedResortID: expectedResortID
            )
        } catch {
            throw FetchError.invalidGraphBlob(error.localizedDescription)
        }
    }

    nonisolated fileprivate static let maximumCompressedBlobBytes = 16 * 1_024 * 1_024
    nonisolated fileprivate static let maximumDecodedBlobBytes = 64 * 1_024 * 1_024

    nonisolated private static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func fetchLiveStatus(
        url: URL?,
        dataset: MountainDataset
    ) async throws -> MountainStatus? {
        guard let url else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return nil // best-effort
        }
        let blob = try JSONDecoder().decode(LiveStatusBlob.self, from: data)
        return blob.mountainStatus(for: dataset)
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

}

// MARK: - Result types

struct CanonicalGraphResult: Sendable {
    let dataset: MountainDataset
    let status: MountainStatus?
    let source: Source

    /// Compatibility projection while routing/render call sites migrate.
    var graph: MountainGraph { dataset.routingGraph(applying: status) }
    var manifestVersion: Int { dataset.version.manifestVersion ?? 0 }
    var snapshotDate: String? { dataset.snapshotDate }

    enum Source: Sendable {
        case cache               // server confirmed our cached version is current
        case freshDownload       // server returned a new blob, we downloaded it
        case crossVersionFetch   // pinned-version fetch for an inbound meet
    }
}

// MARK: - Wire types

nonisolated struct GetResortGraphResponse: Decodable, Sendable {
    let status: Status
    let manifestVersion: Int?
    let currentManifestVersion: Int?
    let graphVersion: String?
    let blobUrl: URL?
    let sha256: String?
    let snapshotDate: String?
    let liveStatusUrl: URL?

    enum Status: String, Decodable, Sendable {
        case cacheValid = "cache_valid"
        case fetch
        case notBuilt = "not_built"
    }

    enum CodingKeys: String, CodingKey {
        case status
        case manifestVersion = "manifest_version"
        case currentManifestVersion = "current_manifest_version"
        case graphVersion = "graph_version"
        case blobUrl = "blob_url"
        case sha256
        case snapshotDate = "snapshot_date"
        case liveStatusUrl = "live_status_url"
    }
}

struct LiveStatusBlob: Decodable, Sendable {
    enum StatusMode: String, Decodable, Sendable {
        case active
        case offSeason = "off_season"
    }

    let resortId: String
    /// Present on v2 sidecars. Older empty/name-keyed sidecars omitted it.
    let manifestVersion: Int?
    let builtAt: String
    let expiresAt: String
    let statusMode: StatusMode
    /// Preferred v2 wire shape: stable graph edge ID → status.
    let segments: [String: LiveStatusEntry]
    /// Backward-compatible v1 name-keyed payloads. Converted to stable edge
    /// IDs once at the dataset boundary and never exposed to routing.
    let lifts: [String: LiveStatusEntry]
    let trails: [String: LiveStatusEntry]

    enum CodingKeys: String, CodingKey {
        case resortId = "resort_id"
        case manifestVersion = "manifest_version"
        case builtAt = "built_at"
        case expiresAt = "expires_at"
        case statusMode = "status_mode"
        case segments, lifts, trails
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resortId = try c.decode(String.self, forKey: .resortId)
        manifestVersion = try c.decodeIfPresent(Int.self, forKey: .manifestVersion)
        builtAt = try c.decode(String.self, forKey: .builtAt)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        statusMode = try c.decodeIfPresent(StatusMode.self, forKey: .statusMode) ?? .active
        segments = try c.decodeIfPresent([String: LiveStatusEntry].self, forKey: .segments) ?? [:]
        lifts = try c.decodeIfPresent([String: LiveStatusEntry].self, forKey: .lifts) ?? [:]
        trails = try c.decodeIfPresent([String: LiveStatusEntry].self, forKey: .trails) ?? [:]
    }

    func mountainStatus(for dataset: MountainDataset) -> MountainStatus? {
        guard resortId == dataset.resortID,
              manifestVersion == nil || manifestVersion == dataset.version.manifestVersion,
              let observedAt = ISO8601Parser.parse(builtAt),
              let expiresAt = ISO8601Parser.parse(expiresAt) else {
            return nil
        }

        var states: [String: MountainStatus.SegmentState] = [:]

        // A winter feed with no ski trails is explicitly marked off-season by
        // the server. Empty must mean closed/unknown, never "use base-open."
        if statusMode == .offSeason {
            states = Dictionary(uniqueKeysWithValues: dataset.graph.edges.map {
                ($0.id, MountainStatus.SegmentState(isOpen: false, waitMinutes: nil))
            })
            return MountainStatus(
                resortID: dataset.resortID,
                datasetVersion: dataset.version,
                observedAt: observedAt,
                expiresAt: expiresAt,
                source: .canonicalSidecar,
                operatingMode: .offSeason,
                confidence: 1,
                segmentStates: states
            )
        }

        for (edgeID, entry) in segments where dataset.graph.edge(byID: edgeID) != nil {
            states[edgeID] = entry.segmentState
        }

        var usedLegacyNameMapping = false
        for edge in dataset.graph.edges.sorted(by: { $0.id < $1.id }) {
            guard states[edge.id] == nil, let name = edge.attributes.trailName else {
                continue
            }
            let entry: LiveStatusEntry?
            switch edge.kind {
            case .lift:
                entry = lifts[name]
            case .run, .traverse:
                entry = trails[name]
            }
            if let entry {
                states[edge.id] = entry.segmentState
                usedLegacyNameMapping = true
            }
        }

        // Active status must cover enough of the actual ski network to prove
        // the vendor/manifest mapping is still healthy. One matching trail on
        // a 200-run mountain is not a safe "fresh" status. Once the feed clears
        // this gross-coverage gate, individual unmatched run/lift edges remain
        // unavailable; structural traverses retain their immutable state.
        let operationalEdges = dataset.graph.edges.filter {
            $0.kind == .run || $0.kind == .lift
        }
        let coveredCount = operationalEdges.reduce(into: 0) { count, edge in
            if states[edge.id] != nil { count += 1 }
        }
        let coverage = operationalEdges.isEmpty
            ? 0
            : Double(coveredCount) / Double(operationalEdges.count)
        guard coverage >= 0.5 else { return nil }

        for edge in operationalEdges where states[edge.id] == nil {
            states[edge.id] = .init(isOpen: false, waitMinutes: nil)
        }

        return MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: dataset.version,
            observedAt: observedAt,
            expiresAt: expiresAt,
            source: .canonicalSidecar,
            operatingMode: .active,
            confidence: (usedLegacyNameMapping ? 0.8 : 1) * coverage,
            segmentStates: states
        )
    }
}

struct LiveStatusEntry: Decodable, Sendable {
    let isOpen: Bool
    let waitMinutes: Double?

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case waitMinutes = "wait_minutes"
    }

    var segmentState: MountainStatus.SegmentState {
        .init(isOpen: isOpen, waitMinutes: waitMinutes)
    }
}

// MARK: - Errors

enum FetchError: LocalizedError {
    case cacheClaimedValidButMissing
    case invalidServerResponse(String)
    case notBuilt(manifestVersion: Int)
    case blobDownloadFailed(status: Int)
    case sha256Mismatch(expected: String, actual: String)
    case blobSizeExceeded(kind: String, actual: Int, limit: Int)
    case invalidGraphBlob(String)
    case invalidRequestedDatasetVersion(String)

    var errorDescription: String? {
        switch self {
        case .cacheClaimedValidButMissing:
            return "server said cache is valid but no local cache exists"
        case .invalidServerResponse(let msg):
            return "invalid server response: \(msg)"
        case .notBuilt(let v):
            return "legacy server returned unbuilt graph v\(v); an operator must build and publish it"
        case .blobDownloadFailed(let s):
            return "blob download failed: HTTP \(s)"
        case .sha256Mismatch(let e, let a):
            return "blob sha256 mismatch (expected \(e), actual \(a))"
        case .blobSizeExceeded(let kind, let actual, let limit):
            return "\(kind) graph blob is too large (\(actual) bytes; limit \(limit))"
        case .invalidGraphBlob(let msg):
            return "invalid graph blob: \(msg)"
        case .invalidRequestedDatasetVersion(let identifier):
            return "unsupported or malformed requested dataset version: \(identifier)"
        }
    }
}

// MARK: - Crypto / gzip helpers

nonisolated private extension Data {
    // `sha256Hex` now lives on `Data` in CryptoHelpers.swift (single copy).

    /// Decompress a raw-deflate (zlib) blob using the Compression
    /// framework. Apple's `COMPRESSION_ZLIB` consumes raw deflate (RFC
    /// 1951), NOT gzip-wrapped (RFC 1952). The build-resort-graph edge
    /// function MUST emit raw deflate (e.g. `fflate.deflateSync`,
    /// not `gzipSync`) for this to round-trip.
    nonisolated func gunzipped() throws -> Data {
        let count = self.count
        // Allow up to 32x expansion, with a 4 MB floor for small but highly
        // compressible graphs and a hard 64 MB decoded ceiling.
        let dstCapacity = Swift.min(
            Swift.max(count * 32, 4 << 20),
            CanonicalGraphFetcher.maximumDecodedBlobBytes
        )
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
        guard written > 0, written < dstCapacity else {
            throw NSError(domain: "CanonicalGraphFetcher", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "deflate decode failed or exceeded the decoded graph size limit",
            ])
        }
        return Data(bytes: dst, count: written)
    }
}
