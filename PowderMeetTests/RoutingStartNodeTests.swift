import CoreLocation
import XCTest
@testable import PowderMeet

final class RoutingStartNodeTests: XCTestCase {
    func testRetryOriginExpiresAndDoesNotRetainLastUsableFix() throws {
        let fixture = graphFixture()
        let captured = Date(timeIntervalSinceReferenceDate: 1_000)
        let coordinate = CLLocationCoordinate2D(latitude: 40.005, longitude: -106)
        var origin = RoutingFixPolicy.currentOrigin(
            in: fixture.graph, coordinate: coordinate, horizontalAccuracyMeters: 10,
            capturedAt: captured, now: captured.addingTimeInterval(60)
        )
        XCTAssertNotNil(origin)
        origin = RoutingFixPolicy.currentOrigin(
            in: fixture.graph, coordinate: coordinate, horizontalAccuracyMeters: 10,
            capturedAt: captured, now: captured.addingTimeInterval(76)
        )
        XCTAssertNil(origin)
        XCTAssertNil(RoutingFixPolicy.currentOrigin(
            in: fixture.graph, coordinate: coordinate, horizontalAccuracyMeters: 500,
            capturedAt: captured, now: captured
        ))
        XCTAssertNil(RoutingFixPolicy.currentOrigin(
            in: fixture.graph, coordinate: nil, horizontalAccuracyMeters: 10,
            capturedAt: captured, now: captured
        ))
    }

    func testRetryOriginUsesMovedFixAndCurrentClosureSnapshot() throws {
        let fixture = graphFixture()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        func origin(_ latitude: Double, graph: MountainGraph) -> RoutingOrigin? {
            RoutingFixPolicy.currentOrigin(
                in: graph, coordinate: .init(latitude: latitude, longitude: -106),
                horizontalAccuracyMeters: 10, capturedAt: now, now: now
            )
        }
        let first = try XCTUnwrap(origin(40.003, graph: fixture.graph))
        let moved = try XCTUnwrap(origin(40.007, graph: fixture.graph))
        XCTAssertGreaterThan(first.remainingFraction, moved.remainingFraction)
        let closedGraph = MountainGraph(
            resortID: fixture.graph.resortID, nodes: fixture.graph.nodes,
            edges: fixture.graph.edges.map { $0.withAttributes($0.attributes.enriched(isOpen: false)) }
        )
        XCTAssertNil(origin(40.007, graph: closedGraph))
    }

    func testMidRunUsesDirectedSourceInsteadOfCloserEndpoint() throws {
        let fixture = graphFixture()
        // 70% down the directed run: target is geographically much closer,
        // but the unskiied remainder cannot be skipped safely.
        let fix = CLLocationCoordinate2D(latitude: 40.007, longitude: -106)
        XCTAssertEqual(fixture.graph.routingStartNode(to: fix)?.id, fixture.source.id)
        let origin = try XCTUnwrap(fixture.graph.routingOrigin(to: fix))
        XCTAssertEqual(origin.approachEdgeID, "directed-run")
        XCTAssertEqual(origin.approachTargetNodeID, fixture.target.id)
        XCTAssertEqual(origin.remainingFraction, 0.3, accuracy: 0.02)
    }

    func testNearDirectedTargetAdvancesToTarget() throws {
        let fixture = graphFixture()
        let fix = CLLocationCoordinate2D(latitude: 40.0097, longitude: -106)
        XCTAssertEqual(fixture.graph.routingStartNode(to: fix)?.id, fixture.target.id)
        XCTAssertNil(fixture.graph.routingOrigin(to: fix)?.approachEdgeID)
    }

    func testSixtyMetersBeforeTargetKeepsDirectedRemainder() throws {
        let fixture = graphFixture()
        let fix = CLLocationCoordinate2D(latitude: 40.00945, longitude: -106)
        let origin = try XCTUnwrap(fixture.graph.routingOrigin(to: fix))

        XCTAssertEqual(origin.approachEdgeID, "directed-run")
        XCTAssertEqual(origin.approachTargetNodeID, fixture.target.id)
        XCTAssertGreaterThan(origin.remainingFraction, 0.04)
    }

