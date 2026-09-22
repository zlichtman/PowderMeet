import CoreLocation
import XCTest
@testable import PowderMeet

@MainActor
final class RouteStepConsolidatorTests: XCTestCase {
    func testSameNameRunAndLiftNeverMerge() {
        let run = edge("run", kind: .run, source: "a", target: "b")
        let lift = edge("lift", kind: .lift, source: "b", target: "c")

        let steps = RouteStepConsolidator.consolidate(
            [run, lift],
            graph: graph(edges: [run, lift]),
            edgeTimes: [30, 120]
        )

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.map(\.seconds), [30, 120])
        XCTAssertEqual(
            RouteStepConsolidator.consolidatedIndex(
                for: [run, lift],
                rawEdgeIndex: 1,
                graph: graph(edges: [run, lift])
            ),
            1
        )
    }

    func testConsecutiveSameKindAndNameMergeAndSumTimes() {
        let first = edge("first", kind: .run, source: "a", target: "b")
        let second = edge("second", kind: .run, source: "b", target: "c")
        let routeGraph = graph(edges: [first, second])

        let steps = RouteStepConsolidator.consolidate(
            [first, second],
            graph: routeGraph,
            edgeTimes: [30, 45]
        )

        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.seconds, 75)
        XCTAssertEqual(
            RouteStepConsolidator.consolidatedIndex(
                for: [first, second],
                rawEdgeIndex: 1,
                graph: routeGraph
            ),
            0
        )
    }

    func testDifficultyChangeRemainsVisibleAcrossEveryInstructionSurface() {
        let first = edge("blue", kind: .run, source: "a", target: "b", group: "peak")
        let second = edge("black", kind: .run, source: "b", target: "c", difficulty: .black, group: "peak")
        let path = [first, second]
        let routeGraph = graph(edges: path)
        let profile = UserProfile.defaultProfile(id: UUID())
        let steps = RouteStepConsolidator.consolidate(path, graph: routeGraph, edgeTimes: [30, 45])
        let instructions = RouteInstructionBuilder.build(
            from: path, profile: profile,
            context: MeetingPointSolver(graph: routeGraph).makeContext(),
            naming: MountainNaming(routeGraph)
        )
        let navigation = NavigationViewModel(
            tracker: RouteProgressTracker(path: path, graph: routeGraph),
            profile: profile, graph: routeGraph
        )

        XCTAssertEqual(steps.map(\.difficulty), [.blue, .black])
        XCTAssertEqual(steps.map(\.seconds), [30, 45])
        XCTAssertEqual(instructions.map(\.difficulty), [.blue, .black])
        XCTAssertEqual(navigation.currentManeuver?.difficulty, .blue)
        XCTAssertEqual(navigation.nextManeuver?.difficulty, .black)
        XCTAssertEqual(navigation.currentManeuver?.transitionDifficulty, .black)
        XCTAssertEqual(navigation.currentManeuver?.remainingMeters, 100)
        XCTAssertEqual(RouteStepConsolidator.consolidatedIndex(for: path, rawEdgeIndex: 1, graph: routeGraph), 1)
    }

    func testDifferentIdentitiesCannotMergeBecauseTheirNamesMatch() {
        let first = edge("first", kind: .run, source: "a", target: "b", group: "peak-west")
        let second = edge("second", kind: .run, source: "b", target: "c", group: "peak-east")
        XCTAssertFalse(RouteInstructionGrouping.canMerge(
            first, second, previousLabel: "Peak", nextLabel: "Peak"
        ))
        XCTAssertEqual(RouteStepConsolidator.consolidate([first, second]).count, 2)
    }

    func testDisconnectedFragmentsCannotMergeIntoOneInstruction() {
        let first = edge("first", kind: .run, source: "a", target: "b", group: "peak")
        let second = edge("second", kind: .run, source: "c", target: "d", group: "peak")
        XCTAssertEqual(RouteStepConsolidator.consolidate([first, second]).count, 2)
    }

    func testFallbackNamesPreserveNamedTrailsWithoutMergingUnknownTrails() {
        let first = edge("first", kind: .run, source: "a", target: "b", name: nil)
        let second = edge("second", kind: .run, source: "b", target: "c", name: nil)
        XCTAssertEqual(RouteStepConsolidator.consolidate([first, second]).count, 2)
        let named = edge("named", kind: .run, source: "a", target: "b")
        XCTAssertEqual(RouteStepConsolidator.consolidate([named]).first?.name, "Peak")
    }

    func testMergedManeuverArrowUsesFinalSegmentEnteringTheJunction() {
        let north = CLLocationCoordinate2D(latitude: 40.01, longitude: -106)
        let middle = CLLocationCoordinate2D(latitude: 40, longitude: -106)
        let junction = CLLocationCoordinate2D(latitude: 40, longitude: -105.99)
        let south = CLLocationCoordinate2D(latitude: 39.99, longitude: -105.99)
        let first = edge("first", kind: .run, source: "a", target: "b", group: "peak", geometry: [north, middle])
        let second = edge("second", kind: .run, source: "b", target: "c", group: "peak", geometry: [middle, junction])
        let exit = edge("exit", kind: .run, source: "c", target: "d", group: "exit", name: "Exit", geometry: [junction, south])
        let path = [first, second, exit]
        let routeGraph = graph(edges: path)
        let navigation = NavigationViewModel(
            tracker: RouteProgressTracker(path: path, graph: routeGraph),
            profile: UserProfile.defaultProfile(id: UUID()), graph: routeGraph
        )

        XCTAssertEqual(navigation.currentManeuver?.remainingMeters, 200)
        XCTAssertEqual(navigation.currentManeuver?.iconSymbolName, "arrow.turn.down.right")
    }

    func testThreeFragmentsShareOneStepAndKeepRawIndexAlignment() {
        let path = [
            edge("one", kind: .run, source: "a", target: "b"),
            edge("two", kind: .run, source: "b", target: "c"),
            edge("three", kind: .run, source: "c", target: "d"),
            edge("lift", kind: .lift, source: "d", target: "e")
        ]
        let steps = RouteStepConsolidator.consolidate(path, edgeTimes: [10, 20, 30, 120])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.map(\.seconds), [60, 120])
        XCTAssertEqual(RouteStepConsolidator.consolidatedIndex(for: path, rawEdgeIndex: 2), 0)
        XCTAssertEqual(RouteStepConsolidator.consolidatedIndex(for: path, rawEdgeIndex: 3), 1)
    }

    private func edge(
        _ id: String,
        kind: GraphEdge.EdgeKind,
        source: String,
        target: String,
        difficulty: RunDifficulty = .blue,
        group: String? = nil,
        name: String? = "Peak",
        geometry: [CLLocationCoordinate2D]? = nil
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source,
            targetID: target,
            kind: kind,
            geometry: geometry ?? [
                .init(latitude: 40, longitude: -106),
                .init(latitude: 39.99, longitude: -106)
            ],
            attributes: EdgeAttributes(
                difficulty: kind == .run ? difficulty : nil,
                lengthMeters: 100,
                trailName: name,
                isOpen: true,
                isOfficiallyValidated: true,
                trailGroupId: group
            )
        )
    }

    private func graph(edges: [GraphEdge]) -> MountainGraph {
        let ids = Set(edges.flatMap { [$0.sourceID, $0.targetID] })
        let nodes = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (
                id,
                GraphNode(
                    id: id,
                    coordinate: .init(latitude: 40 - Double(index) * 0.01, longitude: -106),
                    elevation: 2_000 - Double(index) * 100,
                    kind: .junction
                )
            )
        })
        return MountainGraph(resortID: "test", nodes: nodes, edges: edges)
    }
}
