import DescentKit
import Foundation
import MeetSolver
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

@Test func importingTheSameDayTwiceAddsNothing() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)
    let day = corpusFile("2026-03-12-whistler-blackcomb.gpx")

    let first = await library.importFiles([day], user: user)
    guard case .imported(let imported) = first.first?.outcome else {
        Issue.record("the corpus day did not import: \(first)")
        return
    }
    #expect(imported.runsFound == 7)
    #expect(imported.runsAdded == 7)

    let second = await library.importFiles([day], user: user)
    guard case .imported(let again) = second.first?.outcome else {
        Issue.record("the second import failed: \(second)")
        return
    }
    #expect(again.runsAdded == 0)
    #expect(again.runsAlreadyHad == 7)

    let history = try await library.history()
    #expect(history.totals.runs == 7)
    #expect(history.totals.days == 1)
    #expect(abs(history.totals.verticalM - imported.verticalM) < 1)
    #expect((history.totals.topSpeedMS ?? 0) > 5)

    // Deleting the day empties the history. Ids nobody has are deleted as
    // nothing, and pad the list past the deletes kept in flight, so the
    // queue refills; progress counts every one.
    let ids = history.resorts.flatMap(\.days).flatMap(\.runs).map(\.id) + (0..<20).map { _ in UUID() }
    let seen = DeleteProgress()
    try await library.delete(ids) { await seen.note($0) }
    #expect(await seen.counts == Array(1...ids.count))
    #expect(try await library.history().isEmpty)
}

/// A second app's recording of a day already in the history (a watch's GPX
/// after a phone's file) adds no runs, though its clock is a few seconds off
/// and its positions are rounded, so no content hash matches. The same run
/// skied again minutes later is a new run.
@Test func theSameDayFromASecondAppIsNotCountedTwice() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)
    let day = corpusFile("2026-03-12-whistler-blackcomb.gpx")
    let points = try GPXParser.parse(day.load()).segments.flatMap(\.points)

    let first = await library.importFiles([day], user: user)
    guard case .imported(let imported) = first.first?.outcome else {
        Issue.record("the corpus day did not import: \(first)")
        return
    }
    #expect(imported.runsAdded == 7)
    let upserts = await world.backend.callCount("descent_upsert")

    let watch = ActivityLibrary.Source(name: "watch.gpx") { gpxExport(points, shiftedBy: 4) }
    let second = await library.importFiles([watch], user: user)
    guard case .imported(let again) = second.first?.outcome else {
        Issue.record("the second recording did not import: \(second)")
        return
    }
    #expect(again.runsFound >= 6)
    #expect(again.runsAdded == 0)
    #expect(again.runsAlreadyHad == again.runsFound)
    #expect(await world.backend.callCount("descent_upsert") == upserts, "the phone caught every repeat itself")
    var history = try await library.history()
    #expect(history.totals.runs == 7)
    #expect(history.totals.days == 1)
    #expect(abs(history.totals.verticalM - imported.verticalM) < 1)

    // The day's last run, skied again ten minutes after it ended.
    let descents = try ActivityImporter.importActivity(fileName: day.name, data: day.load()).descents
    let last = try #require(descents.max { $0.endedAt < $1.endedAt })
    let lap = last.endedAt.timeIntervalSince(last.startedAt) + 600
    let lapPoints = points.filter {
        guard let time = $0.timestamp else { return false }
        return time >= last.startedAt.addingTimeInterval(-60) && time <= last.endedAt.addingTimeInterval(30)
    }
    let lapFile = ActivityLibrary.Source(name: "lap.gpx") { gpxExport(lapPoints, shiftedBy: lap) }
    let third = await library.importFiles([lapFile], user: user)
    guard case .imported(let lapImport) = third.first?.outcome else {
        Issue.record("the second lap did not import: \(third)")
        return
    }
    #expect(lapImport.runsAdded == 1)
    history = try await library.history()
    #expect(history.totals.runs == 8)
}

