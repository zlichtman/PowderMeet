//
//  MountainGraphTests.swift
//  PowderMeetTests
//
//  Audit §7.2 foundation. Per-resort golden fixtures still need
//  capture (planned as a separate workflow), but in the meantime this
//  pins the contract every fixture-based test will rely on:
//
//   1. `MountainGraph.fingerprint` is deterministic for identical
//      inputs — different processes / runs / orderings of the same
//      node + edge set must produce the same string. The solver
//      cache and per-skier edge-history cache key on it; drift here
//      silently invalidates every cached solution across restarts.
//
//   2. The fingerprint changes when meaningful state changes
//      (added node, added edge, edge attribute that affects routing).
//
//   3. Graph identity invariants: edge ids unique, edges reference
//      nodes that actually exist.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class MountainGraphTests: XCTestCase {

    /// Tiny synthetic graph: two nodes connected by one blue run edge.
    /// Built fresh each test so mutations in one don't leak into
    /// another.
    private func makeBaseline() -> MountainGraph {
        let nodes: [String: GraphNode] = [
            "n-top": GraphNode(
                id: "n-top",
                coordinate: .init(latitude: 39.65, longitude: -106.36),
                elevation: 3500, kind: .liftTop
            ),
            "n-base": GraphNode(
                id: "n-base",
                coordinate: .init(latitude: 39.61, longitude: -106.36),
                elevation: 2500, kind: .liftBase
            )
        ]
        let edge = GraphEdge(
            id: "e-blue-1",
            sourceID: "n-top",
            targetID: "n-base",
            kind: .run,
            geometry: [
                .init(latitude: 39.65, longitude: -106.36),
                .init(latitude: 39.63, longitude: -106.36),
                .init(latitude: 39.61, longitude: -106.36)
            ],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 4400,
                verticalDrop: 1000,
                trailName: "Mid Mountain Cruise",
                isOpen: true
            )
        )
        return MountainGraph(resortID: "test-resort", nodes: nodes, edges: [edge])
    }

    func testFingerprintIsNonEmpty() {
        let g = makeBaseline()
        XCTAssertFalse(g.fingerprint.isEmpty)
    }

    func testFingerprintDeterministic() {
        let a = makeBaseline()
        let b = makeBaseline()
        XCTAssertEqual(a.fingerprint, b.fingerprint,
                       "Same inputs MUST produce the same fingerprint — the solver cache keys on it")
    }

    func testFingerprintChangesOnAddedNode() {
        let baseline = makeBaseline()
        var nodes = baseline.nodes
        nodes["n-extra"] = GraphNode(
            id: "n-extra",
            coordinate: .init(latitude: 39.62, longitude: -106.35),
            elevation: 2800, kind: .junction
        )
        let mutated = MountainGraph(resortID: "test-resort", nodes: nodes, edges: baseline.edges)
        XCTAssertNotEqual(baseline.fingerprint, mutated.fingerprint)
    }

    func testFingerprintChangesOnAddedEdge() {
        let baseline = makeBaseline()
        let extraEdge = GraphEdge(
            id: "e-blue-2",
            sourceID: "n-base",
            targetID: "n-top",
            kind: .lift,
            geometry: [
                .init(latitude: 39.61, longitude: -106.36),
                .init(latitude: 39.65, longitude: -106.36)
            ],
            attributes: EdgeAttributes(lengthMeters: 4400, liftType: .chairLift, isOpen: true)
        )
        let mutated = MountainGraph(
            resortID: "test-resort",
            nodes: baseline.nodes,
            edges: baseline.edges + [extraEdge]
        )
        XCTAssertNotEqual(baseline.fingerprint, mutated.fingerprint)
    }

    func testEdgeReferencesPointToValidNodes() {
        let g = makeBaseline()
        for edge in g.edges {
            XCTAssertNotNil(g.nodes[edge.sourceID],
                            "Edge \(edge.id) source \(edge.sourceID) missing from nodes")
            XCTAssertNotNil(g.nodes[edge.targetID],
                            "Edge \(edge.id) target \(edge.targetID) missing from nodes")
        }
    }

    func testEdgeIdsAreUnique() {
        let g = makeBaseline()
        let ids = g.edges.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate edge id in graph")
    }
}
