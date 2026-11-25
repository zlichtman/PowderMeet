import Foundation
import Testing
@testable import DescentKit

/// One test per import failure the corpus or the format survey turned up.
struct ImportTests {
    private func descents(_ points: [TrackPoint]) -> [Descent] {
        DescentSegmenter.segments(ParsedActivity(source: .live, segments: [ParsedSegment(
            number: 0, startTime: nil, endTime: nil, durationS: nil, points: points
        )]))
    }

    private func importing(_ data: Data, as name: String?) -> Result<ImportedActivity, ActivityImportError> {
        do {
            return .success(try ActivityImporter.importActivity(fileName: name, data: data))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Segmentation

    @Test func liftRidesAreNotRunsAndEachLapIsOneRun() {
        let found = descents(SyntheticTrack.day(laps: 4))
        #expect(found.count == 4)
        for descent in found {
            #expect(abs((descent.stats.verticalM ?? 0) - 300) < 20)
        }
    }

    /// Splitting at every pause would cut one run in two.
    @Test func aStopInTheMiddleDoesNotSplitARun() {
        var points = [SyntheticTrack.origin]
        points += SyntheticTrack.lift(from: points[points.count - 1], climbM: 400, seconds: 500)
        points += SyntheticTrack.run(from: points[points.count - 1], dropM: 200, seconds: 120)
        points += SyntheticTrack.wait(at: points[points.count - 1], seconds: 420)
        points += SyntheticTrack.run(from: points[points.count - 1], dropM: 200, seconds: 120)
        points += SyntheticTrack.wait(at: points[points.count - 1], seconds: 60)
        let found = descents(points)
        #expect(found.count == 1)
        #expect(abs((found.first?.stats.verticalM ?? 0) - 400) < 25)
    }

    @Test func aDriveDownTheCanyonIsNotARun() {
        var points = SyntheticTrack.day(laps: 2)
        // Skis off, then 20 m/s on a 5 % road for ten minutes, with no climb
        // between the last run and the drive.
        points += SyntheticTrack.wait(at: points[points.count - 1], seconds: 240)
        let start = points[points.count - 1]
        points += (1...600).map { second in
            TrackPoint(
                lat: start.lat - Double(second) * 20 / 111_320,
                lon: start.lon + 0.002 * sin(Double(second) / 40),
                elevationM: (start.elevationM ?? 0) - Double(second),
                timestamp: start.timestamp?.addingTimeInterval(Double(second))
            )
        }
        let outcome = DescentSegmenter.analyze(ParsedActivity(source: .gpx, segments: [ParsedSegment(
            number: 1, startTime: nil, endTime: nil, durationS: nil, points: points
        )]))
        #expect(outcome.descents.count == 2)
        #expect(outcome.rejected[.vehicle] == 1)
    }

    @Test func aGondolaRiddenDownIsNotARun() {
        var points = SyntheticTrack.day(laps: 2)
        points += SyntheticTrack.lift(from: points[points.count - 1], climbM: 300, seconds: 400)
        // Download: the same steady straight line, descending.
        points += SyntheticTrack.lift(from: points[points.count - 1], climbM: -300, seconds: 300, speedMS: 4.5)
        let outcome = DescentSegmenter.analyze(ParsedActivity(source: .gpx, segments: [ParsedSegment(
            number: 1, startTime: nil, endTime: nil, durationS: nil, points: points
        )]))
        #expect(outcome.descents.count == 2)
        #expect(outcome.rejected[.liftDownhill] == 1)
    }

    @Test func repeatedFixesSpikesAndUnorderedPointsAreCleaned() {
        var points = SyntheticTrack.day(laps: 3)
        let clean = descents(points).count
        // Every tenth fix written twice, one fix thrown 5 km away, and the
        // file order scrambled.
        var dirty: [TrackPoint] = []
        for (index, point) in points.enumerated() {
            dirty.append(point)
            if index % 10 == 0 { dirty.append(point) }
        }
        dirty[700].lat += 0.05
        dirty.swapAt(100, 900)
        dirty.swapAt(250, 1_300)
        points = dirty
        #expect(descents(points).count == clean)
        #expect(clean == 3)
    }

    @Test func twoDaysInOneFileAreBothImportedAndFlagged() throws {
        var second = SyntheticTrack.origin
        second.timestamp = SyntheticTrack.base.addingTimeInterval(22 * 3_600)
        let points = SyntheticTrack.day(laps: 2) + SyntheticTrack.day(laps: 3, from: second)
        let result = try ActivityImporter.importActivity(fileName: "trip.gpx", data: ExportWriters.gpx(points))
        #expect(result.descents.count == 5)
        #expect(result.warnings.contains(.multipleDays(2)))
    }

    // MARK: Errors and warnings

    @Test func aRouteWithNoTimesIsRefusedWithAReason() {
        let data = ExportWriters.gpx(SyntheticTrack.day(laps: 2), time: false)
        #expect(importing(data, as: "route.gpx").failureValue == .noTimestamps)
    }

    @Test func aTrackWithNoElevationIsRefusedWithAReason() {
        let data = ExportWriters.gpx(SyntheticTrack.day(laps: 2), elevation: false)
        #expect(importing(data, as: "flat.gpx").failureValue == .noElevation)
        // Loggers without a barometer often write zero for every fix.
        let zeroed = SyntheticTrack.day(laps: 2).map { point in
            var copy = point
            copy.elevationM = 0
            return copy
        }
        #expect(importing(ExportWriters.gpx(zeroed), as: "zero.gpx").failureValue == .noElevation)
    }

    @Test func aGapInElevationIsInterpolatedAndFlagged() throws {
        var points = SyntheticTrack.day(laps: 3)
        for index in points.indices where index % 4 != 0 { points[index].elevationM = nil }
        let result = try ActivityImporter.importActivity(fileName: "gaps.gpx", data: ExportWriters.gpx(points))
        #expect(result.descents.count == 3)
        #expect(result.warnings.contains { warning in
            if case .elevationInterpolated(let share) = warning { return share > 0.7 }
            return false
        })
    }