    func testInteriorOriginChargesOnlyRemainingDirectedEdge() throws {
        let fixture = graphFixture()
        var profile = UserProfile.defaultProfile(id: UUID())
        profile.skillLevel = "intermediate"
        profile.speedGreen = 8
        profile.speedBlue = 10
        let solver = MeetingPointSolver(graph: fixture.graph)
        let full = try XCTUnwrap(solver.pathTo(
            target: fixture.target.id,
            from: fixture.source.id,
            skier: profile
        ))
        let origin = try XCTUnwrap(fixture.graph.routingOrigin(
            to: .init(latitude: 40.005, longitude: -106)
        ))
        let remaining = try XCTUnwrap(solver.pathTo(
            target: fixture.target.id,
            from: origin,
            skier: profile
        ))

        XCTAssertEqual(remaining.path.map(\.id), full.path.map(\.id))
        XCTAssertEqual(remaining.time, full.time * 0.5, accuracy: 0.5)
        XCTAssertEqual(remaining.etaStdSeconds, full.etaStdSeconds * 0.5, accuracy: 0.5)
    }

    func testPositionAccuracyWidensETAConfidenceWithoutChangingMean() throws {
        let fixture = graphFixture()
        var profile = UserProfile.defaultProfile(id: UUID())
        profile.skillLevel = "intermediate"
        profile.speedBlue = 10
        let coordinate = CLLocationCoordinate2D(latitude: 40.005, longitude: -106)
        let precise = try XCTUnwrap(fixture.graph.routingOrigin(
            to: coordinate,
            positionUncertaintyMeters: 5
        ))
        let uncertain = try XCTUnwrap(fixture.graph.routingOrigin(
            to: coordinate,
            positionUncertaintyMeters: 100
        ))
        let solver = MeetingPointSolver(graph: fixture.graph)
        let preciseRoute = try XCTUnwrap(solver.pathTo(
            target: fixture.target.id,
            from: precise,
            skier: profile
        ))
        let uncertainRoute = try XCTUnwrap(solver.pathTo(
            target: fixture.target.id,
            from: uncertain,
            skier: profile
        ))

        XCTAssertEqual(preciseRoute.time, uncertainRoute.time, accuracy: 0.001)
        XCTAssertGreaterThan(uncertainRoute.etaStdSeconds, preciseRoute.etaStdSeconds + 30)
        XCTAssertNotEqual(precise.cacheFingerprint, uncertain.cacheFingerprint)
    }

    func testInteriorLiftDoesNotChargeQueueAgain() throws {
        let fixture = liftFixture()
        var profile = UserProfile.defaultProfile(id: UUID())
        profile.skillLevel = "intermediate"
        profile.speedGreen = 8
        profile.speedBlue = 10
        let solver = MeetingPointSolver(graph: fixture.graph)
        let full = try XCTUnwrap(solver.pathTo(
            target: fixture.target.id,
            from: fixture.source.id,
            skier: profile
        ))
        let origin = try XCTUnwrap(fixture.graph.routingOrigin(
            to: .init(latitude: 40.005, longitude: -106)
        ))
        let remaining = try XCTUnwrap(solver.pathTo(
            target: fixture.target.id,
            from: origin,
            skier: profile
        ))

        XCTAssertGreaterThan(full.time, 600) // ride plus a queue/baseline wait
        XCTAssertEqual(remaining.time, 300, accuracy: 1) // half the ride; queue already paid
    }

    func testAccurateOffCorridorFixDoesNotTeleportToNearestNode() throws {
        let fixture = graphFixture()
        let fix = CLLocationCoordinate2D(latitude: 40, longitude: -106.001)
        XCTAssertNotNil(fixture.graph.nearestNode(to: fix))
        XCTAssertNil(fixture.graph.routingOrigin(to: fix))
    }

    func testUsableAccuracyMayWidenCorridorButNeverBeyondPolicyCap() throws {
        let fixture = graphFixture()
        let fix = CLLocationCoordinate2D(latitude: 40, longitude: -106.001)
        let tolerance = RoutingFixPolicy.networkSnapTolerance(
            horizontalAccuracyMeters: 100
        )
        let origin = try XCTUnwrap(fixture.graph.routingOrigin(
            to: fix,
            maximumSnapDistanceMeters: tolerance
        ))

        XCTAssertEqual(origin.approachEdgeID, "directed-run")
        XCTAssertEqual(tolerance, 100)
        XCTAssertEqual(
            RoutingFixPolicy.networkSnapTolerance(horizontalAccuracyMeters: 150),
            120
        )
    }

