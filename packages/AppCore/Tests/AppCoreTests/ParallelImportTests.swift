import DescentKit
import Foundation
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// A day from the DescentKit corpus, read from that package's fixtures.
private func corpusFile(_ name: String) -> ActivityLibrary.Source {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DescentKit/Tests/DescentKitTests/Fixtures/GPSLogs/\((name as NSString).pathExtension)/\(name)")
    return ActivityLibrary.Source(name: name) { try Data(contentsOf: url) }
}

/// Whistler days, each wanting the same bundle at once; two pairs of files that
/// share a day; one file twice; and a file that is not an activity.
private let batch = [
    "2026-03-12-whistler-blackcomb.gpx",
    "2026-01-14-whistler-blackcomb.slopes",
    "2026-01-15-whistler-blackcomb.slopes",
    "2026-01-10-sierra-at-tahoe-heavenly.slopes",
    "2026-01-10-sierra-at-tahoe.slopes",
    "2026-01-12-kirkwood.slopes",
    "2026-01-12-kirkwood-2.slopes",
    "2026-03-12-whistler-blackcomb.gpx",
    "2026-01-16-whistler-blackcomb.slopes",
].map(corpusFile) + [ActivityLibrary.Source(name: "notes.txt") { Data("hello".utf8) }]

/// A world whose catalog maps Whistler, so the Whistler days open its bundle.
private func whistlerWorld() async throws -> World {
    let world = try await World()
    let stored = try TestResort.stored(id: "whistler")
    await world.backend.addResort(PublishedResort(
        id: "whistler", name: "Whistler", timezone: "America/Vancouver",
        bbox: BoundingBox(minLon: -123.1, minLat: 49.95, maxLon: -122.8, maxLat: 50.2)
    ))
    await world.backend.publishBundle(
        resortID: "whistler", bundleID: stored.bundleID, data: stored.data, rendezvousIDs: []
    )
    return world
}

private actor Counts {
    var seen: [Int] = []
    func note(_ done: Int) { seen.append(done) }
}

/// Saving stays in file order, so importing several files at once gives the
/// same reports and the same stored runs as one at a time, with a day that is
/// in two files, or in one file twice, stored once.
@Test func importingFilesAtOnceSavesWhatOneAtATimeDoes() async throws {
    func run(concurrency: Int) async throws -> (
        reports: [ActivityLibrary.FileReport], stored: [DescentSummary], progress: [Int], bundleLoads: Int
    ) {
        let world = try await whistlerWorld()
        defer { world.cleanUp() }
        let user = await world.backend.addUser(displayName: "Alice")
        let phone = Phone("alice", user: user, world: world)
        defer { Task { await phone.kill() } }
        let library = ActivityLibrary(dependencies: phone.dependencies)
        let counts = Counts()
        let reports = await library.importFiles(batch, user: user, concurrency: concurrency) {
            await counts.note($0)
        }
        let stored = try await phone.dependencies.backend.descents(limit: ActivityLibrary.historyLimit)
        return (reports, stored, await counts.seen, await world.backend.callCount("bundle_data"))
    }

    let single = try await run(concurrency: 1)
    let parallel = try await run(concurrency: ActivityLibrary.importConcurrency)

    #expect(parallel.reports.map(\.fileName) == batch.map(\.name))
    #expect(parallel.reports.map(\.outcome) == single.reports.map(\.outcome))
    func key(_ row: DescentSummary) -> String { "\(row.contentHash)|\(row.startedAt.timeIntervalSince1970)" }
    #expect(parallel.stored.map(key).sorted() == single.stored.map(key).sorted())
    #expect(Set(parallel.stored.map(\.stats)) == Set(single.stored.map(\.stats)))
    #expect(parallel.progress == Array(1...batch.count))
    #expect(parallel.bundleLoads == 1)

    let added = parallel.reports.map { report -> Int in
        if case .imported(let imported) = report.outcome { return imported.runsAdded }
        return 0
    }
    #expect(added.reduce(0, +) == parallel.stored.count)
    // The second copy of the first file adds nothing.
    #expect(added[7] == 0)
    guard case .imported(let first) = parallel.reports[0].outcome,
          case .imported(let again) = parallel.reports[7].outcome else {
        Issue.record("the Whistler day did not import: \(parallel.reports)")
        return
    }
    #expect(again.runsAlreadyHad == first.runsFound)
}

/// Cancelling stops at the file being saved: its runs and those before it
/// stay, and nothing after it is saved.
@Test func cancellingAnImportKeepsWhatWasSaved() async throws {
    let world = try await whistlerWorld()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)

    // Its own task, so that only the import is cancelled.
    let reports = await Task {
        await library.importFiles(batch, user: user) { done in
            if done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }.value
    #expect(reports.map(\.fileName) == batch.prefix(2).map(\.name))
    let added = reports.map { report -> Int in
        if case .imported(let imported) = report.outcome { return imported.runsAdded }
        return 0
    }
    let stored = try await phone.dependencies.backend.descents(limit: ActivityLibrary.historyLimit)
    #expect(added.allSatisfy { $0 > 0 })
    #expect(stored.count == added.reduce(0, +))
}

/// Runs named by an older matcher are matched again from their stored tracks,
/// once: the same rows are updated, none is added or lost, and a run already
/// on the current matcher is left alone. Each run carries its version, so a
/// pass that stops resumes with only what is left.
@Test func runsFromAnOlderMatcherAreMatchedAgainOnce() async throws {
    let world = try await whistlerWorld()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let backend = phone.dependencies.backend
    let library = ActivityLibrary(dependencies: phone.dependencies)
    _ = await library.importFiles([corpusFile("2026-03-12-whistler-blackcomb.gpx")], user: user)
    let imported = try await backend.descentRecords(offset: 0, limit: 100)
    #expect(imported.count == 7)
    #expect(imported.allSatisfy { $0.summary.stats?.matcherVersion == MatcherVersion })
    #expect(await library.rematchOlderRuns() == 0)

    // Five runs as an older build stored them: no version, a stale name.
    for record in imported.prefix(5) {
        let row = record.summary
        var stats = row.stats ?? DescentStatsRow()
        stats.matcherVersion = nil
        stats.trailName = "Old name"
        stats.pace = nil
        _ = try await backend.descentUpsert(DescentUpload(
            source: row.source, startedAt: row.startedAt, endedAt: row.endedAt,
            contentHash: row.contentHash, track: record.track, resortID: row.resortID,
            device: row.device, appBuild: "old", match: nil, stats: stats
        ))
    }
    let current = Dictionary(uniqueKeysWithValues: imported.map { ($0.summary.descentID, $0.summary.stats) })

    #expect(await library.rematchOlderRuns() == 5)
    let after = try await backend.descents(limit: ActivityLibrary.historyLimit)
    #expect(Set(after.map(\.descentID)) == Set(imported.map(\.summary.descentID)))
    // Matched again, each run says what the import said.
    for row in after {
        #expect(row.stats == current[row.descentID] ?? nil, "\(row.descentID)")
    }

    let upserts = await world.backend.callCount("descent_upsert")
    #expect(await library.rematchOlderRuns() == 0)
    #expect(await world.backend.callCount("descent_upsert") == upserts)
}
