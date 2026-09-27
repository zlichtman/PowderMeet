//
//  StoredRouteValidatorTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class StoredRouteValidatorTests: XCTestCase {
    private func makeGraph() -> MountainGraph {
        let nodes = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].enumerated().map { index, id in
            (
                id,
                GraphNode(
                    id: id,
                    coordinate: .init(latitude: 39.60 + Double(index) * 0.001, longitude: -106.35),
                    elevation: 3_000 - Double(index) * 100,
                    kind: .junction
                )
            )
        })

        func edge(_ id: String, _ source: String, _ target: String, isOpen: Bool = true) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: source,
                targetID: target,
                kind: .run,
                geometry: [nodes[source]!.coordinate, nodes[target]!.coordinate],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 100,
                    verticalDrop: 100,
                    trailName: id,
                    isOpen: isOpen
                )
            )
        }

        return MountainGraph(
            resortID: "route-validator-test",
            nodes: nodes,
            edges: [
                edge("ab", "a", "b"),
                edge("bc", "b", "c"),
                edge("bd", "b", "d"),
                edge("dc", "d", "c"),
                edge("closed-bc", "b", "c", isOpen: false)
            ]
        )
    }

    func testRejectsMissingEdgeWithoutPartialReconstruction() {
        assertFailure(["ab", "missing"], start: "a", target: "c") {
            $0 == .missingEdge("missing")
        }
    }

    func testRejectsClosedEdge() {
        assertFailure(["ab", "closed-bc"], start: "a", target: "c") {
            $0 == .closedEdge("closed-bc")
        }
    }

    func testRejectsDiscontinuousDirectedPath() {
        assertFailure(["ab", "dc"], start: "a", target: "c") {
            if case .discontinuity(let previous, let next, let expected, let actual) = $0 {
                return previous == "ab" && next == "dc" && expected == "b" && actual == "d"
            }
            return false
        }
    }

    func testRejectsWrongExpectedStart() {
        assertFailure(["bc"], start: "a", target: "c") {
            $0 == .wrongStart(expected: "a", actual: "b")
        }
    }

    func testRejectsWrongFinalTarget() {
        assertFailure(["ab"], start: "a", target: "c") {
            $0 == .wrongTarget(expected: "c", actual: "b")
        }
    }

    func testAcceptsCompleteOpenContiguousPath() throws {
        let result = StoredRouteValidator.validate(
            edgeIDs: ["ab", "bc"],
            in: makeGraph(),
            expectedStartID: "a",
            targetID: "c"
        )

        let path = try result.get()
        XCTAssertEqual(path.map(\.id), ["ab", "bc"])
    }

    func testAcceptsEmptyPathOnlyWhenStartIsTarget() throws {
        let result = StoredRouteValidator.validate(
            edgeIDs: [],
            in: makeGraph(),
            expectedStartID: "c",
            targetID: "c"
        )
        XCTAssertTrue(try result.get().isEmpty)
    }

    func testOnlyLiveSolveAttemptIsNavigable() {
        XCTAssertTrue(SolveAttempt.live.isNavigable)
        XCTAssertFalse(SolveAttempt.forcedOpen.isNavigable)
        XCTAssertFalse(SolveAttempt.neighborSubstitution.isNavigable)
        XCTAssertFalse(SolveAttempt.forcedOpenNeighborSubstitution.isNavigable)
        XCTAssertFalse(SolveAttempt.nonCanonicalDataset.isNavigable)
    }

    func testRequestStartStampComesFromExactPathNotALaterGpsSnap() throws {
        let graph = makeGraph()
        let path = [try XCTUnwrap(graph.edge(byID: "ab")), try XCTUnwrap(graph.edge(byID: "bc"))]

        XCTAssertEqual(StoredRouteStamp.startNodeID(for: path, targetID: "c"), "a")
        XCTAssertEqual(StoredRouteStamp.startNodeID(for: [], targetID: "c"), "c")
    }

    @MainActor
    func testFreshOriginWithNoSafePathCannotFallBackToRequestTimeRoute() {
        let base = makeGraph()
        let x = GraphNode(
            id: "x",
            coordinate: .init(latitude: 39.61, longitude: -106.35),
            elevation: 3_100,
            kind: .junction
        )
        let closedEscape = GraphEdge(
            id: "xc",
            sourceID: x.id,
            targetID: "c",
            kind: .run,
            geometry: [x.coordinate, base.nodes["c"]!.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 500,
                isOpen: false
            )
        )
        var nodes = base.nodes
        nodes[x.id] = x
        let graph = MountainGraph(
            resortID: base.resortID,
            nodes: nodes,
            edges: base.edges + [closedEscape]
        )
        let controller = MeetupSessionController()
        let route = controller.validatedOrStrictlyResolvedRoute(
            storedEdgeIDs: ["ab", "bc"],
            storedStartID: "a",
            localOrigin: .node("x"),
            targetID: "c",
            profile: UserProfile.defaultProfile(id: UUID()),
            graph: graph,
            solver: MeetingPointSolver(graph: graph),
            label: "test"
        )

        XCTAssertNil(route)
    }

    private func assertFailure(
        _ edgeIDs: [String]?,
        start: String?,
        target: String,
        matches: (StoredRouteValidationFailure) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = StoredRouteValidator.validate(
            edgeIDs: edgeIDs,
            in: makeGraph(),
            expectedStartID: start,
            targetID: target
        )
        switch result {
        case .success(let path):
            XCTFail("Expected validation failure, got \(path.map(\.id))", file: file, line: line)
        case .failure(let failure):
            XCTAssertTrue(matches(failure), "Unexpected failure: \(failure)", file: file, line: line)
        }
    }
}