    func testLiveRoutingRejectsLegacyOneKilometerNodeFallback() {
        let fixture = graphFixture()
        let fix = CLLocationCoordinate2D(latitude: 40, longitude: -106.006)

        XCTAssertNotNil(fixture.graph.nearestNode(to: fix))
        XCTAssertNil(fixture.graph.routingOrigin(
            to: fix,
            maximumSnapDistanceMeters: 120
        ))
    }

    func testEqualGeometrySnapDoesNotDependOnEdgeOrder() {
        let fixture = graphFixture()
        let alternate = GraphEdge(
            id: "aaa-stable-winner",
            sourceID: fixture.source.id,
            targetID: fixture.target.id,
            kind: .run,
            geometry: fixture.graph.edges[0].geometry,
            attributes: fixture.graph.edges[0].attributes
        )
        let forward = MountainGraph(
            resortID: "test",
            nodes: fixture.graph.nodes,
            edges: [fixture.graph.edges[0], alternate]
        )
        let reversed = MountainGraph(
            resortID: "test",
            nodes: fixture.graph.nodes,
            edges: [alternate, fixture.graph.edges[0]]
        )
        let fix = CLLocationCoordinate2D(latitude: 40.005, longitude: -106)

        XCTAssertEqual(forward.bestOpenNetworkSnap(to: fix)?.edge.id, alternate.id)
        XCTAssertEqual(reversed.bestOpenNetworkSnap(to: fix)?.edge.id, alternate.id)
    }

    func testMovingCourseDisambiguatesNearbyOppositeDirectionCorridors() throws {
        let south = GraphNode(
            id: "south",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 1_900,
            kind: .junction
        )
        let north = GraphNode(
            id: "north",
            coordinate: .init(latitude: 40.01, longitude: -106),
            elevation: 2_100,
            kind: .junction
        )
        let northbound = GraphEdge(
            id: "northbound",
            sourceID: south.id,
            targetID: north.id,
            kind: .lift,
            geometry: [south.coordinate, north.coordinate],
            attributes: EdgeAttributes(lengthMeters: 1_100, isOpen: true)
        )
        let reverseSouth = GraphNode(
            id: "reverse-south",
            coordinate: .init(latitude: 40, longitude: -106.00005),
            elevation: 1_900,
            kind: .trailEnd
        )
        let reverseNorth = GraphNode(
            id: "reverse-north",
            coordinate: .init(latitude: 40.01, longitude: -106.00005),
            elevation: 2_100,
            kind: .trailHead
        )
        let southbound = GraphEdge(
            id: "southbound",
            sourceID: reverseNorth.id,
            targetID: reverseSouth.id,
            kind: .run,
            geometry: [reverseNorth.coordinate, reverseSouth.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_100,
                isOpen: true
            )
        )
        let graph = MountainGraph(
            resortID: "parallel",
            nodes: [
                south.id: south,
                north.id: north,
                reverseSouth.id: reverseSouth,
                reverseNorth.id: reverseNorth
            ],
            edges: [northbound, southbound]
        )
        let fix = CLLocationCoordinate2D(latitude: 40.005, longitude: -106.00005)

        XCTAssertEqual(graph.bestOpenNetworkSnap(to: fix)?.edge.id, southbound.id)
        XCTAssertEqual(
            graph.bestOpenNetworkSnap(
                to: fix,
                travelCourseDegrees: 0
            )?.edge.id,
            northbound.id
        )
        let origin = try XCTUnwrap(graph.routingOrigin(
            to: fix,
            travelCourseDegrees: 0
        ))
        XCTAssertEqual(origin.approachEdgeID, northbound.id)
    }