    @Test func timesWithNoZoneAreReadAsUTCAndFlagged() throws {
        let points = SyntheticTrack.day(laps: 2)
        let result = try ActivityImporter.importActivity(
            fileName: "nozone.gpx", data: ExportWriters.gpx(points, zone: false)
        )
        #expect(result.descents.count == 2)
        #expect(result.warnings.contains(.timeZoneAssumedUTC))
        let zoned = try ActivityImporter.importActivity(fileName: "zone.gpx", data: ExportWriters.gpx(points))
        #expect(result.descents.first?.startedAt == zoned.descents.first?.startedAt)
        #expect(!zoned.warnings.contains(.timeZoneAssumedUTC))
    }

    /// A logger with no zone writes the mountain's clock: once the resort's
    /// zone is known the runs land at the instant they were skied, in winter
    /// and in summer time.
    @Test(arguments: [0.0, 180 * 86_400.0])
    func timesWithNoZoneAreReadInTheResortsZone(daysLater: Double) throws {
        let denver = try #require(TimeZone(identifier: "America/Denver"))
        let points = SyntheticTrack.day(laps: 2).map { point in
            var point = point
            point.timestamp = point.timestamp.map { $0 + daysLater }
            return point
        }
        let offset = TimeInterval(denver.secondsFromGMT(for: try #require(points.first?.timestamp)))
        // The file's clock times are Denver's, written with no zone.
        let clock = points.map { point in
            var point = point
            point.timestamp = point.timestamp.map { $0 + offset }
            return point
        }
        let unzoned = try ActivityImporter.importActivity(
            fileName: "nozone.gpx", data: ExportWriters.gpx(clock, zone: false)
        ).readingUnzonedTimes(in: denver)
        let zoned = try ActivityImporter.importActivity(fileName: "zone.gpx", data: ExportWriters.gpx(points))
        #expect(unzoned.descents.map(\.startedAt) == zoned.descents.map(\.startedAt))
        #expect(unzoned.descents.map(\.endedAt) == zoned.descents.map(\.endedAt))
        #expect(unzoned.descents.first?.points.first?.timestamp == zoned.descents.first?.points.first?.timestamp)
        #expect(!unzoned.warnings.contains(.timeZoneAssumedUTC))
        // A file that gave its zone is left as it is.
        #expect(zoned.readingUnzonedTimes(in: denver).descents.map(\.startedAt) == zoned.descents.map(\.startedAt))
    }

    @Test func aWalkOnTheFlatHasNoDescents() {
        let walk = (0..<900).map { second in
            TrackPoint(
                lat: 39.6 + Double(second) * 1.2 / 111_320, lon: -106.5,
                elevationM: 2_800 + 2 * sin(Double(second) / 50),
                timestamp: SyntheticTrack.base.addingTimeInterval(Double(second))
            )
        }
        #expect(importing(ExportWriters.gpx(walk), as: "walk.gpx").failureValue == .noDescents(.flatTrack))
    }

    @Test func unreadableFilesGiveSpecificErrors() {
        #expect(importing(Data("hello".utf8), as: "notes.txt").failureValue == .unrecognizedFormat)
        #expect(importing(Data("<gpx><trk>".utf8), as: "cut.gpx").failureValue.map(isUnreadable) == true)
        let empty = Data("<gpx version=\"1.1\"><trk><trkseg></trkseg></trk></gpx>".utf8)
        #expect(importing(empty, as: "empty.gpx").failureValue == .noTrack)
        let photos = ExportWriters.zip([("holiday.jpg", Data([1, 2, 3]))])
        #expect(importing(photos, as: "photos.slopes").failureValue == .unreadable(.unknownArchive))
        var fit = [UInt8](ExportWriters.fit(SyntheticTrack.day(laps: 1)))
        fit[40] ^= 0xFF
        #expect(importing(Data(fit), as: "bad.fit").failureValue == .unreadable(.malformed("corrupt FIT member")))
    }

    @Test func aWrongExtensionIsReadByItsContent() throws {
        let tcx = ExportWriters.tcx(SyntheticTrack.day(laps: 2))
        let result = try ActivityImporter.importActivity(fileName: "activity.gpx", data: tcx)
        #expect(result.format == .tcx)
        #expect(result.descents.count == 2)
    }

    // MARK: FIT

    /// Laps are global message 19, not 21 (event), which a reader can take
    /// for laps and then never see one. They are reported, never used as runs.
    @Test func fitReportsItsMakerSportAndLapsButFindsRunsItself() throws {
        var options = ExportWriters.FITOptions()
        options.manufacturer = 294
        options.sport = 14
        options.laps = 9
        options.sessionDescentM = 1_190
        let result = try ActivityImporter.importActivity(
            fileName: "day.fit", data: ExportWriters.fit(SyntheticTrack.day(laps: 4), options: options)
        )
        #expect(result.sourceApp == "Coros")
        #expect(result.declared.sport == "snowboarding")
        #expect(result.declared.runCount == 9)
        #expect(result.declared.verticalM == 1_190)
        #expect(result.descents.count == 4)
    }

    @Test func fitAltitudeInADeveloperFieldIsUsed() throws {
        var options = ExportWriters.FITOptions()
        options.altitudeAsDeveloperField = true
        let result = try ActivityImporter.importActivity(
            fileName: "dev.fit", data: ExportWriters.fit(SyntheticTrack.day(laps: 3), options: options)
        )
        #expect(result.descents.count == 3)
        #expect(result.descents.first?.points.first?.elevationM != nil)
    }

    @Test func fitWithAZeroFileChecksumIsAccepted() throws {
        var options = ExportWriters.FITOptions()
        options.zeroFileCRC = true
        let result = try ActivityImporter.importActivity(
            fileName: "phone.fit", data: ExportWriters.fit(SyntheticTrack.day(laps: 2), options: options)
        )
        #expect(result.descents.count == 2)
    }

    // MARK: Ski Tracks

    @Test func skizUsesItsRunListAndReportsItsTotals() throws {
        let points = SyntheticTrack.day(laps: 3)
        let truth = descents(points)
        let archive = ExportWriters.skiz(points, runs: truth.map { ($0.startedAt, $0.endedAt) }, declaredDescents: 3)
        #expect(ActivityFormat.detect(fileName: nil, data: archive) == .skiz)
        let result = try ActivityImporter.importActivity(fileName: "day.skiz", data: archive)
        #expect(result.sourceApp == "Ski Tracks")
        #expect(result.resortName == "Day at the hill")
        #expect(result.declared.runCount == 3)
        #expect(result.descents.count == 3)
    }

    /// The format is unpublished, so a run list that does not line up with
    /// the GPS log must not cost the skier their day.
    @Test func skizWithAMisalignedRunListFallsBackToTheGPSLog() throws {
        let points = SyntheticTrack.day(laps: 3)
        let truth = descents(points)
        let archive = ExportWriters.skiz(
            points, runs: truth.map { ($0.startedAt, $0.endedAt) }, segmentClockOffsetS: 5 * 86_400
        )
        let result = try ActivityImporter.importActivity(fileName: "day.skiz", data: archive)
        #expect(result.descents.count == 3)
    }

    @Test(arguments: ["1e30", "nan", "inf"])
    func skizWithAnImpossibleDescentCountStillImports(_ text: String) throws {
        let points = SyntheticTrack.day(laps: 3)
        let truth = descents(points)
        let archive = ExportWriters.skiz(points, runs: truth.map { ($0.startedAt, $0.endedAt) }, descentsText: text)
        let result = try ActivityImporter.importActivity(fileName: "day.skiz", data: archive)
        #expect(result.declared.runCount == nil)
    }

    @Test func slopesActionDatesWithAnAbsurdYearAreRefusedNotTrapped() {
        #expect(SlopesMetadata.date("999999999999999-01-01 00:00:00 +0000") == nil)
        #expect(SlopesMetadata.date("-9223372036854775808-01-01 00:00:00 +0000") == nil)
        #expect(SlopesMetadata.date("2026-01-10 11:34:26 -0600") != nil)
    }

    // MARK: The same day from two apps

    /// A real Slopes day, re-exported the way each other format would carry
    /// it, must come back as the same descents and be recognised as already
    /// imported.
    @Test func theSameDayFromAnotherAppIsRecognisedAsOneDay() throws {
        let name = "2026-01-14-snowbasin.slopes"
        let url = CorpusTests.log(name)
        let data = try Data(contentsOf: url)
        let native = try ActivityImporter.importActivity(fileName: name, data: data)
        let nativeHashes = Set(native.descents.map(DescentHasher.contentHash))
        let log = try SlopesParser.parse(data, honouringRunList: false).segments[0].points
        let ordered = DescentSegmenter.normalizedPoints(log)

        // Exports round times to the second and positions to six places, so
        // the content hashes differ and the time-and-place rule has to catch
        // the repeat. The server's own rule (more than 80 % of the longer
        // descent shared) is checked too, since it is the last line of defence.
        let exports: [(String, Data)] = [
            ("strava.gpx", ExportWriters.gpx(ordered)),
            ("garmin.tcx", ExportWriters.tcx(ordered)),
            ("watch.fit", ExportWriters.fit(ordered)),
            ("day.skiz", ExportWriters.skiz(ordered, runs: native.descents.map { ($0.startedAt, $0.endedAt) })),
        ]
        for (fileName, export) in exports {
            let other = try ActivityImporter.importActivity(fileName: fileName, data: export)
            #expect(other.descents.count == native.descents.count, "\(fileName)")
            #expect(DescentDeduplicator.repeatedShare(of: other.descents, in: native.descents) == 1, "\(fileName)")
            #expect(DescentDeduplicator.repeatedShare(of: native.descents, in: other.descents) == 1, "\(fileName)")
            #expect(other.descents.allSatisfy { !nativeHashes.contains(DescentHasher.contentHash($0)) }, "\(fileName)")
            let caughtByServerRule = other.descents.filter { descent in
                native.descents.contains { existing in
                    let shared = min(descent.endedAt, existing.endedAt)
                        .timeIntervalSince(max(descent.startedAt, existing.startedAt))
                    let longer = max(
                        descent.endedAt.timeIntervalSince(descent.startedAt),
                        existing.endedAt.timeIntervalSince(existing.startedAt)
                    )
                    return shared > 0.8 * longer
                }
            }.count
            #expect(caughtByServerRule == other.descents.count, "\(fileName): server rule catches \(caughtByServerRule) of \(other.descents.count)")
        }
    }

    /// Two skiers who recorded the same day at the same resort are not each
    /// other's duplicates, even where they rode and skied together.
    @Test func twoPhonesOnTheSameDayAreNotMistakenForOneRecording() throws {
        let pairs = [
            ("2026-01-12-kirkwood.slopes", "2026-01-12-kirkwood-2.slopes"),
        ]
        for (first, second) in pairs {
            let a = try CorpusTests.imported(CorpusTests.log(first))
            let b = try CorpusTests.imported(CorpusTests.log(second))
            #expect(DescentDeduplicator.repeatedShare(of: a.descents, in: b.descents) < 0.5, "\(first)")
        }
    }
}

private func isUnreadable(_ error: ActivityImportError) -> Bool {
    if case .unreadable = error { return true }
    return false
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@Test func aStoredTrackReadsBackAsTheSamePoints() throws {
    let start = Date(timeIntervalSince1970: 1_768_000_000.4)
    var points: [TrackPoint] = []
    for index in 0..<200 {
        let step = Double(index)
        let elevation: Double? = index == 17 ? nil : 1_900 - step * 1.37
        points.append(TrackPoint(
            lat: 50.1 - step * 0.00001234, lon: -122.95 + step * 0.0000071,
            elevationM: elevation, timestamp: start.addingTimeInterval(step * 1.5)
        ))
    }
    let descent = Descent(
        source: .gpx, startedAt: start, endedAt: start.addingTimeInterval(298.5), points: points
    )
    let decoded = try DescentTrackCodec.decode(try DescentTrackCodec.encode(descent))

    #expect(decoded.count == points.count)
    for (stored, original) in zip(decoded, points) {
        #expect(abs(stored.lat - original.lat) < 1e-6)
        #expect(abs(stored.lon - original.lon) < 1e-6)
        #expect((stored.elevationM == nil) == (original.elevationM == nil))
        if let a = stored.elevationM, let b = original.elevationM { #expect(abs(a - b) < 0.06) }
        let drift = stored.timestamp!.timeIntervalSince(original.timestamp!)
        #expect(abs(drift) <= 0.1)
    }
}
