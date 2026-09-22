//
//  MountainNamingDeterminismTests.swift
//  PowderMeetTests
//
//  Equivalent topology must render and label identically regardless of edge
//  insertion order.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class MountainNamingDeterminismTests: XCTestCase {
    func testNamedFragmentKeepsItsWholeGroupVisibleInDemoPicker() throws {
        let edges = fixtureEdges().map { edge in
            guard edge.kind == .run else { return edge }
            return edge.withAttributes(EdgeAttributes(
                difficulty: .blue, lengthMeters: 500, verticalDrop: 100,
                trailName: edge.id == "run-a" ? "Cruiser" : "  ",
                isOpen: true, trailGroupId: "cruiser"
            ))
        }
        // Geometric chain order starts at base-a, so its first fragment is
        // unnamed. The named fragment later in that same group is evidence.
        let graph = fixtureGraph(edges: edges)
        let summary = try XCTUnwrap(graph.runTrailGroupSummary(forGroupId: "cruiser"))
        XCTAssertEqual(summary.orderedRunEdges.first?.id, "run-b")
        XCTAssertEqual(summary.displayName, "Cruiser")
        let entry = try XCTUnwrap(RoutingTestSheet.trailEntries(in: graph).first)
        XCTAssertTrue(entry.name.contains("Cruiser"))
        XCTAssertEqual(entry.nodeId, "top")
        XCTAssertEqual(entry.trailGroupId, "cruiser")
        let reversed = fixtureGraph(edges: Array(edges.reversed()))
        XCTAssertEqual(reversed.runTrailGroupSummary(forGroupId: "cruiser")?.displayName, "Cruiser")
    }


    func testTrailChainOrderIsIndependentOfInputOrder() {
        let edges = fixtureEdges()
        let forward = TrailChainGeometry.orderEdgeChain(Array(edges.prefix(2))).map(\.id)
        let reversed = TrailChainGeometry.orderEdgeChain(Array(edges.prefix(2).reversed())).map(\.id)

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(Set(forward), Set(["run-a", "run-b"]))
    }

    func testNamingAndLiftPickerAreIndependentOfEdgeOrder() {
        let edges = fixtureEdges()
        let first = fixtureGraph(edges: edges)

        // Change a routing-only value to force a distinct NamingCache key;
        // naming output itself should remain identical.
        var reversedEdges = Array(edges.reversed())
        let liftIndex = try! XCTUnwrap(reversedEdges.firstIndex { $0.id == "lift-z" })
        reversedEdges[liftIndex] = reversedEdges[liftIndex].withAttributes(
            reversedEdges[liftIndex].attributes.enriched(waitTimeMinutes: 7)
        )
        let second = fixtureGraph(edges: reversedEdges)

        let firstNaming = MountainNaming(first)
        let secondNaming = MountainNaming(second)
        XCTAssertEqual(
            firstNaming.liftPickerEntries.map { "\($0.nodeId)|\($0.label)" },
            secondNaming.liftPickerEntries.map { "\($0.nodeId)|\($0.label)" }
        )
        XCTAssertEqual(
            firstNaming.nodeLabel("mid", style: .canonical),
            secondNaming.nodeLabel("mid", style: .canonical)
        )
        XCTAssertEqual(
            first.runTrailGroupSummaries().flatMap { $0.orderedRunEdges.map(\.id) },
            second.runTrailGroupSummaries().flatMap { $0.orderedRunEdges.map(\.id) }
        )
    }

    func testRendezvousLabelPrefersRecognizableLiftBaseLandmark() throws {
        let graph = fixtureGraph(edges: fixtureEdges())
        let naming = MountainNaming(graph)

        XCTAssertTrue(naming.nodeLabel("base-a").hasPrefix("Cruiser"))
        XCTAssertEqual(naming.meetingNodeLabel("base-a"), "Alpine Chair · Base")

        let point = try XCTUnwrap(
            RendezvousCatalog.derived(from: graph).points.first { $0.nodeID == "base-a" }
        )
        XCTAssertEqual(point.displayName, "Alpine Chair · Base")
    }

    func testRendezvousLabelNamesLiftMidStationInsteadOfAdjacentRun() throws {
        let base = GraphNode(
            id: "gondola-base",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 2_700,
            kind: .liftBase
        )
        let mid = GraphNode(
            id: "gondola-mid",
            coordinate: .init(latitude: 40.01, longitude: -106),
            elevation: 2_900,
            kind: .midStation
        )
        let runTop = GraphNode(
            id: "run-top",
            coordinate: .init(latitude: 40.015, longitude: -106),
            elevation: 3_000,
            kind: .trailHead
        )
        let graph = MountainGraph(
            resortID: "mid-station-label",
            nodes: [base.id: base, mid.id: mid, runTop.id: runTop],
            edges: [
                GraphEdge(
                    id: "gondola-lower",
                    sourceID: base.id,
                    targetID: mid.id,
                    kind: .lift,
                    geometry: [base.coordinate, mid.coordinate],
                    attributes: EdgeAttributes(
                        lengthMeters: 1_000,
                        trailName: "Village Gondola",
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "run-to-mid",
                    sourceID: runTop.id,
                    targetID: mid.id,
                    kind: .run,
                    geometry: [runTop.coordinate, mid.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 500,
                        verticalDrop: 100,
                        trailName: "Home Run",
                        isOpen: true,
                        trailGroupId: "home-run"
                    )
                ),
            ]
        )

        let naming = MountainNaming(graph)
        XCTAssertTrue(naming.nodeLabel(mid.id).hasPrefix("Home Run"))
        XCTAssertEqual(naming.meetingNodeLabel(mid.id), "Village Gondola · Mid-Station")
        XCTAssertEqual(
            try XCTUnwrap(
                RendezvousCatalog.derived(from: graph).points.first { $0.nodeID == mid.id }
            ).displayName,
            "Village Gondola · Mid-Station"
        )
    }

    func testDemoPickerIncludesNamedTrailWithoutLiftDifficultyOrMinimumLength() throws {
        let top = GraphNode(
            id: "isolated-top",
            coordinate: .init(latitude: 40.001, longitude: -106),
            elevation: 3_000,
            kind: .trailHead
        )
        let bottom = GraphNode(
            id: "isolated-bottom",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 2_990,
            kind: .trailEnd
        )
        let shortNamedRun = GraphEdge(
            id: "short-run",
            sourceID: top.id,
            targetID: bottom.id,
            kind: .run,
            geometry: [top.coordinate, bottom.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 25,
                verticalDrop: 10,
                trailName: "Hidden Connector",
                isOpen: true,
                trailGroupId: "hidden-connector"
            )
        )
        let graph = MountainGraph(
            resortID: "demo-catalog",
            nodes: [top.id: top, bottom.id: bottom],
            edges: [shortNamedRun]
        )

        let entry = try XCTUnwrap(RoutingTestSheet.trailEntries(in: graph).first)

        XCTAssertEqual(entry.trailGroupId, "hidden-connector")
        XCTAssertEqual(entry.nodeId, top.id)
        XCTAssertEqual(entry.name, "Hidden Connector")
        XCTAssertNil(entry.difficulty)
    }

    private func fixtureGraph(edges: [GraphEdge]) -> MountainGraph {
        let nodes = fixtureNodes()
        return MountainGraph(
            resortID: "determinism",
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
            edges: edges
        )
    }

    private func fixtureNodes() -> [GraphNode] {
        [
            GraphNode(id: "top", coordinate: .init(latitude: 40.03, longitude: -106), elevation: 3_100, kind: .liftTop),
            GraphNode(id: "mid", coordinate: .init(latitude: 40.02, longitude: -106), elevation: 3_000, kind: .junction),
            GraphNode(id: "base-a", coordinate: .init(latitude: 40.01, longitude: -106), elevation: 2_900, kind: .liftBase),
            GraphNode(id: "base-z", coordinate: .init(latitude: 40.01, longitude: -106.01), elevation: 2_900, kind: .liftBase)
        ]
    }

    private func fixtureEdges() -> [GraphEdge] {
        let nodes = Dictionary(uniqueKeysWithValues: fixtureNodes().map { ($0.id, $0) })
        func geometry(_ source: String, _ target: String) -> [CLLocationCoordinate2D] {
            [nodes[source]!.coordinate, nodes[target]!.coordinate]
        }
        return [
            GraphEdge(
                id: "run-a", sourceID: "top", targetID: "mid", kind: .run,
                geometry: geometry("top", "mid"),
                attributes: EdgeAttributes(
                    difficulty: .blue, lengthMeters: 500, verticalDrop: 100,
                    trailName: "Cruiser", isOpen: true, trailGroupId: "cruiser"
                )
            ),
            GraphEdge(
                id: "run-b", sourceID: "mid", targetID: "base-a", kind: .run,
                geometry: geometry("mid", "base-a"),
                attributes: EdgeAttributes(
                    difficulty: .blue, lengthMeters: 500, verticalDrop: 100,
                    trailName: "Cruiser", isOpen: true, trailGroupId: "cruiser"
                )
            ),
            GraphEdge(
                id: "lift-z", sourceID: "base-z", targetID: "top", kind: .lift,
                geometry: geometry("base-z", "top"),
                attributes: EdgeAttributes(
                    lengthMeters: 1_000, trailName: "Summit Express", isOpen: true
                )
            ),
            GraphEdge(
                id: "lift-a", sourceID: "base-a", targetID: "top", kind: .lift,
                geometry: geometry("base-a", "top"),
                attributes: EdgeAttributes(
                    lengthMeters: 1_000, trailName: "Alpine Chair", isOpen: true
                )
            )
        ]
    }
}
