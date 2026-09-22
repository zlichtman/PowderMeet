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

    private func makeParityFixture(
        attributes: EdgeAttributes? = nil
    ) -> MountainGraph {
        let nodes: [String: GraphNode] = [
            "n-base": GraphNode(
                id: "n-base",
                coordinate: .init(latitude: 39.5, longitude: -106.25),
                elevation: 2_500,
                kind: .liftBase
            ),
            "n-top": GraphNode(
                id: "n-top",
                coordinate: .init(latitude: 39.75, longitude: -106.5),
                elevation: 3_500,
                kind: .liftTop
            )
        ]
        let completeAttributes = attributes ?? EdgeAttributes(
            difficulty: .blue,
            lengthMeters: 1_234.5,
            verticalDrop: 1_000,
            averageGradient: 12.25,
            maxGradient: 31.5,
            aspect: 180,
            aspectVariance: 0.125,
            trailName: "Alpine Ω",
            hasMoguls: true,
            isGroomed: false,
            isGladed: true,
            liftType: .chairLift,
            liftCapacity: 6,
            rideTimeSeconds: 321.5,
            waitTimeMinutes: 4.25,
            weekdayWaitMinutes: 3,
            weekendWaitMinutes: 8,
            chargesLiftWait: true,
            isOpen: true,
            isOfficiallyValidated: true,
            trailGroupId: "group-α",
            midpointElevation: 3_000,
            estimatedTrailWidthMeters: 17.5,
            obstacleDensity: 0.3,
            fallLineExposure: 0.75,
            nightGroomedFlag: true,
            lastGroomedHoursAgo: 7,
            estimatedSurfaceCondition: "crust"
        )
        let edge = GraphEdge(
            id: "edge-1",
            sourceID: "n-top",
            targetID: "n-base",
            kind: .run,
            geometry: [
                .init(latitude: 39.75, longitude: -106.5),
                .init(latitude: 39.6, longitude: -106.4),
                .init(latitude: 39.5, longitude: -106.25)
            ],
            attributes: completeAttributes
        )
        return MountainGraph(
            resortID: "parity-resort",
            nodes: nodes,
            edges: [edge]
        )
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

    func testV11FingerprintMatchesTypeScriptGoldenFixture() {
        XCTAssertEqual(
            makeParityFixture().fingerprint,
            "2:1:1d81c2adcccecaa9",
            "Swift and the server builder must hash the wire model identically"
        )
    }

    func testFingerprintNormalizesNegativeZeroToJSONWireSemantics() {
        let positiveZero = EdgeAttributes(lengthMeters: 0)
        let negativeZero = EdgeAttributes(lengthMeters: -0.0)

        XCTAssertEqual(
            makeParityFixture(attributes: positiveZero).fingerprint,
            makeParityFixture(attributes: negativeZero).fingerprint
        )
    }

    func testEdgeAttributesDecodeOlderWireWithoutCanonicalWaitFields() throws {
        let original = makeParityFixture().edges[0].attributes
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "weekdayWaitMinutes")
        object.removeValue(forKey: "weekendWaitMinutes")
        object.removeValue(forKey: "chargesLiftWait")
        let legacyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(
            EdgeAttributes.self,
            from: legacyData
        )
        XCTAssertNil(decoded.weekdayWaitMinutes)
        XCTAssertNil(decoded.weekendWaitMinutes)
        XCTAssertNil(decoded.chargesLiftWait)
        XCTAssertEqual(decoded.liftType, .chairLift)
    }

    func testFingerprintCoversEveryEdgeAttributeWireField() throws {
        let baseline = makeParityFixture()
        let encoded = try JSONEncoder().encode(baseline.edges[0].attributes)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let mutations: [String: Any] = [
            "difficulty": "black",
            "lengthMeters": 1_235.5,
            "verticalDrop": 999.0,
            "averageGradient": 13.25,
            "maxGradient": 32.5,
            "aspect": 181.0,
            "aspectVariance": 0.25,
            "trailName": "Different",
            "hasMoguls": false,
            "isGroomed": true,
            "isGladed": false,
            "liftType": "gondola",
            "liftCapacity": 8,
            "rideTimeSeconds": 322.5,
            "waitTimeMinutes": 5.25,
            "weekdayWaitMinutes": 4.0,
            "weekendWaitMinutes": 9.0,
            "chargesLiftWait": false,
            "isOpen": false,
            "isOfficiallyValidated": false,
            "estimatedTrailWidthMeters": 18.5,
            "obstacleDensity": 0.4,
            "fallLineExposure": 0.8,
            "nightGroomedFlag": false,
            "lastGroomedHoursAgo": 8,
            "estimatedSurfaceCondition": "hero",
            "trailGroupId": "different-group",
            "midpointElevation": 3_001.0
        ]

        for (field, value) in mutations {
            var changedObject = object
            changedObject[field] = value
            let changedData = try JSONSerialization.data(
                withJSONObject: changedObject,
                options: [.sortedKeys]
            )
            let changedAttributes = try JSONDecoder().decode(
                EdgeAttributes.self,
                from: changedData
            )
            XCTAssertNotEqual(
                baseline.fingerprint,
                makeParityFixture(attributes: changedAttributes).fingerprint,
                "Fingerprint omitted EdgeAttributes.\(field)"
            )
        }
    }

    func testFingerprintCoversNodeCoordinatesElevationAndKind() {
        let baseline = makeParityFixture()
        let top = baseline.nodes["n-top"]!
        let replacements = [
            GraphNode(
                id: top.id,
                coordinate: .init(
                    latitude: top.coordinate.latitude + 0.000_001,
                    longitude: top.coordinate.longitude
                ),
                elevation: top.elevation,
                kind: top.kind
            ),
            GraphNode(
                id: top.id,
                coordinate: top.coordinate,
                elevation: top.elevation + 1,
                kind: top.kind
            ),
            GraphNode(
                id: top.id,
                coordinate: top.coordinate,
                elevation: top.elevation,
                kind: .junction
            )
        ]

        for replacement in replacements {
            var nodes = baseline.nodes
            nodes[top.id] = replacement
            XCTAssertNotEqual(
                baseline.fingerprint,
                MountainGraph(
                    resortID: baseline.resortID,
                    nodes: nodes,
                    edges: baseline.edges
                ).fingerprint
            )
        }
    }

    func testFingerprintIsIndependentOfEdgeArrayOrder() {
        let baseline = makeBaseline()
        let lift = GraphEdge(
            id: "e-lift-1",
            sourceID: "n-base",
            targetID: "n-top",
            kind: .lift,
            geometry: [
                .init(latitude: 39.61, longitude: -106.36),
                .init(latitude: 39.65, longitude: -106.36)
            ],
            attributes: EdgeAttributes(lengthMeters: 4_400, liftType: .chairLift)
        )
        let forward = MountainGraph(
            resortID: baseline.resortID,
            nodes: baseline.nodes,
            edges: baseline.edges + [lift]
        )
        let reversed = MountainGraph(
            resortID: baseline.resortID,
            nodes: baseline.nodes,
            edges: [lift] + baseline.edges
        )
        XCTAssertEqual(forward.fingerprint, reversed.fingerprint)
    }

    func testFingerprintChangesWhenTopologyIdentityChanges() {
        let baseline = makeBaseline()
        let edge = baseline.edges[0]
        let reversed = GraphEdge(
            id: edge.id,
            sourceID: edge.targetID,
            targetID: edge.sourceID,
            kind: edge.kind,
            geometry: edge.geometry,
            attributes: edge.attributes
        )
        let changed = MountainGraph(
            resortID: baseline.resortID,
            nodes: baseline.nodes,
            edges: [reversed]
        )
        XCTAssertNotEqual(baseline.fingerprint, changed.fingerprint)
    }

    func testFingerprintChangesWhenGeometryOrNameChanges() {
        let baseline = makeBaseline()
        let edge = baseline.edges[0]
        let changedGeometry = GraphEdge(
            id: edge.id,
            sourceID: edge.sourceID,
            targetID: edge.targetID,
            kind: edge.kind,
            geometry: edge.geometry + [.init(latitude: 39.62, longitude: -106.35)],
            attributes: edge.attributes
        )
        let changedName = edge.withAttributes(
            edge.attributes.enriched(trailName: "Different Name")
        )
        XCTAssertNotEqual(
            baseline.fingerprint,
            MountainGraph(resortID: baseline.resortID, nodes: baseline.nodes, edges: [changedGeometry]).fingerprint
        )
        XCTAssertNotEqual(
            baseline.fingerprint,
            MountainGraph(resortID: baseline.resortID, nodes: baseline.nodes, edges: [changedName]).fingerprint
        )
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

    func testCuratedLiftOverlayPreservesArrivalDayBaselines() throws {
        let baseline = makeBaseline()
        let lift = GraphEdge(
            id: "l123",
            sourceID: "n-base",
            targetID: "n-top",
            kind: .lift,
            geometry: [
                baseline.nodes["n-base"]!.coordinate,
                baseline.nodes["n-top"]!.coordinate
            ],
            attributes: EdgeAttributes(
                lengthMeters: 4_400,
                liftType: .chairLift,
                waitTimeMinutes: 7,
                isOpen: true
            )
        )
        var graph = MountainGraph(
            resortID: "test-resort",
            nodes: baseline.nodes,
            edges: [lift]
        )
        let curated = CuratedResort(
            resortId: "test-resort",
            version: 1,
            trails: nil,
            lifts: [CuratedLift(
                name: "Deterministic Chair",
                osmWayIds: ["l123"],
                liftType: "chair_lift",
                capacity: 6,
                rideTimeSeconds: 360,
                verticalRise: 1_000,
                weekdayWaitMinutes: 2,
                weekendWaitMinutes: 9
            )],
            operatingHours: nil,
            graphBuildHints: nil,
            trailWhitelist: nil,
            liftWhitelist: nil
        )

        CuratedResortLoader.applyOverlay(curated, to: &graph)
        // Match the production `GraphEnricher.enrich` contract: overlays may
        // batch mutations, then indices/fingerprint rebuild exactly once.
        graph.rebuildIndices()
        let attributes = try XCTUnwrap(graph.edge(byID: "l123")?.attributes)
        XCTAssertEqual(attributes.waitTimeMinutes, 7, "real live wait must remain live")
        XCTAssertEqual(attributes.weekdayWaitMinutes, 2)
        XCTAssertEqual(attributes.weekendWaitMinutes, 9)
    }
}
