//
//  MountainGraphIntegrityTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class MountainGraphIntegrityTests: XCTestCase {
    func testGraphFetchResponseDecodesCompleteImmutableIdentity() throws {
        let sha = String(repeating: "a", count: 64)
        let json = """
        {
          "status": "fetch",
          "manifest_version": 7,
          "current_manifest_version": 9,
          "graph_version": "v11",
          "blob_url": "https://example.com/graph",
          "sha256": "\(sha)",
          "snapshot_date": "2026-08-02"
        }
        """

        let response = try JSONDecoder().decode(
            GetResortGraphResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.status, .fetch)
        XCTAssertEqual(response.manifestVersion, 7)
        XCTAssertEqual(response.currentManifestVersion, 9)
        XCTAssertEqual(response.graphVersion, "v11")
        XCTAssertEqual(response.sha256, sha)
    }

    func testValidCanonicalWireDecodesAndMatchesAdvertisedFingerprint() throws {
        let graph = makeValidGraph()

        let decoded = try CanonicalMountainGraphDecoder.decode(
            wireData(for: graph),
            expectedResortID: "test"
        )

        XCTAssertEqual(decoded.resortID, "test")
        XCTAssertEqual(decoded.fingerprint, graph.fingerprint)
    }

    func testCanonicalWireCarriesValidatedRendezvousCatalog() throws {
        let graph = makeValidGraph(startKind: .liftBase)
        var wire = try wireObject(for: graph)
        wire["rendezvousCatalog"] = [
            "points": [[
                "id": "start",
                "nodeID": "start",
                "kind": "liftBase",
                "displayName": "Test Chair Base",
                "confidence": 0.95,
                "quality": 0.9
            ]]
        ]

        let payload = try CanonicalMountainGraphDecoder.decodePayload(
            JSONSerialization.data(withJSONObject: wire),
            expectedResortID: "test"
        )

        XCTAssertEqual(payload.rendezvousPoints?.map(\.id), ["start"])
        XCTAssertEqual(payload.rendezvousPoints?.first?.displayName, "Test Chair Base")
    }

    func testInvalidCanonicalRendezvousCatalogFailsClosed() throws {
        let graph = makeValidGraph()
        var wire = try wireObject(for: graph)
        wire["rendezvousCatalog"] = [
            "points": [[
                "id": "start",
                "nodeID": "start",
                "kind": "liftBase",
                "displayName": "Unsafe Trail Point",
                "confidence": 0.95,
                "quality": 0.9
            ]]
        ]

        XCTAssertThrowsError(try CanonicalMountainGraphDecoder.decodePayload(
            JSONSerialization.data(withJSONObject: wire),
            expectedResortID: "test"
        )) { error in
            XCTAssertEqual(
                error as? MountainGraphIntegrityError,
                .invalidRendezvousCatalog
            )
        }
    }

    func testWrongResortIsRejectedBeforeDatasetConstruction() throws {
        let graph = makeValidGraph()

        assertIntegrityError(
            .resortMismatch(expected: "other", actual: "test")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: graph),
                expectedResortID: "other"
            )
        }
    }

    func testMissingAndMismatchedAdvertisedFingerprintsAreRejected() throws {
        let graph = makeValidGraph()
        var missing = try wireObject(for: graph)
        missing.removeValue(forKey: "fingerprint")
        assertIntegrityError(.missingAdvertisedFingerprint) {
            try CanonicalMountainGraphDecoder.decode(
                JSONSerialization.data(withJSONObject: missing),
                expectedResortID: "test"
            )
        }

        var mismatch = try wireObject(for: graph)
        mismatch["fingerprint"] = "1:1:0000000000000000"
        assertIntegrityError(
            .fingerprintMismatch(
                expected: "1:1:0000000000000000",
                actual: graph.fingerprint
            )
        ) {
            try CanonicalMountainGraphDecoder.decode(
                JSONSerialization.data(withJSONObject: mismatch),
                expectedResortID: "test"
            )
        }
    }

    func testDanglingEndpointAndDuplicateEdgeIDsAreRejected() throws {
        let valid = makeValidGraph()
        let original = try XCTUnwrap(valid.edges.first)
        let danglingEdge = GraphEdge(
            id: original.id,
            sourceID: original.sourceID,
            targetID: "missing",
            kind: original.kind,
            geometry: original.geometry,
            attributes: original.attributes
        )
        let dangling = MountainGraph(
            resortID: valid.resortID,
            nodes: valid.nodes,
            edges: [danglingEdge]
        )
        assertIntegrityError(
            .missingEndpoint(edgeID: "run-1", nodeID: "missing", endpoint: "target")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: dangling),
                expectedResortID: "test"
            )
        }

        let duplicate = MountainGraph(
            resortID: valid.resortID,
            nodes: valid.nodes,
            edges: [original, original]
        )
        assertIntegrityError(.duplicateEdgeID("run-1")) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: duplicate),
                expectedResortID: "test"
            )
        }
    }

    func testNodeDictionaryIdentityAndCoordinateRangeAreValidated() throws {
        let valid = makeValidGraph()
        var badKeyNodes = valid.nodes
        let start = try XCTUnwrap(badKeyNodes.removeValue(forKey: "start"))
        badKeyNodes["wrong-key"] = start
        let badKey = MountainGraph(
            resortID: valid.resortID,
            nodes: badKeyNodes,
            edges: valid.edges
        )
        assertIntegrityError(
            .nodeKeyMismatch(dictionaryKey: "wrong-key", nodeID: "start")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: badKey),
                expectedResortID: "test"
            )
        }

        let invalidNode = GraphNode(
            id: "start",
            coordinate: .init(latitude: 91, longitude: -106.3),
            elevation: 3_000,
            kind: .trailHead
        )
        let badCoordinate = MountainGraph(
            resortID: valid.resortID,
            nodes: ["start": invalidNode, "end": valid.nodes["end"]!],
            edges: valid.edges
        )
        assertIntegrityError(.invalidNodeCoordinate(nodeID: "start")) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: badCoordinate),
                expectedResortID: "test"
            )
        }
    }

    func testMalformedGeometryPairThrowsInsteadOfIndexing() throws {
        let graph = makeValidGraph()
        var object = try wireObject(for: graph)
        var edges = try XCTUnwrap(object["edges"] as? [[String: Any]])
        edges[0]["geometryPairs"] = [[-106.3]]
        object["edges"] = edges

        XCTAssertThrowsError(
            try CanonicalMountainGraphDecoder.decode(
                JSONSerialization.data(withJSONObject: object),
                expectedResortID: "test"
            )
        ) { error in
            guard let integrityError = error as? MountainGraphIntegrityError,
                  case .decodingFailed = integrityError else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }

    func testDetachedGeometryEndpointIsRejected() throws {
        let valid = makeValidGraph()
        let edge = try XCTUnwrap(valid.edges.first)
        let detached = GraphEdge(
            id: edge.id,
            sourceID: edge.sourceID,
            targetID: edge.targetID,
            kind: edge.kind,
            geometry: [
                .init(latitude: 39.61, longitude: -106.3),
                edge.geometry[1],
            ],
            attributes: edge.attributes
        )
        let graph = MountainGraph(
            resortID: valid.resortID,
            nodes: valid.nodes,
            edges: [detached]
        )

        assertIntegrityError(
            .geometryEndpointMismatch(edgeID: "run-1", endpoint: "source")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: graph),
                expectedResortID: "test"
            )
        }
    }

    func testNonpositiveLengthAndOutOfRangeSignalsAreRejected() throws {
        let valid = makeValidGraph()
        let edge = try XCTUnwrap(valid.edges.first)
        let zeroLength = edge.withAttributes(
            EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 0,
                verticalDrop: 100,
                averageGradient: 42,
                maxGradient: 45,
                aspect: 180,
                aspectVariance: 0.1,
                trailName: "Test Run",
                obstacleDensity: 1.1
            )
        )
        let graph = MountainGraph(
            resortID: valid.resortID,
            nodes: valid.nodes,
            edges: [zeroLength]
        )

        assertIntegrityError(
            .invalidAttribute(edgeID: "run-1", field: "lengthMeters")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: graph),
                expectedResortID: "test"
            )
        }
    }

    func testV11LiftRequiresExplicitQueueEntrySemantics() throws {
        let base = GraphNode(
            id: "base",
            coordinate: .init(latitude: 39.599, longitude: -106.3),
            elevation: 2_900,
            kind: .liftBase
        )
        let top = GraphNode(
            id: "top",
            coordinate: .init(latitude: 39.6, longitude: -106.3),
            elevation: 3_000,
            kind: .liftTop
        )
        let lift = GraphEdge(
            id: "lift-1",
            sourceID: base.id,
            targetID: top.id,
            kind: .lift,
            geometry: [base.coordinate, top.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 111,
                verticalDrop: 100,
                averageGradient: 42,
                maxGradient: 42,
                trailName: "Test Lift",
                liftType: .chairLift,
                rideTimeSeconds: 90,
                chargesLiftWait: nil
            )
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [base.id: base, top.id: top],
            edges: [lift]
        )

        assertIntegrityError(
            .invalidAttribute(edgeID: "lift-1", field: "chargesLiftWait")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: graph),
                expectedResortID: "test"
            )
        }
    }

    func testContinuationLiftCannotCarryAnotherQueueBaseline() throws {
        let base = GraphNode(
            id: "base",
            coordinate: .init(latitude: 39.599, longitude: -106.3),
            elevation: 2_900,
            kind: .midStation
        )
        let top = GraphNode(
            id: "top",
            coordinate: .init(latitude: 39.6, longitude: -106.3),
            elevation: 3_000,
            kind: .liftTop
        )
        let lift = GraphEdge(
            id: "lift-2",
            sourceID: base.id,
            targetID: top.id,
            kind: .lift,
            geometry: [base.coordinate, top.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 111,
                verticalDrop: 100,
                averageGradient: 42,
                maxGradient: 42,
                trailName: "Test Lift",
                liftType: .chairLift,
                rideTimeSeconds: 90,
                weekdayWaitMinutes: 3,
                chargesLiftWait: false
            )
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [base.id: base, top.id: top],
            edges: [lift]
        )

        assertIntegrityError(
            .invalidAttribute(edgeID: "lift-2", field: "continuationLiftWait")
        ) {
            try CanonicalMountainGraphDecoder.decode(
                wireData(for: graph),
                expectedResortID: "test"
            )
        }
    }

    private func makeValidGraph(
        startKind: GraphNode.NodeKind = .trailHead
    ) -> MountainGraph {
        let start = GraphNode(
            id: "start",
            coordinate: .init(latitude: 39.6, longitude: -106.3),
            elevation: 3_000,
            kind: startKind
        )
        let end = GraphNode(
            id: "end",
            coordinate: .init(latitude: 39.599, longitude: -106.3),
            elevation: 2_900,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "run-1",
            sourceID: start.id,
            targetID: end.id,
            kind: .run,
            geometry: [start.coordinate, end.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 111,
                verticalDrop: 100,
                averageGradient: 42,
                maxGradient: 45,
                aspect: 180,
                aspectVariance: 0.1,
                trailName: "Test Run",
                isOfficiallyValidated: true,
                midpointElevation: 2_950,
                estimatedTrailWidthMeters: 25,
                obstacleDensity: 0.2,
                fallLineExposure: 0.4
            )
        )
        return MountainGraph(
            resortID: "test",
            nodes: [start.id: start, end.id: end],
            edges: [edge]
        )
    }

    private func wireData(for graph: MountainGraph) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: wireObject(for: graph),
            options: [.sortedKeys]
        )
    }

    private func wireObject(for graph: MountainGraph) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(graph)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["fingerprint"] = graph.fingerprint
        return object
    }

    private func assertIntegrityError(
        _ expected: MountainGraphIntegrityError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> MountainGraph
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? MountainGraphIntegrityError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