/// A GPX as another app writes it: whole seconds, six decimal places, and a
/// clock `shiftedBy` seconds from the original's.
private func gpxExport(_ points: [TrackPoint], shiftedBy offset: TimeInterval) -> Data {
    let format = ISO8601DateFormatter()
    var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    text += "<gpx creator=\"Watch\" version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n<trk><trkseg>\n"
    for point in points {
        guard let time = point.timestamp else { continue }
        text += "<trkpt lat=\"\(String(format: "%.6f", point.lat))\" lon=\"\(String(format: "%.6f", point.lon))\">"
        if let metres = point.elevationM { text += "<ele>\(String(format: "%.1f", metres))</ele>" }
        text += "<time>\(format.string(from: time.addingTimeInterval(offset)))</time></trkpt>\n"
    }
    text += "</trkseg></trk></gpx>\n"
    return Data(text.utf8)
}

private actor DeleteProgress {
    var counts: [Int] = []
    func note(_ done: Int) { counts.append(done) }
}

@Test func aFileThatIsNotAnActivitySaysSo() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)

    let reports = await library.importFiles(
        [ActivityLibrary.Source(name: "notes.txt") { Data("hello".utf8) }], user: user
    )
    guard case .failed(let message) = reports.first?.outcome else {
        Issue.record("a text file imported: \(reports)")
        return
    }
    #expect(message.contains("isn't a file PowderMeet can read"))
}

@Test func runsMoveTheBaselineTowardWhatWasSkied() {
    let preset = SkierProfile.preset(.intermediate, userID: UUID()).baselineSpeedMS
    var fastBlues = PaceCalibration.Evidence()
    for _ in 0..<8 { fastBlues.add(movingS: 100, lengthM: 1_000) }   // 10 m/s against a preset of 5

    let speeds = PaceCalibration.baselineSpeeds(ability: .intermediate, evidence: [.blue: fastBlues])
    // Eight runs weigh as much as the preset: halfway to twice as fast.
    #expect(speeds["blue"] == 7.5)
    #expect(speeds["green"] == preset[.green])
    // No evidence at all is the preset, whatever was stored before.
    #expect(PaceCalibration.baselineSpeeds(ability: .intermediate, evidence: [:])
        == Dictionary(uniqueKeysWithValues: preset.map { ($0.key.rawValue, $0.value) }))
}

@Test func abilitySetsPaceOnlyNotTheHardestRun() {
    // A row saved while ability capped the limit has no black pace; the black
    // limit the skier chose is still what decides, at the preset's slow pace.
    let row = Profile(
        id: UUID(), displayName: "Pat", ability: "beginner", maxDifficulty: "black",
        baselineSpeeds: ["green": 4.5, "blue": 2]
    )
    let routing = SkierProfile(row)
    #expect(routing.maxDifficulty == .black)
    #expect(routing.baselineSpeedMS[.green] == 4.5)
    #expect(routing.baselineSpeedMS[.black] == SkierProfile.preset(.beginner, userID: row.id).baselineSpeedMS[.black])
    for ability in Ability.allCases {
        #expect(SkierProfile.preset(ability, userID: row.id).baselineSpeedMS.count == 5, "\(ability)")
    }
}

@Test func theLevelTheRunsBackIsTheOneCoveringTheHardestRunSkied() {
    func run(_ difficulty: String?) -> DescentSummary {
        DescentSummary(
            descentID: UUID(), source: .gpx, startedAt: .now, endedAt: .now.addingTimeInterval(120),
            contentHash: UUID().uuidString, stats: DescentStatsRow(difficulty: difficulty)
        )
    }
    let bluesAndPark = ActivityHistory([run("green"), run("blue"), run("park"), run(nil)])
    #expect(bluesAndPark.backedAbility == .intermediate)
    #expect(ActivityHistory([run("double_black")]).backedAbility == .expert)
    // No rated run: the runs say nothing about the level.
    #expect(ActivityHistory([run(nil)]).backedAbility == nil)
}

/// Live runs go through the same store as files, keep `live` as their source,
/// and a run the recorder hands over twice (a relaunch mid-upload) is stored once.
@Test func liveRunsAreStoredOnceWithTheirSource() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)
    let data = try corpusFile("2026-03-12-whistler-blackcomb.gpx").load()
    let runs = try ActivityImporter.importActivity(fileName: "day.gpx", data: data).descents.map {
        var run = $0
        run.source = .live
        return run
    }

    guard case .imported(let first) = await library.storeLive(runs, resorts: [], user: user) else {
        Issue.record("live runs were not stored")
        return
    }
    #expect(first.runsAdded == runs.count)
    guard case .imported(let again) = await library.storeLive(runs, resorts: [], user: user) else {
        Issue.record("the repeat failed")
        return
    }
    #expect(again.runsAdded == 0)
    let history = try await library.history()
    #expect(history.totals.runs == runs.count)
    #expect(history.resorts.flatMap(\.days).flatMap(\.runs).allSatisfy { $0.source == "live" })
}

