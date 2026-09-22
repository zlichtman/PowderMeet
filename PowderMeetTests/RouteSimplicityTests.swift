import XCTest
import CoreLocation
@testable import PowderMeet

final class RouteSimplicityTests: XCTestCase {
    private func node(_ id: String, longitude: Double, kind: GraphNode.NodeKind = .junction) -> GraphNode {
        GraphNode(
            id: id,
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: longitude),
            elevation: 2_500,
            kind: kind
        )
    }

    private func edge(
        _ id: String,
        from source: GraphNode,
        to target: GraphNode,
        length: Double,
        name: String,
        group: String? = nil
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source.id,
            targetID: target.id,
            kind: .run,
            geometry: [source.coordinate, target.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: length,
                verticalDrop: 0,
                averageGradient: 0,
                maxGradient: 0,
                trailName: name,
                isGroomed: true,
                isOpen: true,
                isOfficiallyValidated: true,
                trailGroupId: group
            )
        )
    }

    private func profile() -> UserProfile {
        UserProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            displayName: "Skier",
            skillLevel: "expert",
            speedGreen: 10,
            speedBlue: 10,
            speedBlack: 10,
            speedDoubleBlack: 10,
            speedTerrainPark: 10,
            conditionMoguls: 1,
            conditionUngroomed: 1,
            conditionIcy: 1,
            conditionGladed: 1,
            onboardingCompleted: true
        )
    }

    func testCanonicalFragmentsOfOneTrailDoNotAddTransitions() {
        let a = node("a", longitude: -106.00)
        let b = node("b", longitude: -106.01)
        let c = node("c", longitude: -106.02)
        let path = [
            edge("one", from: a, to: b, length: 100, name: "Upper", group: "peak"),
            edge("two", from: b, to: c, length: 100, name: "Lower", group: "peak"),
        ]

        XCTAssertEqual(RouteSimplicity.transitionCount(in: path), 0)
        XCTAssertEqual(
            RouteSimplicity.preferencePenaltySeconds(
                forTransitionCount: RouteSimplicity.transitionCount(in: path)
            ),
            0
        )
    }

    func testCanonicalTrailSegmentationDoesNotShrinkETAUncertainty() throws {
        for count in [1, 2, 8] {
            let nodes = (0...count).map {
                node("node-\($0)", longitude: -106 + Double($0) * 0.001,
                     kind: $0 == count ? .liftBase : .junction)
            }
            let path = (0..<count).map {
                edge("piece-\($0)", from: nodes[$0], to: nodes[$0 + 1],
                     length: 1_000 / Double(count), name: "Peak", group: "peak")
            }
            let graph = MountainGraph(
                resortID: "test", nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
                edges: path
            )
            let catalog = RendezvousCatalog(points: [RendezvousPoint(
                id: nodes.last!.id, nodeID: nodes.last!.id, kind: .liftBase, confidence: 1, quality: 1
            )], graph: graph)
            XCTAssertEqual(catalog.points.count, 1)
            let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
            solver.temperatureC = 0
            let metrics = try XCTUnwrap(solver.metrics(for: path, skier: profile()))
            let route = try XCTUnwrap(solver.pathTo(target: nodes.last!.id, from: nodes[0].id, skier: profile()))
            XCTAssertEqual(metrics.time, 100, accuracy: 0.001)
            XCTAssertEqual(metrics.etaStdSeconds, 15, accuracy: 0.001)
            XCTAssertEqual(route.etaStdSeconds, metrics.etaStdSeconds, accuracy: 0.001)
            MeetingPointSolver.solutionCache.clear()
            let meetup = try XCTUnwrap(solver.solve(
                skierA: profile(), positionA: nodes[0].id,
                skierB: UserProfile.defaultProfile(id: UUID()), positionB: nodes[0].id
            ))
            XCTAssertEqual(try XCTUnwrap(meetup.etaStdSecondsA), metrics.etaStdSeconds, accuracy: 0.001)

            let remaining = try XCTUnwrap(solver.metrics(for: path, skier: profile(), initialEdgeFraction: 0.5))
            XCTAssertEqual(remaining.etaStdSeconds, remaining.time * 0.15, accuracy: 0.001)
        }
    }

    func testUncertaintyKeepsGPSVarianceSeparateAndResetsAtDisconnectedFragments() {
        let a = node("a", longitude: -106)
        let b = node("b", longitude: -106.01)
        let c = node("c", longitude: -106.02)
        let first = edge("one", from: a, to: b, length: 100, name: "Peak", group: "peak")
        let next = edge("two", from: b, to: c, length: 100, name: "Peak", group: "peak")
        var estimate = RouteTimeUncertainty(initialVariance: 81)
        estimate.append(edge: first, variance: 9)
        estimate.append(edge: next, variance: 16)
        XCTAssertEqual(estimate.varianceTime, 81 + 49, accuracy: 0.001)
        XCTAssertEqual(estimate.currentActionStdSeconds, 7, accuracy: 0.001)
        // Same identity is insufficient without directed continuity.
        estimate.append(edge: first, variance: 25)
        XCTAssertEqual(estimate.varianceTime, 81 + 49 + 25, accuracy: 0.001)
        XCTAssertEqual(estimate.currentActionStdSeconds, 5, accuracy: 0.001)
    }

    func testDistinctPhysicalTrailsRetainIndependentUncertainty() throws {
        let a = node("a", longitude: -106)
        let b = node("b", longitude: -106.01)
        let c = node("c", longitude: -106.02)
        let path = [
            edge("one", from: a, to: b, length: 500, name: "One", group: "one"),
            edge("two", from: b, to: c, length: 500, name: "Two", group: "two")
        ]
        let solver = MeetingPointSolver(graph: MountainGraph(
            resortID: "test", nodes: [a.id: a, b.id: b, c.id: c], edges: path
        ))
        solver.temperatureC = 0
        let metrics = try XCTUnwrap(solver.metrics(for: path, skier: profile()))
        XCTAssertEqual(metrics.etaStdSeconds, (2 * 7.5 * 7.5).squareRoot(), accuracy: 0.001)
    }

    func testStorageFragmentsCannotMakeSlowerTrailWinReliabilityScore() throws {
        let nodes = (0...8).map { node("node-\($0)", longitude: -106 + Double($0) * 0.001) }
        let split = (0..<8).map {
            edge("piece-\($0)", from: nodes[$0], to: nodes[$0 + 1],
                 length: 125, name: "Split", group: "split")
        }
        let direct = edge("direct", from: nodes[0], to: nodes[8], length: 990, name: "Direct", group: "direct")
        let solver = MeetingPointSolver(graph: MountainGraph(
            resortID: "test", nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
            edges: split + [direct]
        ))
        solver.temperatureC = 0
        let route = try XCTUnwrap(solver.pathTo(target: nodes[8].id, from: nodes[0].id, skier: profile()))
        XCTAssertEqual(route.path.map(\.id), [direct.id])
        XCTAssertEqual(route.time, 99, accuracy: 0.001)
    }

    func testTransitionPreferenceIsBounded() {
        XCTAssertEqual(
            RouteSimplicity.preferencePenaltySeconds(forTransitionCount: 1),
            8
        )
        XCTAssertEqual(
            RouteSimplicity.preferencePenaltySeconds(forTransitionCount: 100),
            32
        )
    }

    func testSlightlySlowerDirectTrailBeatsFragmentedInstructionSequence() throws {
        let start = node("start", longitude: -106.00)
        let one = node("one", longitude: -106.01)
        let two = node("two", longitude: -106.02)
        let finish = node("finish", longitude: -106.03)
        let complex = [
            edge("complex-a", from: start, to: one, length: 100, name: "A", group: "a"),
            edge("complex-b", from: one, to: two, length: 100, name: "B", group: "b"),
            edge("complex-c", from: two, to: finish, length: 100, name: "C", group: "c"),
        ]
        let direct = edge(
            "direct",
            from: start,
            to: finish,
            length: 330,
            name: "Easy Way",
            group: "easy-way"
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [start.id: start, one.id: one, two.id: two, finish.id: finish],
            edges: complex + [direct]
        )

        let route = try XCTUnwrap(
            MeetingPointSolver(graph: graph).pathTo(
                target: finish.id,
                from: start.id,
                skier: profile()
            )
        )
        XCTAssertEqual(route.path.map(\.id), [direct.id])
        XCTAssertGreaterThan(route.time, 30)
        XCTAssertLessThan(route.time, 40)
    }

    func testMateriallyFasterRouteStillWinsDespiteMoreActions() throws {
        let start = node("start", longitude: -106.00)
        let one = node("one", longitude: -106.01)
        let two = node("two", longitude: -106.02)
        let finish = node("finish", longitude: -106.03)
        let complex = [
            edge("complex-a", from: start, to: one, length: 50, name: "A", group: "a"),
            edge("complex-b", from: one, to: two, length: 50, name: "B", group: "b"),
            edge("complex-c", from: two, to: finish, length: 50, name: "C", group: "c"),
        ]
        let direct = edge(
            "direct",
            from: start,
            to: finish,
            length: 800,
            name: "Easy Way",
            group: "easy-way"
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [start.id: start, one.id: one, two.id: two, finish.id: finish],
            edges: complex + [direct]
        )

        let route = try XCTUnwrap(
            MeetingPointSolver(graph: graph).pathTo(
                target: finish.id,
                from: start.id,
                skier: profile()
            )
        )
        XCTAssertEqual(route.path.map(\.id), complex.map(\.id))
        XCTAssertGreaterThan(route.time, 10)
        XCTAssertLessThan(route.time, 20)
    }
}
