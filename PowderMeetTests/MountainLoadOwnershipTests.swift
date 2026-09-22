//
//  MountainLoadOwnershipTests.swift
//  PowderMeetTests
//
//  Covers latest-request-wins publication and canonical activity-matching
//  graph selection without requiring network or production services.
//

import XCTest
@testable import PowderMeet

final class MountainLoadOwnershipTests: XCTestCase {

    func testIdenticalInflightRequestIsCoalesced() {
        var arbiter = ResortLoadArbiter()
        let key = request(resortID: "vail")

        XCTAssertNotNil(arbiter.begin(key))
        XCTAssertNil(arbiter.begin(key))
    }

    func testForcedOperationalRefreshSupersedesOrdinaryCachedLoad() throws {
        var arbiter = ResortLoadArbiter()
        let ordinary = try XCTUnwrap(arbiter.begin(request(resortID: "vail")))
        let refreshed = try XCTUnwrap(arbiter.begin(request(
            resortID: "vail",
            forceOperationalRefresh: true
        )))

        XCTAssertFalse(arbiter.isLatest(ordinary))
        XCTAssertTrue(arbiter.isLatest(refreshed))
    }

    func testNewerResortRequestOwnsPublicationAndFinish() throws {
        var arbiter = ResortLoadArbiter()
        let first = try XCTUnwrap(arbiter.begin(request(resortID: "vail")))
        let second = try XCTUnwrap(arbiter.begin(request(resortID: "whistler")))

        XCTAssertFalse(arbiter.isLatest(first))
        XCTAssertTrue(arbiter.isLatest(second))
        XCTAssertFalse(arbiter.finish(first))
        XCTAssertEqual(arbiter.activeKey?.resortID, "whistler")
        XCTAssertTrue(arbiter.finish(second))
        XCTAssertNil(arbiter.activeKey)
    }

    func testNewerExactVersionOfSameResortOwnsPublication() throws {
        var arbiter = ResortLoadArbiter()
        let first = try XCTUnwrap(arbiter.begin(request(
            resortID: "vail",
            manifest: 4,
            dataset: "dataset-4"
        )))
        let second = try XCTUnwrap(arbiter.begin(request(
            resortID: "vail",
            manifest: 5,
            dataset: "dataset-5"
        )))

        XCTAssertFalse(arbiter.isLatest(first))
        XCTAssertTrue(arbiter.isLatest(second))
    }

    func testFinishedTicketStaysLatestUntilAnotherLoadBegins() throws {
        var arbiter = ResortLoadArbiter()
        let delivered = try XCTUnwrap(arbiter.begin(request(resortID: "vail")))

        XCTAssertTrue(arbiter.finish(delivered))
        XCTAssertTrue(arbiter.isLatest(delivered))

        _ = arbiter.begin(request(resortID: "whistler"))
        XCTAssertFalse(arbiter.isLatest(delivered))
    }

    func testCanonicalLiveMatchingUsesImmutableDatasetGraph() async throws {
        let graph = testGraph(resortID: "vail")
        let dataset = MountainDataset(
            resortID: "vail",
            version: MountainDatasetVersion(
                manifestVersion: 1,
                graphVersion: MountainRepository.canonicalGraphVersion,
                contentSHA256: String(repeating: "a", count: 64)
            ),
            snapshotDate: "2026-08-10",
            source: .canonicalServer,
            graph: graph
        )

        let selected = await LiveRunRecorder.matchingGraph(
            dataset: dataset,
            displayedGraph: nil,
            resortID: "vail"
        )

        XCTAssertEqual(selected?.fingerprint, dataset.graph.fingerprint)
    }

    func testLiveMatchingRejectsDatasetFromDifferentResort() async {
        let graph = testGraph(resortID: "vail")
        let dataset = MountainDataset(
            resortID: "vail",
            version: MountainDatasetVersion(
                manifestVersion: 1,
                graphVersion: MountainRepository.canonicalGraphVersion,
                contentSHA256: String(repeating: "b", count: 64)
            ),
            snapshotDate: nil,
            source: .canonicalServer,
            graph: graph
        )

        let selected = await LiveRunRecorder.matchingGraph(
            dataset: dataset,
            displayedGraph: nil,
            resortID: "whistler"
        )

        XCTAssertNil(selected)
    }

    func testActiveMeetIdentityRejectsDifferentCanonicalDataset() {
        let graph = testGraph(resortID: "vail")
        let original = canonicalDataset(graph: graph, manifest: 1, sha: "c")
        let replacement = canonicalDataset(graph: graph, manifest: 2, sha: "d")
        let identity = ActiveMeetDatasetIdentity(
            resortID: original.resortID,
            datasetVersion: original.version.identifier
        )

        XCTAssertTrue(identity.matches(dataset: original, graph: graph))
        XCTAssertFalse(identity.matches(dataset: replacement, graph: graph))
    }

    func testActiveMeetIdentityRejectsLegacyDataset() {
        let graph = testGraph(resortID: "vail")
        let legacy = MountainDataset(
            resortID: "vail",
            version: MountainDatasetVersion(
                manifestVersion: nil,
                graphVersion: MountainRepository.expectedLegacyVersion,
                contentSHA256: String(repeating: "e", count: 64)
            ),
            snapshotDate: nil,
            source: .legacySnapshot,
            graph: graph
        )
        let identity = ActiveMeetDatasetIdentity(
            resortID: "vail",
            datasetVersion: legacy.version.identifier
        )

        XCTAssertFalse(identity.matches(dataset: legacy, graph: graph))
    }

    private func request(
        resortID: String,
        snapshot: String? = nil,
        manifest: Int? = nil,
        dataset: String? = nil,
        forceOperationalRefresh: Bool = false
    ) -> ResortLoadRequestKey {
        ResortLoadRequestKey(
            resortID: resortID,
            snapshotOverride: snapshot,
            manifestVersionOverride: manifest,
            datasetVersionOverride: dataset,
            forceOperationalRefresh: forceOperationalRefresh
        )
    }

    private func canonicalDataset(
        graph: MountainGraph,
        manifest: Int,
        sha: Character
    ) -> MountainDataset {
        MountainDataset(
            resortID: graph.resortID,
            version: MountainDatasetVersion(
                manifestVersion: manifest,
                graphVersion: MountainRepository.canonicalGraphVersion,
                contentSHA256: String(repeating: sha, count: 64)
            ),
            snapshotDate: nil,
            source: .canonicalServer,
            graph: graph
        )
    }

    private func testGraph(resortID: String) -> MountainGraph {
        let top = GraphNode(
            id: "top",
            coordinate: .init(latitude: 39.64, longitude: -106.37),
            elevation: 3_000,
            kind: .liftTop
        )
        let bottom = GraphNode(
            id: "bottom",
            coordinate: .init(latitude: 39.63, longitude: -106.36),
            elevation: 2_800,
            kind: .junction
        )
        let edge = GraphEdge(
            id: "run-1",
            sourceID: top.id,
            targetID: bottom.id,
            kind: .run,
            geometry: [top.coordinate, bottom.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                verticalDrop: 200,
                averageGradient: 12,
                maxGradient: 18,
                isOpen: true
            )
        )
        return MountainGraph(
            resortID: resortID,
            nodes: [top.id: top, bottom.id: bottom],
            edges: [edge]
        )
    }
}
