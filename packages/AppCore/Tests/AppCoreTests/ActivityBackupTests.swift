import DescentKit
import Foundation
import PowderMeetAPI
import Testing
@testable import AppCore

// The `.powdermeet` backup: a round trip into another account, a file in the older
// PowderMeet backup format, and importing either twice adding nothing to the server.

@Test func aBackupRestoresEveryRunIntoAnotherAccountOnce() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let alice = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: alice, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DescentKit/Tests/DescentKitTests/Fixtures/GPSLogs/gpx/2026-03-12-whistler-blackcomb.gpx")
    _ = await library.importFiles([ActivityLibrary.Source(name: "day.gpx") { try Data(contentsOf: url) }], user: alice)
    let stored = try await library.history().resorts.flatMap(\.days).flatMap(\.runs)
    #expect(stored.count == 7)

    let file = try await library.exportBackup(user: alice)
    #expect(ActivityBackup.isBackup(fileName: "renamed.json", data: file), "the marker comes first")
    let contents = try ActivityBackup.decode(file)
    #expect(contents.entries.count == 7)

    let bob = await world.backend.addUser(displayName: "Bob")
    let bobPhone = Phone("bob", user: bob, world: world)
    defer { Task { await bobPhone.kill() } }
    let bobLibrary = ActivityLibrary(dependencies: bobPhone.dependencies)
    let source = ActivityLibrary.Source(name: ActivityBackup.fileName(on: Date())) { file }

    guard case .imported(let first) = await bobLibrary.importFiles([source], user: bob).first?.outcome else {
        Issue.record("the backup did not import")
        return
    }
    #expect(first.runsAdded == 7)
    let aliceRows = try await phone.dependencies.backend.descents(limit: 100)
    let bobRows = try await bobPhone.dependencies.backend.descents(limit: 100)
    #expect(Set(bobRows.map(\.contentHash)) == Set(aliceRows.map(\.contentHash)), "the same descents, by identity")

    guard case .imported(let again) = await bobLibrary.importFiles([source], user: bob).first?.outcome else {
        Issue.record("the second import failed")
        return
    }
    #expect(again.runsAdded == 0 && again.runsAlreadyHad == 7)
    #expect(await world.backend.callCount("descent_upsert") == 7 + 7, "the repeat sends nothing")
    #expect(try await bobLibrary.history().resorts.flatMap(\.days).flatMap(\.runs).count == 7)
}

@Test func anOlderBackupRestoresItsRunsWithoutTracks() async throws {
    // Schema 5 of the older format: markers first, ISO dates, "nan" for a number
    // it could not compute, a run with no length, and a repeated dedup hash.
    let older = """
    {"export_schema_version": 5, "exported_at": "2026-02-01T18:00:00Z",
     "profile": {"display_name": "Alice", "something_unknown": [1, 2]},
     "stats": {"avg_speed_ms": "nan"},
     "runs": [
       {"resort_id": "whistler-blackcomb", "edge_id": "e1", "difficulty": "doubleBlack",
        "speed_ms": "nan", "peak_speed_ms": 21.5, "duration_s": 140, "vertical_m": 310,
        "distance_m": 1200, "max_grade_deg": 30, "run_at": "2026-01-20T17:00:00Z",
        "dedup_hash": "slopes|1|whistler|e1", "source": "slopes", "trail_name": "Couloir"},
       {"speed_ms": 7, "duration_s": 90, "vertical_m": 150, "distance_m": 600, "max_grade_deg": 20,
        "run_at": "2026-01-20T18:00:00Z", "dedup_hash": "strava|2", "source": "strava"},
       {"speed_ms": 7, "duration_s": 0, "vertical_m": 150, "distance_m": 600, "max_grade_deg": 20,
        "run_at": "2026-01-20T19:00:00Z", "dedup_hash": "gpx|3"},
       {"speed_ms": 7, "duration_s": 90, "vertical_m": 150, "distance_m": 600, "max_grade_deg": 20,
        "run_at": "2026-01-20T18:00:00Z", "dedup_hash": "strava|2"}
     ],
     "avatar_image_base64": null}
    """
    let data = Data(older.utf8)
    #expect(ActivityBackup.isBackup(fileName: "old-backup.json", data: data))
    let contents = try ActivityBackup.decode(data)
    #expect(contents.origin == .powderMeet1(schemaVersion: 5))
    #expect(contents.entries.count == 2 && contents.skipped == 2)
    let couloir = try #require(contents.entries.first)
    #expect(couloir.source == .slopes && couloir.endedAt.timeIntervalSince(couloir.startedAt) == 140)
    #expect(couloir.stats?.difficulty == "double_black" && couloir.stats?.avgSpeedMS == nil)
    #expect(couloir.stats?.pace == nil && couloir.stats?.matched == nil, "older-format runs never teach calibration")
    #expect(try DescentTrackCodec.decode(couloir.track).isEmpty)
    #expect(contents.entries[1].source == .gpx, "a source with no `DescentSource` name is stored as gpx")

    let world = try await World()
    defer { world.cleanUp() }
    let alice = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: alice, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)
    let source = ActivityLibrary.Source(name: "powdermeet-2026-02-01.powdermeet") { data }
    for expectedAdded in [2, 0] {
        guard case .imported(let report) = await library.importFiles([source], user: alice).first?.outcome else {
            Issue.record("the older backup did not import")
            return
        }
        #expect(report.runsAdded == expectedAdded)
    }
    let history = try await library.history()
    #expect(history.totals.runs == 2)
    #expect(abs(history.totals.verticalM - 460) < 0.01)

    // Schema 1 held only the profile: it reads, and restores nothing.
    let profileOnly = try ActivityBackup.decode(Data(#"{"export_schema_version": 1, "profile": {}}"#.utf8))
    #expect(profileOnly.entries.isEmpty)
    #expect(throws: ActivityBackup.DecodeError.notABackup) { try ActivityBackup.decode(Data("[1]".utf8)) }
}