    func testDiagonalHighLatitudeSnapUsesMetricLongitudeScale() throws {
        let start = GraphNode(
            id: "start",
            coordinate: .init(latitude: 60, longitude: 0),
            elevation: 2_200,
            kind: .trailHead
        )
        let end = GraphNode(
            id: "end",
            coordinate: .init(latitude: 60.01, longitude: 0.02),
            elevation: 1_900,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "diagonal",
            sourceID: start.id,
            targetID: end.id,
            kind: .run,
            geometry: [start.coordinate, end.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_600,
                isOpen: true
            )
        )
        let graph = MountainGraph(
            resortID: "high-latitude",
            nodes: [start.id: start, end.id: end],
            edges: [edge]
        )

        let snap = try XCTUnwrap(graph.bestOpenNetworkSnap(
            to: .init(latitude: 60.008, longitude: 0.005)
        ))
        XCTAssertEqual(snap.fractionAlongEdge, 0.525, accuracy: 0.01)
    }

    func testAccurateAltitudeDisambiguatesStackedMountainCorridors() throws {
        let lowStart = GraphNode(id: "low-start", coordinate: .init(latitude: 40, longitude: -106), elevation: 1_900, kind: .trailHead)
        let lowEnd = GraphNode(id: "low-end", coordinate: .init(latitude: 40.01, longitude: -106), elevation: 1_900, kind: .trailEnd)
        let highStart = GraphNode(id: "high-start", coordinate: lowStart.coordinate, elevation: 2_200, kind: .liftBase)
        let highEnd = GraphNode(id: "high-end", coordinate: lowEnd.coordinate, elevation: 2_200, kind: .liftTop)
        let low = GraphEdge(
            id: "a-low-run",
            sourceID: lowStart.id,
            targetID: lowEnd.id,
            kind: .run,
            geometry: [lowStart.coordinate, lowEnd.coordinate],
            attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 1_100, isOpen: true)
        )
        let high = GraphEdge(
            id: "z-high-lift",
            sourceID: highStart.id,
            targetID: highEnd.id,
            kind: .lift,
            geometry: [highStart.coordinate, highEnd.coordinate],
            attributes: EdgeAttributes(lengthMeters: 1_100, isOpen: true)
        )
        let graph = MountainGraph(
            resortID: "stacked",
            nodes: [
                lowStart.id: lowStart,
                lowEnd.id: lowEnd,
                highStart.id: highStart,
                highEnd.id: highEnd
            ],
            edges: [low, high]
        )
        let fix = CLLocationCoordinate2D(latitude: 40.005, longitude: -106)

        XCTAssertEqual(graph.bestOpenNetworkSnap(to: fix)?.edge.id, low.id)
        XCTAssertEqual(graph.bestOpenNetworkSnap(
            to: fix,
            altitudeMeters: 2_190,
            verticalAccuracyMeters: 15
        )?.edge.id, high.id)
        XCTAssertEqual(graph.bestOpenNetworkSnap(
            to: fix,
            altitudeMeters: 2_190,
            verticalAccuracyMeters: 80
        )?.edge.id, low.id)
    }

    private func graphFixture() -> (graph: MountainGraph, source: GraphNode, target: GraphNode) {
        let source = GraphNode(
            id: "top",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 2_200,
            kind: .trailHead
        )
        let target = GraphNode(
            id: "base",
            coordinate: .init(latitude: 40.01, longitude: -106),
            elevation: 1_900,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "directed-run",
            sourceID: source.id,
            targetID: target.id,
            kind: .run,
            geometry: [source.coordinate, target.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_100,
                verticalDrop: 300,
                trailName: "Creekside",
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        return (
            MountainGraph(
                resortID: "test",
                nodes: [source.id: source, target.id: target],
                edges: [edge]
            ),
            source,
            target
        )
    }

    private func liftFixture() -> (graph: MountainGraph, source: GraphNode, target: GraphNode) {
        let source = GraphNode(
            id: "lift-base",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 1_900,
            kind: .liftBase
        )
        let target = GraphNode(
            id: "lift-top",
            coordinate: .init(latitude: 40.01, longitude: -106),
            elevation: 2_200,
            kind: .liftTop
        )
        let edge = GraphEdge(
            id: "chair",
            sourceID: source.id,
            targetID: target.id,
            kind: .lift,
            geometry: [source.coordinate, target.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 1_100,
                verticalDrop: -300,
                trailName: "Test Chair",
                liftType: .chairLift,
                rideTimeSeconds: 600,
                waitTimeMinutes: 5,
                chargesLiftWait: true,
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        return (
            MountainGraph(
                resortID: "test",
                nodes: [source.id: source, target.id: target],
                edges: [edge]
            ),
            source,
            target
        )
    }
}
