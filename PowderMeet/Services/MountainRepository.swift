//
//  MountainRepository.swift
//  PowderMeet
//
//  Single on-disk owner for immutable mountain datasets. Canonical datasets
//  retain every exact version for meet-plan replay; legacy snapshot/Overpass
//  datasets remain a transitional fallback and expire after 30 days.
//

import Foundation

nonisolated struct CachedMountainDataset: Codable, Sendable {
    let dataset: MountainDataset
    let cachedAt: Date
    /// Detects local cache truncation/mutation independently of the filename.
    /// Optional only so legacy cache envelopes remain decodable during rollout.
    let graphFingerprint: String?

    init(dataset: MountainDataset, cachedAt: Date) {
        self.dataset = dataset
        self.cachedAt = cachedAt
        self.graphFingerprint = dataset.graph.fingerprint
    }

    var graph: MountainGraph { dataset.graph }
    var snapshotDate: String { dataset.snapshotDate ?? "" }
}

actor MountainRepository {
    static let shared = MountainRepository()

    static let canonicalGraphVersion = "v15"
    static let legacyGraphVersion = "v15"
    static let legacySnapshotVersion = 3
    static var expectedLegacyVersion: String {
        "\(legacyGraphVersion)-s\(legacySnapshotVersion)"
    }

    private let maxLegacyCacheAge: TimeInterval = 30 * 24 * 60 * 60
    private let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MountainDatasets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: self.cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            AppLog.graph.error("mountain repository directory failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Canonical exact datasets

    func loadCanonical(
        resortID: String,
        manifestVersion: Int? = nil
    ) -> MountainDataset? {
        let candidates = loadEnvelopes(resortID: resortID)
            .filter {
                $0.dataset.source == .canonicalServer
                    && $0.dataset.version.graphVersion == Self.canonicalGraphVersion
                    && (manifestVersion == nil || $0.dataset.version.manifestVersion == manifestVersion)
            }
            .sorted { lhs, rhs in
                let lhsManifest = lhs.dataset.version.manifestVersion ?? -1
                let rhsManifest = rhs.dataset.version.manifestVersion ?? -1
                if lhsManifest != rhsManifest { return lhsManifest > rhsManifest }
                return lhs.cachedAt > rhs.cachedAt
            }
        return candidates.first?.dataset
    }

    /// Exact immutable lookup for cross-device meet replay. Unlike the
    /// current-version selector above, this includes the content SHA so two
    /// snapshots rebuilt under the same manifest cannot be confused.
    func loadCanonical(
        resortID: String,
        exactVersion: MountainDatasetVersion
    ) -> MountainDataset? {
        loadEnvelopes(resortID: resortID)
            .filter {
                $0.dataset.source == .canonicalServer
                    && $0.dataset.version == exactVersion
            }
            .sorted { $0.cachedAt > $1.cachedAt }
            .first?
            .dataset
    }

    // MARK: - Legacy fallback datasets

    func loadLegacy(resortID: String) -> CachedMountainDataset? {
        let candidates = loadEnvelopes(resortID: resortID)
            .filter { $0.dataset.source != .canonicalServer }
            .sorted { $0.cachedAt > $1.cachedAt }
        guard let latest = candidates.first else { return nil }
        guard Date().timeIntervalSince(latest.cachedAt) <= maxLegacyCacheAge else {
            remove(latest.dataset)
            return nil
        }
        return latest
    }

    // MARK: - Shared persistence

    func save(_ dataset: MountainDataset) {
        if dataset.source == .canonicalServer {
            do {
                try MountainGraphIntegrity.validateCanonical(
                    dataset.graph,
                    expectedResortID: dataset.resortID
                )
            } catch {
                AppLog.graph.error(
                    "refused invalid canonical cache write for \(dataset.resortID): \(error.localizedDescription)"
                )
                return
            }
        }
        let envelope = CachedMountainDataset(dataset: dataset, cachedAt: .now)
        do {
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: path(for: dataset), options: .atomic)
            if dataset.source != .canonicalServer {
                removeOtherLegacyVersions(of: dataset)
            }
        } catch {
            AppLog.graph.error("mountain dataset cache write failed for \(dataset.resortID): \(error.localizedDescription)")
        }
    }

    func clearResort(_ resortID: String) {
        for url in entryURLs(resortID: resortID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Disk helpers

    private func loadEnvelopes(resortID: String) -> [CachedMountainDataset] {
        entryURLs(resortID: resortID).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let cached = try? JSONDecoder().decode(CachedMountainDataset.self, from: data),
                  cached.dataset.resortID == resortID else {
                return nil
            }
            if cached.dataset.source == .canonicalServer {
                guard cached.graphFingerprint == cached.dataset.graph.fingerprint else {
                    AppLog.graph.error(
                        "ignored canonical cache with missing/mismatched fingerprint at \(url.lastPathComponent)"
                    )
                    return nil
                }
                do {
                    try MountainGraphIntegrity.validateCanonical(
                        cached.dataset.graph,
                        expectedResortID: resortID
                    )
                } catch {
                    AppLog.graph.error(
                        "ignored invalid canonical cache at \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                    return nil
                }
            }
            return cached
        }
    }

    private func entryURLs(resortID: String) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("\(resortID)--") }
    }

    private func path(for dataset: MountainDataset) -> URL {
        let manifest = dataset.version.manifestVersion.map(String.init) ?? "legacy"
        let source = dataset.source.rawValue
        let sha = String(dataset.version.contentSHA256.prefix(16))
        return cacheDirectory.appendingPathComponent(
            "\(dataset.resortID)--\(source)-m\(manifest)-\(dataset.version.graphVersion)-\(sha).json"
        )
    }

    private func remove(_ dataset: MountainDataset) {
        try? FileManager.default.removeItem(at: path(for: dataset))
    }

    private func removeOtherLegacyVersions(of saved: MountainDataset) {
        for cached in loadEnvelopes(resortID: saved.resortID)
        where cached.dataset.source != .canonicalServer
            && cached.dataset.version != saved.version {
            remove(cached.dataset)
        }
    }
}
