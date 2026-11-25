import CSQLite
import Foundation
import Testing
@testable import DescentKit

/// Bad fixes and damaged or hostile files: each must cost at most the bad
/// part, never the skier's runs, a hang or the app's memory.
struct HostileFileTests {
    private func importing(_ data: Data, as name: String) -> Result<ImportedActivity, ActivityImportError> {
        do {
            return .success(try ActivityImporter.importActivity(fileName: name, data: data))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Bad fixes

    /// A cold-start fix km away used to make every good fix after it look
    /// impossible for 90 s, so the top of the run was lost.
    @Test func aBadFirstFixIsDroppedNotTheGoodFixesAfterIt() {
        let run = SyntheticTrack.run(from: SyntheticTrack.origin, dropM: 300, seconds: 180)
        var stale = SyntheticTrack.origin
        stale.lat += 0.05
        let cleaned = DescentSegmenter.normalizedPoints([stale] + run)
        #expect(cleaned == run)
    }

    /// Loggers write 0 m when they have no altitude: one such fix mid-run
    /// must neither split the run nor add vertical.
    @Test func oneZeroAltitudeMidRunNeitherSplitsItNorAddsVertical() {
        var points = [SyntheticTrack.origin]
        points += SyntheticTrack.lift(from: points[points.count - 1], climbM: 400, seconds: 500)
        points += SyntheticTrack.run(from: points[points.count - 1], dropM: 300, seconds: 180)
        points += SyntheticTrack.wait(at: points[points.count - 1], seconds: 60)
        points[501 + 90].elevationM = 0
        let found = DescentSegmenter.segments(ParsedActivity(source: .live, segments: [ParsedSegment(
            number: 0, startTime: nil, endTime: nil, durationS: nil, points: points
        )]))
        #expect(found.count == 1)
        #expect(abs((found.first?.stats.verticalM ?? 0) - 300) < 20)
    }

    /// The same two faults on a real day: the descents must not change.
    @Test func aRealDayKeepsItsRunsDespiteABadFirstFixAndAZeroAltitude() throws {
        let data = try Data(contentsOf: CorpusTests.log("2026-01-14-snowbasin.slopes"))
        let log = try SlopesParser.parse(data, honouringRunList: false).segments[0].points
        func descents(_ points: [TrackPoint]) -> [Descent] {
            DescentSegmenter.segments(ParsedActivity(source: .slopes, segments: [ParsedSegment(
                number: 1, startTime: nil, endTime: nil, durationS: nil, points: points
            )]))
        }
        let truth = descents(log)
        let middle = try #require(truth.first?.points[truth[0].points.count / 2].timestamp)

        var stale = try #require(log.first)
        stale.lat += 0.05
        stale.timestamp = stale.timestamp?.addingTimeInterval(-1)
        #expect(descents([stale] + log).map(DescentHasher.contentHash) == truth.map(DescentHasher.contentHash))

        var glitched = log
        let index = try #require(glitched.firstIndex { $0.timestamp == middle })
        glitched[index].elevationM = 0
        let found = descents(glitched)
        #expect(found.count == truth.count)
        let vertical = { (runs: [Descent]) in runs.reduce(0) { $0 + ($1.stats.verticalM ?? 0) } }
        #expect(abs(vertical(found) - vertical(truth)) < 5)
    }

    // MARK: Sport

    @Test func aBikeRideOrARunIsRefusedNotImportedAsSkiing() {
        let day = SyntheticTrack.day(laps: 2)
        let gpx = String(decoding: ExportWriters.gpx(day), as: UTF8.self)
            .replacingOccurrences(of: "<type>alpine_ski</type>", with: "<type>cycling</type>")
        let tcx = String(decoding: ExportWriters.tcx(day), as: UTF8.self)
            .replacingOccurrences(of: "Sport=\"Other\"", with: "Sport=\"Running\"")
        let refused = ActivityImportError.noDescents(.onlyVehicleOrLift)
        guard case .failure(let gpxError) = importing(Data(gpx.utf8), as: "ride.gpx"),
              case .failure(let tcxError) = importing(Data(tcx.utf8), as: "run.tcx") else {
            Issue.record("a non-ski activity was imported")
            return
        }
        #expect(gpxError == refused)
        #expect(tcxError == refused)
        guard case .success(let skiing) = importing(ExportWriters.tcx(day), as: "ski.tcx") else {
            Issue.record("a TCX with Sport=Other was refused")
            return
        }
        #expect(skiing.descents.count == 2)
    }

    // MARK: Archives

    /// A size under the old 256 MB cap used to be zero-filled up front.
    @Test func anEntryDeclaringAHugeSizeIsRefusedBeforeAnythingIsAllocated() throws {
        var archive = [UInt8](ExportWriters.zip([("GPS.csv", Data([0x03, 0x00]))]))
        let declared = UInt32(100 * 1_024 * 1_024)
        let size = [0, 8, 16, 24].map { UInt8((declared >> $0) & 0xFF) }
        // Method 8 (deflate) and the declared size, in the local and central headers.
        let central = archive.count - 22 - (46 + 7)
        archive[8] = 8
        archive[central + 10] = 8
        archive.replaceSubrange(22..<26, with: size)
        archive.replaceSubrange((central + 24)..<(central + 28), with: size)
        let reader = try ZipReader(data: Data(archive))
        #expect(throws: ZipReaderError.tooLarge(limit: ZipReader.maximumEntryBytes)) {
            try reader.read(reader.fileEntries[0])
        }
    }

    /// Finder re-zips an unzipped export inside a folder, with `._` resource
    /// forks beside it; the day must read as before.
    @Test func aSlopesExportRezippedInAFolderGivesTheSameDescents() throws {
        let name = "2026-01-14-snowbasin.slopes"
        let data = try Data(contentsOf: CorpusTests.log(name))
        let reader = try ZipReader(data: data)
        var entries = try reader.fileEntries.map { ("Day/" + $0.name, try reader.read($0)) }
        entries.insert(("__MACOSX/Day/._GPS.csv", Data(repeating: 0, count: 64)), at: 0)
        entries.insert(("Day/._RawGPS.csv", Data("1,2,3,4\n".utf8)), at: 0)
        let native = try ActivityImporter.importActivity(fileName: name, data: data)
        let wrapped = try ActivityImporter.importActivity(fileName: name, data: ExportWriters.zip(entries))
        #expect(wrapped.descents.map(DescentHasher.contentHash) == native.descents.map(DescentHasher.contentHash))
        #expect(wrapped.declared.runCount == native.declared.runCount)
    }

    /// Each listed run used to rescan the whole track; a list of windows that
    /// each cover the day would copy it once per run.
    @Test func aRunListCoveringTheTrackOverAndOverIsRefused() {
        let points = SyntheticTrack.day(laps: 3)
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return }
        let archive = ExportWriters.skiz(points, runs: Array(repeating: (first, last), count: 1_000))
        guard case .failure(.unreadable(.malformed)) = importing(archive, as: "day.skiz") else {
            Issue.record("an overlapping run list was not refused")
            return
        }
    }

    /// A legacy database whose location "table" is a view that never ends
    /// used to hang the import while its sort grew.
    @Test func aDatabaseThatNeverStopsAnsweringIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("descentkit-endless-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let schema = """
            CREATE VIEW ZRECORDEDLOCATION AS
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c)
            SELECT 39.6 AS ZLATITUDE, -106.5 AS ZLONGITUDE, 2800.0 AS ZALTITUDE, x AS ZTIMESTAMP FROM c;
            """
        #expect(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let data = try Data(contentsOf: url)
        guard case .failure(.unreadable(.malformed)) = importing(data, as: "old.slopes") else {
            Issue.record("an endless view was not refused")
            return
        }
    }
}
