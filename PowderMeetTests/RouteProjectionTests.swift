import CoreLocation
import XCTest
@testable import PowderMeet

final class RouteProjectionTests: XCTestCase {
    func testFractionalStartProjectsFromCurrentPositionAndChargesOnlyRemainder() throws {
        let a = GraphNode(id: "a", coordinate: .init(latitude: 40, longitude: -106), elevation: 2_200, kind: .trailHead)
        let b = GraphNode(id: "b", coordinate: .init(latitude: 40.01, longitude: -106), elevation: 2_000, kind: .junction)
        let c = GraphNode(id: "c", coordinate: .init(latitude: 40.02, longitude: -106), elevation: 1_800, kind: .liftBase)
        let first = run(id: "first", source: a, target: b)
        let second = run(id: "second", source: b, target: c)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, c.id: c],
            edges: [first, second]
        )
        let profile = UserProfile(
            id: UUID(),
            displayName: "Skier",
            skillLevel: "intermediate",
            speedGreen: 7,
            speedBlue: 5,
            conditionMoguls: 1,
            conditionUngroomed: 1,
            conditionIcy: 1,
            conditionGladed: 1,
            onboardingCompleted: true
        )
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 1,
            stationElevationM: 2_000,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )

        let start = try XCTUnwrap(RouteProjection.skierPosition(
            at: 0,
            path: [first, second],
            profile: profile,
            context: context,
            graph: graph,
            initialEdgeFraction: 0.5
        ))
        let halfwayThroughRemainder = try XCTUnwrap(RouteProjection.skierPosition(
            at: 50,
            path: [first, second],
            profile: profile,
            context: context,
            graph: graph,
            initialEdgeFraction: 0.5
        ))

        XCTAssertEqual(start.coordinate.latitude, 40.005, accuracy: 0.000_01)
        XCTAssertEqual(halfwayThroughRemainder.coordinate.latitude, 40.0075, accuracy: 0.000_01)
        XCTAssertEqual(
            try XCTUnwrap(RouteProjection.totalTime(
                for: [first, second],
                profile: profile,
                context: context,
                initialEdgeFraction: 0.5
            )),
            300,
            accuracy: 0.01
        )

        let beforePlan = try XCTUnwrap(RouteProjection.skierPosition(
            at: -1,
            path: [first, second],
            profile: profile,
            context: context,
            graph: graph,
            initialEdgeFraction: 0.5
        ))
        XCTAssertEqual(beforePlan.coordinate.latitude, 40.005, accuracy: 0.000_01)
    }

    func testProjectionFailsClosedWhenRemainingRouteBecomesUnavailable() {
        let a = GraphNode(id: "a", coordinate: .init(latitude: 40, longitude: -106), elevation: 2_200, kind: .trailHead)
        let b = GraphNode(id: "b", coordinate: .init(latitude: 40.01, longitude: -106), elevation: 2_000, kind: .liftBase)
        var closedAttributes = EdgeAttributes(
            difficulty: .blue,
            lengthMeters: 1_000,
            isGroomed: true,
            isOpen: false,
            isOfficiallyValidated: true
        )
        closedAttributes.isOpen = false
        let closed = GraphEdge(
            id: "closed",
            sourceID: a.id,
            targetID: b.id,
            kind: .run,
            geometry: [a.coordinate, b.coordinate],
            attributes: closedAttributes
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b],
            edges: [closed]
        )
        let profile = UserProfile(
            id: UUID(),
            displayName: "Skier",
            skillLevel: "intermediate",
            speedGreen: 7,
            speedBlue: 5,
            conditionMoguls: 1,
            conditionUngroomed: 1,
            conditionIcy: 1,
            conditionGladed: 1,
            onboardingCompleted: true
        )
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 1,
            stationElevationM: 2_000,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )

        XCTAssertNil(RouteProjection.skierPosition(
            at: 1,
            path: [closed],
            profile: profile,
            context: context,
            graph: graph
        ))
        XCTAssertNil(RouteProjection.totalTime(
            for: [closed],
            profile: profile,
            context: context
        ))
    }

    private func run(id: String, source: GraphNode, target: GraphNode) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source.id,
            targetID: target.id,
            kind: .run,
            geometry: [source.coordinate, target.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                isGroomed: true,
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
    }
}
