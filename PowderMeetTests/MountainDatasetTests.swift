//
//  MountainDatasetTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class MountainDatasetTests: XCTestCase {
    private let version = MountainDatasetVersion(
        manifestVersion: 7,
        graphVersion: "v8",
        contentSHA256: String(repeating: "a", count: 64)
    )

    func testDatasetVersionIdentifierRoundTripsCanonicalAndLegacyVersions() {
        let canonical = MountainDatasetVersion(
            manifestVersion: 12,
            graphVersion: "v11",
            contentSHA256: String(repeating: "a", count: 64)
        )
        let legacy = MountainDatasetVersion(
            manifestVersion: nil,
            graphVersion: "v9-s3",
            contentSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(
            MountainDatasetVersion(identifier: canonical.identifier),
            canonical
        )
        XCTAssertEqual(
            MountainDatasetVersion(identifier: legacy.identifier),
            legacy
        )
    }

    func testDatasetVersionIdentifierRejectsAmbiguousOrUnsafeValues() {
        XCTAssertNil(MountainDatasetVersion(identifier: "m0-v11-\(String(repeating: "a", count: 64))"))
        XCTAssertNil(MountainDatasetVersion(identifier: "m2-v11-short"))
        XCTAssertNil(MountainDatasetVersion(identifier: "m2-v11/other-\(String(repeating: "a", count: 64))"))
        XCTAssertNil(MountainDatasetVersion(identifier: "m2-v11-\(String(repeating: "A", count: 64))"))
    }

    func testLegacyCacheRequiresExactResortPinAndCurrentBuilder() {
        let base = makeDataset()
        let dataset = MountainDataset(resortID: base.resortID,
            version: .init(manifestVersion: nil, graphVersion: "v15-s3", contentSHA256: base.graph.fingerprint),
            snapshotDate: "2026-09-20", source: .legacySnapshot, graph: base.graph)
        XCTAssertTrue(LegacySnapshotCachePolicy.matches(dataset, resortID: "test", snapshotDate: "2026-09-20", graphVersion: "v15-s3"))
        XCTAssertFalse(LegacySnapshotCachePolicy.matches(dataset, resortID: "test", snapshotDate: "2026-04-28", graphVersion: "v15-s3"))
        XCTAssertFalse(LegacySnapshotCachePolicy.matches(dataset, resortID: "other", snapshotDate: "2026-09-20", graphVersion: "v15-s3"))
        XCTAssertFalse(LegacySnapshotCachePolicy.matches(dataset, resortID: "test", snapshotDate: "2026-09-20", graphVersion: "v13-s3"))
        XCTAssertFalse(LegacySnapshotCachePolicy.matches(base, resortID: "test", snapshotDate: "2026-08-02", graphVersion: "v8"))
    }

    private func makeDataset() -> MountainDataset {
        let top = GraphNode(
            id: "top",
            coordinate: .init(latitude: 39.6, longitude: -106.3),
            elevation: 3_000,
            kind: .trailHead
        )
        let base = GraphNode(
            id: "base",
            coordinate: .init(latitude: 39.59, longitude: -106.3),
            elevation: 2_800,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "segment-1",
            sourceID: top.id,
            targetID: base.id,
            kind: .run,
            geometry: [top.coordinate, base.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 500,
                verticalDrop: 200,
                trailName: "Test Run",
                isOpen: true
            )
        )
        return MountainDataset(
            resortID: "test",
            version: version,
            snapshotDate: "2026-08-02",
            source: .canonicalServer,
            graph: MountainGraph(
                resortID: "test",
                nodes: [top.id: top, base.id: base],
                edges: [edge]
            )
        )
    }

    func testFreshMatchingStatusProducesDerivedRoutingGraphWithoutMutatingDataset() {
        let dataset = makeDataset()
        let now = Date()
        let status = MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: dataset.version,
            observedAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(300),
            source: .canonicalSidecar,
            confidence: 1,
            segmentStates: [
                "segment-1": .init(isOpen: false, waitMinutes: nil)
            ]
        )

        let projected = dataset.routingGraph(applying: status, at: now)

        XCTAssertTrue(dataset.graph.edge(byID: "segment-1")!.attributes.isOpen)
        XCTAssertFalse(projected.edge(byID: "segment-1")!.attributes.isOpen)
        XCTAssertTrue(projected.outgoing(from: "top").isEmpty)
    }

    func testExpiredStatusIsNotApplied() {
        let dataset = makeDataset()
        let now = Date()
        let status = MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: dataset.version,
            observedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(-1),
            source: .canonicalSidecar,
            confidence: 1,
            segmentStates: ["segment-1": .init(isOpen: false, waitMinutes: nil)]
        )

        XCTAssertTrue(dataset.routingGraph(applying: status, at: now)
            .edge(byID: "segment-1")!.attributes.isOpen)
    }

    func testFutureDatedStatusIsNotApplied() {
        let dataset = makeDataset()
        let now = Date()
        let status = MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: dataset.version,
            observedAt: now.addingTimeInterval(300),
            expiresAt: now.addingTimeInterval(600),
            source: .canonicalSidecar,
            confidence: 1,
            segmentStates: ["segment-1": .init(isOpen: false, waitMinutes: nil)]
        )

        XCTAssertTrue(dataset.routingGraph(applying: status, at: now)
            .edge(byID: "segment-1")!.attributes.isOpen)
    }

    func testStatusForDifferentDatasetVersionIsNotApplied() {
        let dataset = makeDataset()
        let otherVersion = MountainDatasetVersion(
            manifestVersion: 6,
            graphVersion: "v8",
            contentSHA256: String(repeating: "b", count: 64)
        )
        let now = Date()
        let status = MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: otherVersion,
            observedAt: now,
            expiresAt: now.addingTimeInterval(300),
            source: .canonicalSidecar,
            confidence: 1,
            segmentStates: ["segment-1": .init(isOpen: false, waitMinutes: nil)]
        )

        XCTAssertTrue(dataset.routingGraph(applying: status, at: now)
            .edge(byID: "segment-1")!.attributes.isOpen)
    }

    func testStableIdSidecarDecodesToMountainStatus() throws {
        let dataset = makeDataset()
        let json = """
        {
          "resort_id": "test",
          "built_at": "2026-08-02T14:00:00Z",
          "expires_at": "2026-08-02T15:00:00Z",
          "segments": {
            "segment-1": { "is_open": false, "wait_minutes": 3 }
          }
        }
        """
        let blob = try JSONDecoder().decode(LiveStatusBlob.self, from: Data(json.utf8))
        let status = try XCTUnwrap(blob.mountainStatus(for: dataset))

        XCTAssertEqual(status.confidence, 1)
        XCTAssertEqual(status.segmentStates["segment-1"], .init(isOpen: false, waitMinutes: 3))
    }

    func testLegacyNameSidecarMapsOnceToStableSegmentId() throws {
        let dataset = makeDataset()
        let json = """
        {
          "resort_id": "test",
          "built_at": "2026-08-02T14:00:00Z",
          "expires_at": "2026-08-02T15:00:00Z",
          "trails": {
            "Test Run": { "is_open": false }
          },
          "lifts": {}
        }
        """
        let blob = try JSONDecoder().decode(LiveStatusBlob.self, from: Data(json.utf8))
        let status = try XCTUnwrap(blob.mountainStatus(for: dataset))

        XCTAssertEqual(status.confidence, 0.8)
        XCTAssertEqual(status.segmentStates["segment-1"], .init(isOpen: false, waitMinutes: nil))
    }

    func testSidecarForDifferentManifestIsRejected() throws {
        let dataset = makeDataset()
        let json = """
        {
          "resort_id": "test",
          "manifest_version": 6,
          "built_at": "2026-08-02T14:00:00Z",
          "expires_at": "2026-08-02T15:00:00Z",
          "trails": {
            "Test Run": { "is_open": false }
          }
        }
        """
        let blob = try JSONDecoder().decode(LiveStatusBlob.self, from: Data(json.utf8))

        XCTAssertNil(blob.mountainStatus(for: dataset))
    }

    func testOffSeasonSidecarClosesBaseOpenTerrain() throws {
        let dataset = makeDataset()
        let json = """
        {
          "resort_id": "test",
          "built_at": "2026-08-02T14:00:00Z",
          "expires_at": "2026-08-02T15:00:00Z",
          "status_mode": "off_season",
          "segments": {}
        }
        """
        let blob = try JSONDecoder().decode(LiveStatusBlob.self, from: Data(json.utf8))
        let status = try XCTUnwrap(blob.mountainStatus(for: dataset))

        XCTAssertFalse(status.segmentStates["segment-1"]?.isOpen ?? true)
        let duringSidecar = try XCTUnwrap(ISO8601Parser.parse("2026-08-02T14:30:00Z"))
        XCTAssertFalse(dataset.routingGraph(applying: status, at: duringSidecar)
            .edge(byID: "segment-1")!.attributes.isOpen)
    }

    func testGrosslyIncompleteActiveSidecarIsRejected() throws {
        let base = makeDataset()
        let top = base.graph.nodes["top"]!
        let bottom = base.graph.nodes["base"]!
        let edges = (1...3).map { index in
            GraphEdge(
                id: "segment-\(index)",
                sourceID: top.id,
                targetID: bottom.id,
                kind: .run,
                geometry: [top.coordinate, bottom.coordinate],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 500,
                    trailName: "Run \(index)",
                    isOpen: true
                )
            )
        }
        let dataset = MountainDataset(
            resortID: "test",
            version: version,
            snapshotDate: "2026-08-02",
            source: .canonicalServer,
            graph: MountainGraph(
                resortID: "test",
                nodes: base.graph.nodes,
                edges: edges
            )
        )
        let json = """
        {
          "resort_id": "test",
          "built_at": "2026-08-02T14:00:00Z",
          "expires_at": "2026-08-02T15:00:00Z",
          "status_mode": "active",
          "segments": {
            "segment-1": { "is_open": true }
          }
        }
        """
        let blob = try JSONDecoder().decode(LiveStatusBlob.self, from: Data(json.utf8))

        XCTAssertNil(blob.mountainStatus(for: dataset))
    }
}
