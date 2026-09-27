import CoreLocation
import XCTest
@testable import PowderMeet

@MainActor
final class RouteProgressTrackerTests: XCTestCase {
    func testPolylineInteriorAdvancesProgressWithoutAJunction() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)

        let midpoint = CLLocationCoordinate2D(latitude: 40.005, longitude: -106)
        XCTAssertNil(tracker.update(location: midpoint))

        XCTAssertEqual(tracker.currentEdgeIndex, 0)
        XCTAssertEqual(tracker.currentEdgeFraction, 0.5, accuracy: 0.03)
        XCTAssertEqual(tracker.progress, 0.25, accuracy: 0.03)
        XCTAssertEqual(tracker.remainingRouteMeters, 1_500, accuracy: 30)
        XCTAssertFalse(tracker.isOffRoute)
    }

    func testNearestTargetNodeDoesNotAdvanceBeforeArrivalRadius() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        // About 122m before node b: b is the globally nearest node, but the
        // skier is still well outside the tracker's documented 80m arrival
        // radius and must remain on the current run.
        let beforeJunction = CLLocationCoordinate2D(
            latitude: 40.0089,
            longitude: -106
        )

        XCTAssertNil(tracker.update(location: beforeJunction))

        XCTAssertEqual(tracker.currentEdgeIndex, 0)
        XCTAssertGreaterThan(tracker.currentEdgeFraction, 0.85)
        XCTAssertLessThan(tracker.currentEdgeFraction, 0.93)
        XCTAssertFalse(tracker.isComplete)
    }

    func testPersistentFixFarFromRouteIsDeviationEvenWhenClosestNodeIsOnRoute() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        let far = CLLocationCoordinate2D(latitude: 40.005, longitude: -105.996)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(tracker.update(location: far, at: start))
        let event = tracker.update(location: far, at: start.addingTimeInterval(21))

        guard case .deviated? = event else {
            return XCTFail("Expected a persistent, physically distant fix to deviate")
        }
        XCTAssertTrue(tracker.isOffRoute)
    }

    func testManeuverDistanceUsesRemainingCurrentEdgeDistance() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        _ = tracker.update(location: CLLocationCoordinate2D(latitude: 40.005, longitude: -106))

        let viewModel = NavigationViewModel(
            tracker: tracker,
            profile: UserProfile(
                id: UUID(),
                displayName: "Test Skier",
                skillLevel: "intermediate",
                speedGreen: 7,
                speedBlue: 5,
                conditionMoguls: 1,
                conditionUngroomed: 1,
                conditionIcy: 1,
                conditionGladed: 1,
                onboardingCompleted: true
            ),
            graph: fixture.graph
        )

        XCTAssertEqual(viewModel.currentManeuver?.remainingMeters ?? -1, 500, accuracy: 30)
    }

    func testFractionalOriginSeedsRemainingDistanceWithoutPretendingMeetProgress() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(
            path: fixture.path,
            graph: fixture.graph,
            initialEdgeFraction: 0.5
        )

        XCTAssertEqual(tracker.currentEdgeFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(tracker.remainingRouteMeters, 1_500, accuracy: 1)
        XCTAssertEqual(tracker.progress, 0, accuracy: 0.001)

        _ = tracker.update(
            location: CLLocationCoordinate2D(latitude: 40.0075, longitude: -106)
        )

        XCTAssertEqual(tracker.currentEdgeFraction, 0.75, accuracy: 0.03)
        XCTAssertEqual(tracker.remainingRouteMeters, 1_250, accuracy: 30)
        XCTAssertEqual(tracker.progress, 1.0 / 6.0, accuracy: 0.03)
    }

    func testRepeatedFixesOnMiddleOfFutureEdgeConfirmShortcut() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        let middleOfFutureLift = CLLocationCoordinate2D(
            latitude: 40.015,
            longitude: -106
        )
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(tracker.update(location: middleOfFutureLift, at: start))
        XCTAssertNil(tracker.update(
            location: middleOfFutureLift,
            at: start.addingTimeInterval(2)
        ))
        let event = tracker.update(
            location: middleOfFutureLift,
            at: start.addingTimeInterval(4)
        )

        guard case .skippedAhead(let count)? = event else {
            return XCTFail("Expected repeated future-edge fixes to confirm a shortcut")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(tracker.currentEdgeIndex, 1)
        XCTAssertEqual(tracker.currentEdgeFraction, 0.5, accuracy: 0.03)
        XCTAssertFalse(tracker.isOffRoute)
    }

    func testSingleFutureEdgeFixCannotSkipRoute() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(tracker.update(
            location: .init(latitude: 40.015, longitude: -106),
            at: start
        ))
        XCTAssertNil(tracker.update(
            location: .init(latitude: 40.005, longitude: -106),
            at: start.addingTimeInterval(2)
        ))
        XCTAssertNil(tracker.update(
            location: .init(latitude: 40.015, longitude: -106),
            at: start.addingTimeInterval(6)
        ))

        XCTAssertEqual(tracker.currentEdgeIndex, 0)
        XCTAssertEqual(tracker.currentEdgeFraction, 0.5, accuracy: 0.03)
    }

    func testSingleFutureTargetFixCannotSkipOrCompleteRoute() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)

        XCTAssertNil(tracker.update(
            location: fixture.path.last!.geometry.last!,
            at: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(tracker.currentEdgeIndex, 0)
        XCTAssertFalse(tracker.isComplete)
        XCTAssertEqual(tracker.progress, 0, accuracy: 0.001)
    }

    func testRepeatedFutureTargetFixesConfirmShortcutBeforeCompletion() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        let meeting = fixture.path.last!.geometry.last!
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(tracker.update(location: meeting, at: start))
        XCTAssertNil(tracker.update(
            location: meeting,
            at: start.addingTimeInterval(2)
        ))
        let event = tracker.update(
            location: meeting,
            at: start.addingTimeInterval(4)
        )

        guard case .completed? = event else {
            return XCTFail("Expected sustained future-target evidence to complete the shortcut")
        }
        XCTAssertEqual(tracker.currentEdgeIndex, fixture.path.count)
        XCTAssertTrue(tracker.isComplete)
        XCTAssertEqual(tracker.progress, 1, accuracy: 0.001)
    }

    func testReplayedCaptureDoesNotCountTowardShortcutConfirmation() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        let meeting = fixture.path.last!.geometry.last!
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(tracker.update(location: meeting, at: start))
        for _ in 0..<5 {
            XCTAssertNil(tracker.update(location: meeting, at: start))
        }
        XCTAssertNil(tracker.update(location: meeting, at: start.addingTimeInterval(4)))
        XCTAssertFalse(tracker.isComplete)
        guard case .completed? = tracker.update(
            location: meeting,
            at: start.addingTimeInterval(6)
        ) else {
            return XCTFail("Three distinct captures should still confirm a real shortcut")
        }
    }

    func testOutOfOrderCaptureCannotAdvanceToAJunction() {
        let fixture = routeFixture()
        let tracker = RouteProgressTracker(path: fixture.path, graph: fixture.graph)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(tracker.update(
            location: .init(latitude: 40.005, longitude: -106),
            at: now
        ))
        let fraction = tracker.currentEdgeFraction

        XCTAssertNil(tracker.update(
            location: fixture.path[0].geometry.last!,
            at: now.addingTimeInterval(-1)
        ))

        XCTAssertEqual(tracker.currentEdgeIndex, 0)
        XCTAssertEqual(tracker.currentEdgeFraction, fraction)
        XCTAssertFalse(tracker.isComplete)
    }

    private func routeFixture() -> (graph: MountainGraph, path: [GraphEdge]) {
        let a = GraphNode(id: "a", coordinate: .init(latitude: 40, longitude: -106), elevation: 2_000, kind: .trailHead)
        let b = GraphNode(id: "b", coordinate: .init(latitude: 40.01, longitude: -106), elevation: 1_800, kind: .liftBase)
        let c = GraphNode(id: "c", coordinate: .init(latitude: 40.02, longitude: -106), elevation: 2_000, kind: .liftTop)

        let run = GraphEdge(
            id: "run",
            sourceID: a.id,
            targetID: b.id,
            kind: .run,
            geometry: [a.coordinate, b.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                trailName: "Creekside",
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        let lift = GraphEdge(
            id: "lift",
            sourceID: b.id,
            targetID: c.id,
            kind: .lift,
            geometry: [b.coordinate, c.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 1_000,
                trailName: "Peak Chair",
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, c.id: c],
            edges: [run, lift]
        )
        return (graph, [run, lift])
    }
}
