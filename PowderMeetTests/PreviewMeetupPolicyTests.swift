//
//  PreviewMeetupPolicyTests.swift
//  PowderMeetTests
//
//  Pre-release test meetups exercise the whole social flow on a preview map
//  without ever becoming live navigation or weakening a live meet's gates.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class PreviewMeetupPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)
    private let previewVersion = MountainDatasetVersion(
        manifestVersion: nil,
        graphVersion: "v15-s3",
        contentSHA256: String(repeating: "c", count: 64)
    )
    private let canonicalVersion = MountainDatasetVersion(
        manifestVersion: 3,
        graphVersion: "v15",
        contentSHA256: String(repeating: "a", count: 64)
    )

    func testOnlyWellFormedLegacyIdentitiesArePreviewMeets() {
        XCTAssertTrue(PreviewMeetupPolicy.isPreviewIdentity(previewVersion.identifier))
        XCTAssertFalse(PreviewMeetupPolicy.isPreviewIdentity(canonicalVersion.identifier))
        XCTAssertFalse(PreviewMeetupPolicy.isPreviewIdentity(nil))
        XCTAssertFalse(PreviewMeetupPolicy.isPreviewIdentity("mlegacy-v15-s3-not-a-sha"))
    }

    func testSendingRequiresPreReleaseStrictPreviewSolveOnPreviewMap() {
        XCTAssertTrue(PreviewMeetupPolicy.canSend(
            isPreRelease: true, solveAttempt: .nonCanonicalDataset, datasetSource: .legacySnapshot))
        XCTAssertFalse(PreviewMeetupPolicy.canSend(
            isPreRelease: false, solveAttempt: .nonCanonicalDataset, datasetSource: .legacySnapshot))
        XCTAssertFalse(PreviewMeetupPolicy.canSend(
            isPreRelease: true, solveAttempt: .nonCanonicalDataset, datasetSource: .canonicalServer))
        XCTAssertFalse(PreviewMeetupPolicy.canSend(
            isPreRelease: true, solveAttempt: .forcedOpen, datasetSource: .legacySnapshot))
        XCTAssertFalse(PreviewMeetupPolicy.canSend(
            isPreRelease: true, solveAttempt: nil, datasetSource: .legacySnapshot))
    }

    func testActivationRequiresTheExactSenderPreviewMapInAPreReleaseBuild() {
        let identity = previewVersion.identifier
        XCTAssertTrue(PreviewMeetupPolicy.canActivate(
            isPreRelease: true, requestDatasetVersion: identity,
            datasetSource: .legacySnapshot, datasetVersion: identity))
        XCTAssertFalse(PreviewMeetupPolicy.canActivate(
            isPreRelease: false, requestDatasetVersion: identity,
            datasetSource: .legacySnapshot, datasetVersion: identity))
        XCTAssertFalse(PreviewMeetupPolicy.canActivate(
            isPreRelease: true, requestDatasetVersion: identity,
            datasetSource: .legacySnapshot,
            datasetVersion: MountainDatasetVersion(
                manifestVersion: nil, graphVersion: "v15-s3",
                contentSHA256: String(repeating: "d", count: 64)
            ).identifier))
        // A canonical request never activates through the preview path.
        XCTAssertFalse(PreviewMeetupPolicy.canActivate(
            isPreRelease: true, requestDatasetVersion: canonicalVersion.identifier,
            datasetSource: .canonicalServer, datasetVersion: canonicalVersion.identifier))
    }

    func testSessionIdentityNeverCrossesBetweenPreviewAndCanonicalData() {
        let preview = makeDataset(source: .legacySnapshot, version: previewVersion)
        let canonical = makeDataset(source: .canonicalServer, version: canonicalVersion)
        let previewIdentity = ActiveMeetDatasetIdentity(
            resortID: "test", datasetVersion: previewVersion.identifier)
        let liveIdentity = ActiveMeetDatasetIdentity(
            resortID: "test", datasetVersion: canonicalVersion.identifier)

        XCTAssertTrue(previewIdentity.isPreview)
        XCTAssertFalse(liveIdentity.isPreview)
        XCTAssertTrue(previewIdentity.matches(dataset: preview, graph: preview.graph))
        XCTAssertTrue(liveIdentity.matches(dataset: canonical, graph: canonical.graph))

        // Same identity string on the wrong source still drifts.
        let spoofedLegacy = makeDataset(source: .legacySnapshot, version: canonicalVersion)
        XCTAssertFalse(liveIdentity.matches(dataset: spoofedLegacy, graph: spoofedLegacy.graph))
        let spoofedCanonical = makeDataset(source: .canonicalServer, version: previewVersion)
        XCTAssertFalse(previewIdentity.matches(dataset: spoofedCanonical, graph: spoofedCanonical.graph))
    }

    func testPreviewSessionIsValidatedAgainstItsMapWithoutStatus() {
        let dataset = makeDataset(source: .legacySnapshot, version: previewVersion)
        let identity = ActiveMeetDatasetIdentity(
            resortID: "test", datasetVersion: previewVersion.identifier)

        XCTAssertEqual(evaluate(identity, dataset, local: ["ab", "bc"], friend: ["db", "bc"]), .valid)
        XCTAssertEqual(evaluate(identity, dataset, local: ["ab", "missing"], friend: ["db", "bc"]),
                       .routeRequiresReroute)
    }

    func testLiveSessionStillRequiresStatusAndNeverTakesThePreviewBranch() {
        let canonical = makeDataset(source: .canonicalServer, version: canonicalVersion)
        let liveIdentity = ActiveMeetDatasetIdentity(
            resortID: "test", datasetVersion: canonicalVersion.identifier)
        XCTAssertEqual(evaluate(liveIdentity, canonical, local: ["ab", "bc"], friend: ["db", "bc"]),
                       .statusUnavailable)

        // A preview meet whose map was replaced by canonical data ends.
        let previewIdentity = ActiveMeetDatasetIdentity(
            resortID: "test", datasetVersion: previewVersion.identifier)
        XCTAssertEqual(evaluate(previewIdentity, canonical, local: ["ab", "bc"], friend: ["db", "bc"]),
                       .datasetDrift)
    }

    func testLiveActivationGateIsUnchangedByPreviewSupport() {
        let canonical = makeDataset(source: .canonicalServer, version: canonicalVersion)
        let routable = status(for: canonical, mode: .active)
        XCTAssertTrue(MeetupSessionController.canActivateLive(
            dataset: canonical, requestedDatasetVersion: canonicalVersion.identifier,
            status: routable, now: now))
        XCTAssertFalse(MeetupSessionController.canActivateLive(
            dataset: canonical, requestedDatasetVersion: canonicalVersion.identifier,
            status: nil, now: now))
        XCTAssertFalse(MeetupSessionController.canActivateLive(
            dataset: canonical, requestedDatasetVersion: canonicalVersion.identifier,
            status: status(for: canonical, mode: .offSeason), now: now))
        let preview = makeDataset(source: .legacySnapshot, version: previewVersion)
        XCTAssertFalse(MeetupSessionController.canActivateLive(
            dataset: preview, requestedDatasetVersion: previewVersion.identifier,
            status: status(for: preview, mode: .active), now: now))
    }

    private func evaluate(
        _ identity: ActiveMeetDatasetIdentity,
        _ dataset: MountainDataset,
        local: [String],
        friend: [String]
    ) -> ActiveRouteOperationalDecision {
        ActiveRouteOperationalValidator.evaluate(
            identity: identity,
            dataset: dataset,
            status: nil,
            localRemainingEdgeIDs: local,
            friendEdgeIDs: friend,
            meetingNodeID: "c",
            now: now
        )
    }

    private func status(
        for dataset: MountainDataset,
        mode: MountainStatus.OperatingMode
    ) -> MountainStatus {
        MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: dataset.version,
            observedAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(300),
            source: .canonicalSidecar,
            operatingMode: mode,
            confidence: 1,
            segmentStates: [:]
        )
    }

    private func makeDataset(
        source: MountainDataset.Source,
        version: MountainDatasetVersion
    ) -> MountainDataset {
        let coordinates: [String: CLLocationCoordinate2D] = [
            "a": .init(latitude: 39.603, longitude: -106.30),
            "b": .init(latitude: 39.602, longitude: -106.30),
            "c": .init(latitude: 39.601, longitude: -106.30),
            "d": .init(latitude: 39.602, longitude: -106.31)
        ]
        let nodes = Dictionary(uniqueKeysWithValues: coordinates.map { id, coordinate in
            (id, GraphNode(
                id: id,
                coordinate: coordinate,
                elevation: id == "c" ? 2_800 : 3_000,
                kind: id == "c" ? .liftBase : .junction
            ))
        })
        func edge(_ id: String, _ from: String, _ to: String) -> GraphEdge {
            GraphEdge(
                id: id, sourceID: from, targetID: to, kind: .run,
                geometry: [coordinates[from]!, coordinates[to]!],
                attributes: EdgeAttributes(
                    difficulty: .blue, lengthMeters: 100, verticalDrop: 50,
                    trailName: id, isOpen: true
                )
            )
        }
        return MountainDataset(
            resortID: "test",
            version: version,
            snapshotDate: "2026-04-28",
            source: source,
            graph: MountainGraph(
                resortID: "test",
                nodes: nodes,
                edges: [edge("ab", "a", "b"), edge("bc", "b", "c"), edge("db", "d", "b")]
            )
        )
    }
}
