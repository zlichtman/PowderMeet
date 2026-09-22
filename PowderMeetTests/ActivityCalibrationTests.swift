//
//  ActivityCalibrationTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class ActivityCalibrationTests: XCTestCase {
    func testRouteMatchWithoutTimedPacePreservesHistoryButCannotTrain() {
        let evidence = RecordedPaceEvidence(confidence: 0.99, observations: [])
        XCTAssertEqual(evidence.method, RecordedPaceEvidence.routeOnlyMethod)
        // Also excludes the existing server's >= 0.75 legacy pace fallback.
        XCTAssertEqual(evidence.confidence, 0)
        let row = run(id: "edge", difficulty: .blue, speed: 20,
                      confidence: evidence.confidence, duration: 120, observations: [])
        XCTAssertFalse(row.isLearningEligible)
        XCTAssertFalse(row.isProfileCalibrationEligible)
        XCTAssertTrue(ActivityCalibration.medianSpeeds(from: [row]).isEmpty)
        XCTAssertEqual(row.edgeId, "edge")
        XCTAssertEqual(row.matchedSegmentIDs, ["edge"])
        XCTAssertEqual(row.datasetVersion, "m1-v11-sha")
        XCTAssertEqual(row.speed, 20)
        XCTAssertEqual(row.duration, 120)
        XCTAssertEqual(row.trailName, "Test")
        XCTAssertTrue(row.edgePaceObservations.isEmpty)
        XCTAssertNil(RecordedPaceEvidence.legacyEdgeID(row.edgeId, method: evidence.method))
    }

    func testTimedPaceKeepsOriginalMatchConfidenceWithoutPromotingWeakMatches() {
        let observations = [EdgePaceObservation(
            edgeId: "edge", speedMs: 8, peakSpeedMs: 10, durationS: 10, distanceM: 80
        )]
        for confidence in [0.4, 0.74, 0.9, 1.0] {
            let evidence = RecordedPaceEvidence(confidence: confidence, observations: observations)
            XCTAssertEqual(evidence.confidence, confidence)
            XCTAssertEqual(evidence.method, "polyline_sequence")
            let row = run(id: "edge", difficulty: .blue, speed: 20,
                          confidence: evidence.confidence, observations: observations)
            XCTAssertEqual(row.isProfileCalibrationEligible, confidence >= 0.75)
            XCTAssertEqual(RecordedPaceEvidence.legacyEdgeID("edge", method: evidence.method), "edge")
        }
    }

    func testActivityCalibrationCannotOverrideExplicitTerrainAvoidance() {
        XCTAssertNil(ActivityCalibration.mergedTerrainPreference(
            existing: 0,
            inferred: 1.4
        ))
        XCTAssertEqual(
            ActivityCalibration.mergedTerrainPreference(
                existing: 0.5,
                inferred: 1,
                observationWeight: 0.6
            ) ?? 0,
            0.8,
            accuracy: 0.001
        )
    }

    private func run(
        id: String = UUID().uuidString,
        difficulty: RunDifficulty,
        speed: Double,
        moguls: Bool = false,
        groomed: Bool? = true,
        gladed: Bool = false,
        width: Double? = 25,
        exposure: Double? = 0.2,
        datasetVersion: String? = "m1-v11-sha",
        confidence: Double = 1,
        duration: TimeInterval = 60,
        matchedSegmentIDs: [String]? = nil,
        observations: [EdgePaceObservation]? = nil
    ) -> MatchedRun {
        MatchedRun(
            edgeId: id,
            datasetVersion: datasetVersion,
            matchedSegmentIDs: matchedSegmentIDs ?? [id],
            edgePaceObservations: observations ?? [EdgePaceObservation(
                edgeId: id, speedMs: speed, peakSpeedMs: speed,
                durationS: duration, distanceM: speed * duration
            )],
            matchConfidence: confidence,
            matchMethod: "polyline_sequence",
            difficulty: difficulty,
            speed: speed,
            peakSpeed: speed,
            duration: duration,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            trailName: "Test",
            hasMoguls: moguls,
            isGroomed: groomed,
            isGladed: gladed,
            widthMeters: width,
            fallLineExposure: exposure,
            source: .gpx,
            sourceFileHash: "source"
        )
    }

    func testProfileUsesForwardObservationWithoutChangingActivitySummary() {
        let row = run(id: "partial", difficulty: .blue, speed: 20, duration: 120,
                      observations: [EdgePaceObservation(
                        edgeId: "partial", speedMs: 8, peakSpeedMs: 10,
                        durationS: 10, distanceM: 80
                      )])
        XCTAssertEqual(ActivityCalibration.medianSpeeds(from: [row])[.blue], 8)
        XCTAssertEqual(row.speed, 20)
        XCTAssertEqual(row.duration, 120)
    }

    func testMissingOrInvalidPaceCannotFallBackToWholeRunAverage() {
        let invalid: [[EdgePaceObservation]] = [
            [],
            [EdgePaceObservation(edgeId: "other", speedMs: 8, peakSpeedMs: 8, durationS: 10, distanceM: 80)],
            [EdgePaceObservation(edgeId: "edge", speedMs: 8, peakSpeedMs: 8, durationS: 10, distanceM: 800)],
            [EdgePaceObservation(edgeId: "edge", speedMs: .nan, peakSpeedMs: 8, durationS: 10, distanceM: 80)],
            [EdgePaceObservation(edgeId: "edge", speedMs: 8, peakSpeedMs: 8, durationS: 1, distanceM: 8)],
            [EdgePaceObservation(edgeId: "edge", speedMs: 8, peakSpeedMs: 8, durationS: 100, distanceM: 800)],
            Array(repeating: EdgePaceObservation(edgeId: "edge", speedMs: 8, peakSpeedMs: 8, durationS: 10, distanceM: 80), count: 2)
        ]
        for observations in invalid {
            let row = run(id: "edge", difficulty: .blue, speed: 20, observations: observations)
            XCTAssertFalse(row.isProfileCalibrationEligible)
            XCTAssertTrue(ActivityCalibration.medianSpeeds(from: [row]).isEmpty)
        }
    }

    func testTerrainRatiosUseForwardPaceInsteadOfRawSummary() {
        let rows = (0..<6).map { index in
            let id = "edge-\(index)"
            let measured = index < 3 ? 8.0 : 10.0
            return run(id: id, difficulty: .blue, speed: 20, moguls: index < 3,
                       observations: [EdgePaceObservation(
                        edgeId: id, speedMs: measured, peakSpeedMs: measured,
                        durationS: 10, distanceM: measured * 10
                       )])
        }
        XCTAssertEqual(ActivityCalibration.inferConditionPreferences(from: rows).mogulRatio ?? 0,
                       0.8, accuracy: 0.001)
    }

    func testConditionInferenceDoesNotCompareDifferentDifficulties() {
        let blueMoguls = (0..<3).map {
            run(id: "bm\($0)", difficulty: .blue, speed: 8, moguls: true)
        }
        let blackGroomers = (0..<3).map {
            run(id: "bn\($0)", difficulty: .black, speed: 12, moguls: false)
        }

        let inference = ActivityCalibration.inferConditionPreferences(
            from: blueMoguls + blackGroomers
        )

        XCTAssertNil(inference.mogulRatio)
    }

    func testConditionInferenceUsesWithinDifficultyRatios() {
        let blueMoguls = (0..<3).map {
            run(id: "m\($0)", difficulty: .blue, speed: 8, moguls: true)
        }
        let blueControls = (0..<3).map {
            run(id: "c\($0)", difficulty: .blue, speed: 10, moguls: false)
        }

        let inference = ActivityCalibration.inferConditionPreferences(
            from: blueMoguls + blueControls
        )

        XCTAssertEqual(inference.mogulRatio ?? 0, 0.8, accuracy: 0.001)
    }

    func testUnknownGroomingDoesNotMasqueradeAsUngroomed() {
        let unknown = (0..<3).map {
            run(
                id: "u\($0)",
                difficulty: .blue,
                speed: 4,
                groomed: nil
            )
        }
        let groomed = (0..<3).map {
            run(
                id: "g\($0)",
                difficulty: .blue,
                speed: 10,
                groomed: true
            )
        }

        let inference = ActivityCalibration.inferConditionPreferences(
            from: unknown + groomed
        )

        XCTAssertNil(inference.ungroomedRatio)
    }

    func testMedianSpeedsExcludeUnversionedAndLowConfidenceRows() {
        let rows = [
            run(id: "valid", difficulty: .blue, speed: 8),
            run(
                id: "legacy",
                difficulty: .blue,
                speed: 30,
                datasetVersion: nil
            ),
            run(
                id: "guess",
                difficulty: .blue,
                speed: 30,
                confidence: 0.4
            )
        ]

        XCTAssertEqual(
            ActivityCalibration.medianSpeeds(from: rows)[.blue],
            8
        )
    }

    func testLearningEligibilityMatchesDatabaseMetricAndIdentityGates() {
        let valid = run(id: "valid", difficulty: .blue, speed: 8)
        let tooFast = run(
            id: "fast",
            difficulty: .blue,
            speed: GPXSpeedStats.peakSpeedCeiling + 0.01
        )
        let tooLong = run(
            id: "long",
            difficulty: .blue,
            speed: 8,
            duration: GPXSpeedStats.maximumLearningDuration + 1
        )
        let blankDataset = run(
            id: "blank-version",
            difficulty: .blue,
            speed: 8,
            datasetVersion: "  "
        )
        let blankTopology = run(id: "  ", difficulty: .blue, speed: 8)

        XCTAssertTrue(valid.isLearningEligible)
        XCTAssertFalse(tooFast.isLearningEligible)
        XCTAssertFalse(tooLong.isLearningEligible)
        XCTAssertFalse(blankDataset.isLearningEligible)
        XCTAssertFalse(blankTopology.isLearningEligible)
        XCTAssertEqual(
            ActivityCalibration.medianSpeeds(
                from: [valid, tooFast, tooLong, blankDataset, blankTopology]
            )[.blue],
            8
        )
    }

    func testImplausibleRowsCannotSatisfyConditionSampleMinimum() {
        let condition = (0..<2).map {
            run(id: "m\($0)", difficulty: .blue, speed: 8, moguls: true)
        } + [
            run(id: "m-fast", difficulty: .blue, speed: 31, moguls: true)
        ]
        let control = (0..<2).map {
            run(id: "c\($0)", difficulty: .blue, speed: 10, moguls: false)
        } + [
            run(
                id: "c-long",
                difficulty: .blue,
                speed: 10,
                moguls: false,
                duration: GPXSpeedStats.maximumLearningDuration + 1
            )
        ]

        XCTAssertNil(
            ActivityCalibration.inferConditionPreferences(
                from: condition + control
            ).mogulRatio
        )
    }

    func testMultiEdgeRunTrainsExactEdgesButNotPrimaryDifficultyBucket() {
        let multiEdge = run(
            id: "primary-blue",
            difficulty: .blue,
            speed: 19,
            matchedSegmentIDs: ["primary-blue", "black-finish"]
        )
        let singleEdge = run(
            id: "single-blue",
            difficulty: .blue,
            speed: 8
        )

        XCTAssertTrue(multiEdge.isLearningEligible)
        XCTAssertFalse(multiEdge.isProfileCalibrationEligible)
        XCTAssertEqual(
            ActivityCalibration.medianSpeeds(from: [multiEdge, singleEdge])[.blue],
            8
        )
    }
}
