//
//  PendingLiveRunStore.swift
//  PowderMeet
//
//  Live runs whose save failed (a dead zone on a chairlift is routine) wait
//  here until `LiveRunRecorder` can upload them. One file per signed-in user
//  so a queued run can never be written under a different account.
//

import Foundation

nonisolated enum PendingLiveRunStore {
    /// Bounds disk use if a device stays offline for days.
    static let maximumQueuedRuns = 500

    static func hasRows(for userID: UUID, in directory: URL? = nil) -> Bool {
        guard let url = fileURL(for: userID, in: directory) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func load(for userID: UUID, in directory: URL? = nil) -> [ImportedRunWriteRow] {
        guard let url = fileURL(for: userID, in: directory),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ImportedRunWriteRow].self, from: data)) ?? []
    }

    static func append(_ row: ImportedRunWriteRow, for userID: UUID, in directory: URL? = nil) {
        var rows = load(for: userID, in: directory)
        guard !rows.contains(where: { $0.dedup_hash == row.dedup_hash }) else { return }
        rows.append(row)
        if rows.count > maximumQueuedRuns {
            rows.removeFirst(rows.count - maximumQueuedRuns)
        }
        save(rows, for: userID, in: directory)
    }

    static func remove(dedupHashes: Set<String>, for userID: UUID, in directory: URL? = nil) {
        let remaining = load(for: userID, in: directory).filter {
            !dedupHashes.contains($0.dedup_hash)
        }
        save(remaining, for: userID, in: directory)
    }

    private static func save(_ rows: [ImportedRunWriteRow], for userID: UUID, in directory: URL?) {
        guard let url = fileURL(for: userID, in: directory) else { return }
        guard !rows.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func fileURL(for userID: UUID, in directory: URL?) -> URL? {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PendingLiveRuns", isDirectory: true)
        return base?.appendingPathComponent("\(userID.uuidString.lowercased()).json")
    }
}
