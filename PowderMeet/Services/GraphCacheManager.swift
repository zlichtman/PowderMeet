//
//  GraphCacheManager.swift
//  PowderMeet
//
//  Persists MountainGraph data to disk (JSON) so resorts don't need
//  to be re-fetched from Overpass on every app launch.
//  Now tracks snapshot dates for server-side shared graph consistency.
//

import Foundation

/// Metadata wrapper for cached graphs — tracks which snapshot the graph was built from.
struct CachedGraph: Sendable {
    let graph: MountainGraph
    let snapshotDate: String     // "2026-03-24" — date of the server-side data snapshot
    let snapshotVersion: Int     // bumped when graph builder logic changes
    let cachedAt: Date
}

extension CachedGraph: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graph = try c.decode(MountainGraph.self, forKey: .graph)
        snapshotDate = try c.decode(String.self, forKey: .snapshotDate)
        snapshotVersion = try c.decode(Int.self, forKey: .snapshotVersion)
        cachedAt = try c.decode(Date.self, forKey: .cachedAt)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(graph, forKey: .graph)
        try c.encode(snapshotDate, forKey: .snapshotDate)
        try c.encode(snapshotVersion, forKey: .snapshotVersion)
        try c.encode(cachedAt, forKey: .cachedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case graph, snapshotDate, snapshotVersion, cachedAt
    }
}

actor GraphCacheManager {
    static let shared = GraphCacheManager()

    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResortGraphs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[GraphCache] ⚠️ Failed to create cache dir at \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }()

    /// Maximum cache age before we re-fetch. Bumped from 7 to 30 days
    /// because pinned snapshots make the server-side blob immutable —
    /// a refresh just downloads the same bytes. 30 days lets devices
    /// freshen on a leisurely cadence in case a pin gets bumped server
    /// side, without paying cold-load latency every week.
    private let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60
    /// Bump when graph structure changes (e.g. threshold adjustments, pruning, elevation/vert fixes)
    static let graphVersion = "v8"
    /// Bump when graph builder logic changes (snapping, splitting, traverse generation)
    static let snapshotVersion = 3  // 2026-04-29: wipe local caches, force enriched rebuild

    // MARK: - Read (with snapshot metadata)

    func loadCachedGraph(resortID: String) -> CachedGraph? {
        let fileURL = cacheDir.appendingPathComponent("\(resortID)-\(Self.graphVersion).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > maxCacheAge {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            AppLog.graph.error("cache read failed for \(resortID): \(error.localizedDescription)")
            return nil
        }
        if let decoded = Self.decodeCachedGraph(from: data) { return decoded }
        AppLog.graph.error("cache decode failed for \(resortID) — schema drift?")
        return nil
    }

    /// Legacy compatibility: returns just the graph without metadata
    func loadGraph(resortID: String) -> MountainGraph? {
        loadCachedGraph(resortID: resortID)?.graph
    }

    /// Returns the snapshot date for a cached resort, or nil if not cached
    func snapshotDate(for resortID: String) -> String? {
        loadCachedGraph(resortID: resortID)?.snapshotDate
    }

    // MARK: - Write (with snapshot metadata)

    func saveGraph(_ graph: MountainGraph, snapshotDate: String) {
        let cached = CachedGraph(
            graph: graph,
            snapshotDate: snapshotDate,
            snapshotVersion: Self.snapshotVersion,
            cachedAt: Date()
        )
        let fileURL = cacheDir.appendingPathComponent("\(graph.resortID)-\(Self.graphVersion).json")
        guard let data = Self.encodeCachedGraph(cached) else {
            AppLog.graph.error("cache encode failed for \(graph.resortID)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.graph.error("cache write failed for \(graph.resortID): \(error.localizedDescription)")
        }
    }

    /// Legacy compatibility: saves with today's date as snapshot date
    func saveGraph(_ graph: MountainGraph) {
        let today = Self.todayString()
        saveGraph(graph, snapshotDate: today)
    }

    // MARK: - Clear

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func clearResort(_ resortID: String) {
        let fileURL = cacheDir.appendingPathComponent("\(resortID)-\(Self.graphVersion).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Helpers

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    // MARK: - Nonisolated encode/decode (avoids actor-isolation Codable warnings)

    private nonisolated static func decodeCachedGraph(from data: Data) -> CachedGraph? {
        try? JSONDecoder().decode(CachedGraph.self, from: data)
    }

    private nonisolated static func encodeCachedGraph(_ cached: CachedGraph) -> Data? {
        try? JSONEncoder().encode(cached)
    }
}