/// A day imported from another app, then recorded live on the phone: the live
/// runs start later than the imported ones (the recorder cut them elsewhere),
/// so the server's overlap rule alone would store them all again.
@Test func aLiveRecordingOfAnImportedDayIsNotCountedTwice() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    defer { Task { await phone.kill() } }
    let library = ActivityLibrary(dependencies: phone.dependencies)
    let day = corpusFile("2026-03-12-whistler-blackcomb.gpx")
    guard case .imported(let imported) = await library.importFiles([day], user: user).first?.outcome else {
        Issue.record("the corpus day did not import")
        return
    }
    let upserts = await world.backend.callCount("descent_upsert")

    let live = try ActivityImporter.importActivity(fileName: day.name, data: day.load()).descents.map {
        var run = $0
        run.source = .live
        run.points = Array(run.points.dropFirst(run.points.count * 3 / 10))
        run.startedAt = run.points.first?.timestamp ?? run.startedAt
        return run
    }
    guard case .imported(let recorded) = await library.storeLive(live, resorts: [], user: user) else {
        Issue.record("the live runs were not stored")
        return
    }
    #expect(recorded.runsAdded == 0)
    #expect(recorded.runsAlreadyHad == live.count)
    #expect(await world.backend.callCount("descent_upsert") == upserts, "the phone caught every repeat itself")
    #expect(try await library.history().totals.runs == imported.runsAdded)
}

@Test func locationModeFollowsWhatWantsFixes() {
    #expect(LocationDemand().mode == .off)
    #expect(LocationDemand(resortOpen: true).mode == .presence)
    #expect(LocationDemand(resortOpen: true, atResort: false).mode == .browsing)
    #expect(LocationDemand(recordingOn: true).mode == .watching)
    #expect(LocationDemand(recordingOn: true, atResort: true).mode == .recording)
    #expect(LocationDemand(resortOpen: true, recordingOn: true, meetActive: true, atResort: false).mode == .navigation)
    #expect(LocationMode.browsing.settings?.background == false)
    #expect(LocationMode.presence.settings?.background == true)
    #expect(LocationMode.presence.wantsAlways == false)
    #expect(LocationMode.recording.settings?.background == true)
    // A meet with the phone in a pocket: looser, still in the background, and
    // never looser than a recording that is on.
    #expect(LocationDemand(resortOpen: true, meetActive: true, inBackground: true).mode == .navigationBackground)
    #expect(LocationDemand(recordingOn: true, meetActive: true, atResort: true, inBackground: true).mode == .recording)
    #expect(LocationMode.navigationBackground.settings?.pausesWhenStill == false)
    #expect(LocationMode.navigation.settings?.pausesWhenStill == false)
    #expect(LocationMode.presence.settings?.pausesWhenStill == false)
    // Outside a meet the background changes nothing.
    #expect(LocationDemand(resortOpen: true, inBackground: true).mode == .presence)
    #expect(LocationDemand(locating: true).mode == .locating)
    #expect(LocationDemand(inBackground: true, locating: true).mode == .off)

    let resort = PublishedResort(
        id: "r", name: "R", timezone: "UTC",
        bbox: BoundingBox(minLon: 0, minLat: 0, maxLon: 0.01, maxLat: 0.01),
        passProducts: [], statusMode: .live
    )
    // 1.5 km east of the box: not entered from outside, but not left either.
    let edge = Coordinate(lon: 0.01 + 1_500 / 111_320, lat: 0.005)
    #expect(ResortVicinity.resort(at: edge, in: [resort], current: nil) == nil)
    #expect(ResortVicinity.resort(at: edge, in: [resort], current: "r")?.id == "r")
    #expect(ResortVicinity.resort(at: Coordinate(lon: 0.005, lat: 0.005), in: [resort], current: nil)?.id == "r")
}
