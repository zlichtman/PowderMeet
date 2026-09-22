//
//  SkiActivitySegmenterTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class SkiActivitySegmenterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(
        second: TimeInterval,
        elevation: Double?,
        latitude: Double
    ) -> GPXTrackPoint {
        GPXTrackPoint(
            latitude: latitude,
            longitude: -106,
            elevation: elevation,
            timestamp: origin.addingTimeInterval(second)
        )
    }

    private func descent(
        startSecond: TimeInterval,
        startElevation: Double,
        startLatitude: Double,
        count: Int = 12
    ) -> [GPXTrackPoint] {
        (0..<count).map { index in
            point(
                second: startSecond + Double(index),
                elevation: startElevation - Double(index * 2),
                latitude: startLatitude - Double(index) * 0.00004
            )
        }
    }

    private func ascent(
        startSecond: TimeInterval,
        startElevation: Double,
        startLatitude: Double,
        count: Int = 12
    ) -> [GPXTrackPoint] {
        (0..<count).map { index in
            point(
                second: startSecond + Double(index),
                elevation: startElevation + Double(index * 2),
                latitude: startLatitude + Double(index) * 0.00002
            )
        }
    }

    private func sourceSegment(
        points: [GPXTrackPoint],
        avgSpeed: Double? = nil,
        topSpeed: Double? = nil,
        distance: Double? = nil,
        boundary: ActivitySegmentBoundary = .providerHint
    ) -> ParsedRunSegment {
        let start = points.first?.timestamp ?? origin
        let end = points.last?.timestamp ?? start
        return ParsedRunSegment(
            runNumber: 1,
            startTime: start,
            endTime: end,
            durationSeconds: max(1, end.timeIntervalSince(start)),
            topSpeedMS: topSpeed,
            avgSpeedMS: avgSpeed,
            distanceMeters: distance,
            verticalMeters: nil,
            points: points,
            boundary: boundary
        )
    }

    func testWholeDayHintBecomesTwoPhysicalDownhillRuns() {
        let first = descent(
            startSecond: 0,
            startElevation: 3_000,
            startLatitude: 39
        )
        let lift = ascent(
            startSecond: 12,
            startElevation: 2_978,
            startLatitude: first.last!.latitude
        )
        let second = descent(
            startSecond: 24,
            startElevation: 3_000,
            startLatitude: lift.last!.latitude
        )

        let runs = SkiActivitySegmenter.downhillRunSegments(
            from: [sourceSegment(points: first + lift + second)]
        )

        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.allSatisfy { ($0.verticalMeters ?? 0) >= 3 })
        XCTAssertEqual(runs.map(\.runNumber), [1, 2])
    }

    func testSingleProviderRunKeepsNativeStats() {
        let segment = sourceSegment(
            points: descent(
                startSecond: 0,
                startElevation: 3_000,
                startLatitude: 39
            ),
            avgSpeed: 7,
            topSpeed: 12,
            distance: 250
        )

        let runs = SkiActivitySegmenter.downhillRunSegments(from: [segment])

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].avgSpeedMS, 7)
        XCTAssertEqual(runs[0].topSpeedMS, 12)
        XCTAssertEqual(runs[0].distanceMeters, 250)
    }

    func testAuthoritativeSlopesRunSurvivesInternalElevationNoise() {
        let first = descent(
            startSecond: 0,
            startElevation: 3_000,
            startLatitude: 39
        )
        let noisyRise = ascent(
            startSecond: 12,
            startElevation: 2_978,
            startLatitude: first.last!.latitude,
            count: 8
        )
        let finalDescent = descent(
            startSecond: 20,
            startElevation: 2_994,
            startLatitude: noisyRise.last!.latitude
        )
        let providerRun = sourceSegment(
            points: first + noisyRise + finalDescent,
            avgSpeed: 8,
            topSpeed: 14,
            distance: 600,
            boundary: .authoritativeDownhillRun
        )

        let runs = SkiActivitySegmenter.downhillRunSegments(from: [providerRun])

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].avgSpeedMS, 8)
        XCTAssertEqual(runs[0].distanceMeters, 600)
        XCTAssertEqual(runs[0].boundary, .authoritativeDownhillRun)
    }

    func testPureUphillHintIsNotPersistedAsRun() {
        let runs = SkiActivitySegmenter.downhillRunSegments(
            from: [sourceSegment(points: ascent(
                startSecond: 0,
                startElevation: 2_900,
                startLatitude: 39
            ))]
        )
        XCTAssertTrue(runs.isEmpty)
    }

    func testTenSecondStationaryTraceIsNotPersistedAsRunAtOneHertz() {
        let points = (0..<15).map { index in
            point(second: Double(index), elevation: 3_000, latitude: 39)
        }

        let motion = SkiActivitySegmenter.motionSegments(points)
        let runs = SkiActivitySegmenter.downhillRunSegments(
            from: [sourceSegment(points: points)]
        )

        XCTAssertEqual(motion.map(\.kind), [.stationary])
        XCTAssertTrue(runs.isEmpty)
    }

    func testLongGapSeparatesTwoDescentsWithoutGraph() {
        let first = descent(
            startSecond: 0,
            startElevation: 3_000,
            startLatitude: 39
        )
        let second = descent(
            startSecond: 300,
            startElevation: 3_100,
            startLatitude: 39.01
        )

        let runs = SkiActivitySegmenter.downhillRunSegments(
            from: [sourceSegment(points: first + second)]
        )

        XCTAssertEqual(runs.count, 2)
    }

    func testInvalidCoordinatesAndImpossibleNativeStatsFailClosed() {
        var points = descent(
            startSecond: 0,
            startElevation: 3_000,
            startLatitude: 39
        )
        points.insert(
            point(second: 5.5, elevation: 2_990, latitude: .nan),
            at: 6
        )
        let segment = sourceSegment(
            points: points,
            avgSpeed: 100,
            topSpeed: 150,
            distance: 100_000
        )

        let runs = SkiActivitySegmenter.downhillRunSegments(from: [segment])

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].points.count, points.count - 1)
        XCTAssertNil(runs[0].avgSpeedMS)
        XCTAssertNil(runs[0].topSpeedMS)
        XCTAssertNil(runs[0].distanceMeters)
    }

    func testRunIdentityIsStableAndSeparatesRealUnmatchedRuns() {
        let timestamp = origin
        let first = ImportedRunIdentity.dedupHash(
            source: .gpx,
            timestamp: timestamp,
            duration: 40,
            resortID: "vail",
            edgeID: nil
        )
        let repeatValue = ImportedRunIdentity.dedupHash(
            source: .gpx,
            timestamp: timestamp,
            duration: 40,
            resortID: "vail",
            edgeID: nil
        )
        let distinctDuration = ImportedRunIdentity.dedupHash(
            source: .gpx,
            timestamp: timestamp,
            duration: 80,
            resortID: "vail",
            edgeID: nil
        )
        let otherSource = ImportedRunIdentity.dedupHash(
            source: .healthKit,
            timestamp: timestamp,
            duration: 40,
            resortID: "vail",
            edgeID: nil
        )

        XCTAssertEqual(first, repeatValue)
        XCTAssertNotEqual(first, distinctDuration)
        XCTAssertNotEqual(first, otherSource)
    }
}
