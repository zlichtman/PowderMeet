import XCTest
@testable import PowderMeet

final class RouteSwitchPolicyTests: XCTestCase {
    func testSameRouteNeverResetsNavigationForTimingNoise() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 600,
                candidateSeconds: 300,
                currentRemainingEdgeIDs: ["run", "lift"],
                candidateEdgeIDs: ["run", "lift"],
                secondsSinceLastAppliedSwitch: nil
            ),
            .keepSamePath
        )
    }

    func testNormalSwitchRequiresAbsoluteAndProportionalGain() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 300,
                candidateSeconds: 271,
                currentRemainingEdgeIDs: ["old"],
                candidateEdgeIDs: ["new"],
                secondsSinceLastAppliedSwitch: nil
            ),
            .keepInsufficientGain(requiredSeconds: 30)
        )
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 1_200,
                candidateSeconds: 1_090,
                currentRemainingEdgeIDs: ["old"],
                candidateEdgeIDs: ["new"],
                secondsSinceLastAppliedSwitch: nil
            ),
            .keepInsufficientGain(requiredSeconds: 120)
        )
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 1_200,
                candidateSeconds: 1_080,
                currentRemainingEdgeIDs: ["old"],
                candidateEdgeIDs: ["new"],
                secondsSinceLastAppliedSwitch: nil
            ),
            .switchRoute(gainSeconds: 120)
        )
    }

    func testStabilityWindowPreventsBackAndForthRouteFlapping() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 600,
                candidateSeconds: 500,
                currentRemainingEdgeIDs: ["new-a"],
                candidateEdgeIDs: ["old-b"],
                secondsSinceLastAppliedSwitch: 0
            ),
            .keepDuringStabilityWindow(requiredSeconds: 120)
        )
    }

    func testLargeImprovementStillSwitchesInsideStabilityWindow() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 600,
                candidateSeconds: 450,
                currentRemainingEdgeIDs: ["current"],
                candidateEdgeIDs: ["shortcut"],
                secondsSinceLastAppliedSwitch: 0
            ),
            .switchRoute(gainSeconds: 150)
        )
    }

    func testStabilityThresholdDecaysContinuously() {
        let decision = RouteSwitchPolicy.decide(
            currentRemainingSeconds: 600,
            candidateSeconds: 510,
            currentRemainingEdgeIDs: ["current"],
            candidateEdgeIDs: ["candidate"],
            secondsSinceLastAppliedSwitch: 60
        )
        XCTAssertEqual(
            decision,
            .switchRoute(gainSeconds: 90)
        )
    }

    func testNearArrivalDoesNotSwapForAnOptimization() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 30,
                candidateSeconds: 0,
                currentRemainingEdgeIDs: ["final"],
                candidateEdgeIDs: [],
                secondsSinceLastAppliedSwitch: nil
            ),
            .keepNearArrival
        )
    }

    func testNominalShortcutCannotRegressDependableArrival() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 600,
                candidateSeconds: 500,
                currentUncertaintySeconds: 30,
                candidateUncertaintySeconds: 300,
                currentRemainingEdgeIDs: ["current"],
                candidateEdgeIDs: ["fragile-shortcut"],
                secondsSinceLastAppliedSwitch: nil
            ),
            .keepReliabilityRegression
        )
    }

    func testMeaningfulShortcutStillSwitchesWhenReliabilityImproves() {
        XCTAssertEqual(
            RouteSwitchPolicy.decide(
                currentRemainingSeconds: 600,
                candidateSeconds: 500,
                currentUncertaintySeconds: 300,
                candidateUncertaintySeconds: 30,
                currentRemainingEdgeIDs: ["current"],
                candidateEdgeIDs: ["dependable-shortcut"],
                secondsSinceLastAppliedSwitch: nil
            ),
            .switchRoute(gainSeconds: 100)
        )
    }
}
