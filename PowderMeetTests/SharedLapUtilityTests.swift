//
//  SharedLapUtilityTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class SharedLapUtilityTests: XCTestCase {
    func testTerrainFitIsBoundedAndMonotonic() {
        let matched = SharedLapUtility.score(
            runLengthMeters: 800,
            verticalDropMeters: 300,
            actionTransitionCount: 0,
            downhillAccessSeconds: 0,
            jointTerrainFit: 1
        )
        let cautious = SharedLapUtility.score(
            runLengthMeters: 800,
            verticalDropMeters: 300,
            actionTransitionCount: 0,
            downhillAccessSeconds: 0,
            jointTerrainFit: 0.2
        )
        let clamped = SharedLapUtility.score(
            runLengthMeters: 800,
            verticalDropMeters: 300,
            actionTransitionCount: 0,
            downhillAccessSeconds: 0,
            jointTerrainFit: -10
        )

        XCTAssertGreaterThan(matched, cautious)
        XCTAssertGreaterThanOrEqual(cautious, clamped)
        XCTAssertGreaterThanOrEqual(clamped, 0)
        XCTAssertLessThanOrEqual(matched, 1)
        XCTAssertTrue(SharedLapUtility.isStrongFit(0.85))
        XCTAssertFalse(SharedLapUtility.isStrongFit(0.849))
    }

    func testOrdinaryAccessIsNeutralAndLongAccessPenaltyCaps() {
        func score(access: Double) -> Double {
            SharedLapUtility.score(
                runLengthMeters: 800,
                verticalDropMeters: 300,
                actionTransitionCount: 1,
                downhillAccessSeconds: access,
                jointTerrainFit: 1
            )
        }

        XCTAssertEqual(score(access: 0), score(access: 8 * 60), accuracy: 0.0001)
        XCTAssertGreaterThan(score(access: 8 * 60), score(access: 15 * 60))
        XCTAssertEqual(score(access: 23 * 60), score(access: 60 * 60), accuracy: 0.0001)
    }

    func testActionTransitionsNotRawSegmentCountDriveUtility() {
        let oneSegment = SharedLapUtility.score(
            runLengthMeters: 600,
            verticalDropMeters: 200,
            actionTransitionCount: 0,
            downhillAccessSeconds: 0,
            jointTerrainFit: 1
        )
        let samePhysicalRunSplitIntoThree = SharedLapUtility.score(
            runLengthMeters: 600,
            verticalDropMeters: 200,
            actionTransitionCount: 0,
            downhillAccessSeconds: 0,
            jointTerrainFit: 1
        )
        let liftThenRun = SharedLapUtility.score(
            runLengthMeters: 600,
            verticalDropMeters: 200,
            actionTransitionCount: 1,
            downhillAccessSeconds: 0,
            jointTerrainFit: 1
        )

        XCTAssertEqual(oneSegment, samePhysicalRunSplitIntoThree, accuracy: 0.0001)
        XCTAssertGreaterThan(oneSegment, liftThenRun)
    }

    func testRunVarietyBonusIsBoundedAndMonotonic() {
        let base = 0.50
        XCTAssertEqual(
            SharedLapUtility.scoreWithVariety(baseScore: base, optionCount: 1),
            base,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            SharedLapUtility.scoreWithVariety(baseScore: base, optionCount: 2),
            base
        )
        XCTAssertGreaterThan(
            SharedLapUtility.scoreWithVariety(baseScore: base, optionCount: 3),
            SharedLapUtility.scoreWithVariety(baseScore: base, optionCount: 2)
        )
        XCTAssertEqual(
            SharedLapUtility.scoreWithVariety(baseScore: base, optionCount: 3),
            SharedLapUtility.scoreWithVariety(baseScore: base, optionCount: 30),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SharedLapUtility.scoreWithVariety(baseScore: 0.99, optionCount: 3),
            1,
            accuracy: 0.0001
        )
    }

    func testRunOptionIdentityDeduplicatesCanonicalAndLegacySegments() {
        func run(_ id: String, name: String, groupID: String?) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: "source-\(id)",
                targetID: "target-\(id)",
                kind: .run,
                geometry: [],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 100,
                    verticalDrop: 20,
                    trailName: name,
                    isOpen: true,
                    trailGroupId: groupID
                )
            )
        }

        XCTAssertEqual(
            SharedLapUtility.optionIdentity(for: run("a", name: "Upper", groupID: "official-upper")),
            SharedLapUtility.optionIdentity(for: run("b", name: "Lower", groupID: "official-upper"))
        )
        XCTAssertEqual(
            SharedLapUtility.optionIdentity(for: run("c", name: "  Peak   To Creek ", groupID: nil)),
            SharedLapUtility.optionIdentity(for: run("d", name: "PEAK TO CREEK", groupID: nil))
        )
        XCTAssertNotEqual(
            SharedLapUtility.optionIdentity(for: run("e", name: "Peak to Creek", groupID: nil)),
            SharedLapUtility.optionIdentity(for: run("f", name: "Dave Murray Downhill", groupID: nil))
        )
    }
}
