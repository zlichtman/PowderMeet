//
//  MapLayerStateTests.swift
//  PowderMeetTests
//
//  Diff-state struct equality contracts. The whole purpose of these
//  Hashable structs is to gate per-source GeoJSON rebuilds — if the
//  Hashable derivation drops or duplicates a field, the map silently
//  over- or under-rebuilds. Pin the equality semantics here.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class MapLayerStateTests: XCTestCase {

    private func routeEdge(_ id: String) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: "\(id)-source",
            targetID: "\(id)-target",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 100,
                isOpen: true
            )
        )
    }

    func testActiveMapRouteShowsOnlyUnfinishedCorridor() {
        let path = [routeEdge("one"), routeEdge("two"), routeEdge("three")]
        let slice = ActiveMapRouteSlice.remaining(
            path: path,
            currentEdgeIndex: 1,
            currentEdgeFraction: 0.42
        )

        XCTAssertEqual(slice.edges.map(\.id), ["two", "three"])
        XCTAssertEqual(slice.initialEdgeFraction, 0.42, accuracy: 0.001)
        XCTAssertTrue(ActiveMapRouteSlice.remaining(
            path: path,
            currentEdgeIndex: 3,
            currentEdgeFraction: 1
        ).edges.isEmpty)
    }

    func testPausedGuidanceHidesOnlyLocalRouteWithoutMutatingAcceptedPath() {
        let path = [routeEdge("one"), routeEdge("two")]
        let slice = ActiveMapRouteSlice.remaining(path: path, currentEdgeIndex: 1, currentEdgeFraction: 0.4)
        XCTAssertTrue(slice.visible(isGuidancePaused: true).edges.isEmpty)
        XCTAssertEqual(slice.visible(isGuidancePaused: true).initialEdgeFraction, 0)
        XCTAssertEqual(slice.visible(isGuidancePaused: false).edges.map(\.id), ["two"])
        XCTAssertEqual(slice.visible(isGuidancePaused: false).initialEdgeFraction, 0.4)
        XCTAssertEqual(path.map(\.id), ["one", "two"])
    }

    func testPausedGuidanceRemovesLocalProjectionButPreservesPartner() {
        let local = UUID()
        let partner = UUID()
        let projections = [local: "YOU @ 3PM", partner: "ALEX @ 3PM"]
        XCTAssertEqual(MapGuidancePresentation.visibleProjections(
            projections, localGuidancePaused: true, partnerID: partner
        ), [partner: "ALEX @ 3PM"])
        XCTAssertEqual(MapGuidancePresentation.visibleProjections(
            projections, localGuidancePaused: false, partnerID: partner
        ), projections)
        XCTAssertTrue(MapGuidancePresentation.visibleProjections(
            projections, localGuidancePaused: true, partnerID: nil
        ).isEmpty)
    }

    func testRouteAnimationDoesNotReplayForCompletedPrefixRemoval() {
        XCTAssertFalse(MapRouteAnimationPolicy.shouldReplay(
            previousA: ["one", "two", "three"],
            previousB: ["friend"],
            nextA: ["two", "three"],
            nextB: ["friend"],
            forced: false
        ))
        XCTAssertFalse(MapRouteAnimationPolicy.shouldReplay(
            previousA: ["three"],
            previousB: ["friend"],
            nextA: [],
            nextB: ["friend"],
            forced: false
        ))
        XCTAssertTrue(MapRouteAnimationPolicy.shouldReplay(
            previousA: ["one", "two", "three"],
            previousB: ["friend"],
            nextA: ["detour", "three"],
            nextB: ["friend"],
            forced: false
        ))
        XCTAssertTrue(MapRouteAnimationPolicy.shouldReplay(
            previousA: ["one", "two"],
            previousB: ["friend"],
            nextA: ["two"],
            nextB: ["friend"],
            forced: true
        ))
    }

    func testActiveRouteSettlesToSolidLineWithoutPerpetualMotion() {
        XCTAssertEqual(ActiveRouteLineStyle.dashArray, [1, 0])
    }

    func testExplicitRoutePreviewFramesOnlyCurrentResortGeometry() {
        func edge(
            _ id: String,
            _ coordinates: [CLLocationCoordinate2D]
        ) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: "\(id)-source",
                targetID: "\(id)-target",
                kind: .run,
                geometry: coordinates,
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 100,
                    isOpen: true
                )
            )
        }
        let valid = [
            CLLocationCoordinate2D(latitude: 50.05, longitude: -122.95),
            CLLocationCoordinate2D(latitude: 50.06, longitude: -122.94),
            CLLocationCoordinate2D(latitude: 50.07, longitude: -122.93),
        ]
        let stale = [
            CLLocationCoordinate2D(latitude: 39.60, longitude: -106.35),
            CLLocationCoordinate2D(latitude: 39.61, longitude: -106.34),
        ]
        let meeting = GraphNode(
            id: "meeting",
            coordinate: valid.last!,
            elevation: 1_800,
            kind: .liftBase
        )

        let framed = ExplicitRoutePreviewFraming.coordinates(
            routes: [[edge("valid", valid)], [edge("stale", stale)]],
            graph: nil,
            meetingNode: meeting,
            resortBounds: BoundingBox(
                minLat: 50.0,
                maxLat: 50.1,
                minLon: -123.0,
                maxLon: -122.9
            ),
            maximumCount: 2
        )

        XCTAssertEqual(framed.count, 2)
        XCTAssertEqual(framed.first?.latitude, valid.first?.latitude)
        XCTAssertEqual(framed.last?.latitude, valid.last?.latitude)
        XCTAssertTrue(framed.allSatisfy { $0.latitude > 49 })
    }

    @MainActor
    func testFriendAccuracyChangeTriggersHaloRebuild() {
        let id = UUID()
        let captured = Date(timeIntervalSinceReferenceDate: 100)
        func location(accuracy: Double) -> RealtimeLocationService.FriendLocation {
            RealtimeLocationService.FriendLocation(
                userId: id,
                displayName: "Friend",
                resortId: "whistler",
                latitude: 50.1,
                longitude: -122.9,
                capturedAt: captured,
                nearestNodeId: nil,
                accuracyMeters: accuracy
            )
        }
        let now = captured.addingTimeInterval(10)
        let precise = MapFriendLayerState.FriendLocationKey(
            location(accuracy: 8),
            now: now
        )
        let loose = MapFriendLayerState.FriendLocationKey(
            location(accuracy: 80),
            now: now
        )

        XCTAssertNotEqual(precise, loose)
    }

    func testOverviewLandmarksAreElevationOrderedSeparatedAndStable() {
        func node(_ id: String, elevation: Double, longitude: Double) -> GraphNode {
            GraphNode(
                id: id,
                coordinate: .init(latitude: 50, longitude: longitude),
                elevation: elevation,
                kind: .junction
            )
        }
        let highest = node("highest", elevation: 2_400, longitude: -122.95)
        let nearby = node("nearby", elevation: 2_390, longitude: -122.951)
        let secondMountain = node("second", elevation: 2_300, longitude: -122.92)
        let thirdMountain = node("third", elevation: 2_200, longitude: -122.89)
        let input = [thirdMountain, nearby, secondMountain, highest]

        let selected = GeoJSONBuilder.separatedElevationLandmarks(
            nodes: input,
            descending: true,
            count: 3,
            minimumDistanceMeters: 1_500
        )
        let reversed = GeoJSONBuilder.separatedElevationLandmarks(
            nodes: Array(input.reversed()),
            descending: true,
            count: 3,
            minimumDistanceMeters: 1_500
        )

        XCTAssertEqual(selected.map(\.id), ["highest", "second", "third"])
        XCTAssertEqual(reversed.map(\.id), selected.map(\.id))
    }

    // MARK: - MapTrailLayerState

    func testTrailStateEqualOnSameInputs() {
        let a = MapTrailLayerState(graphFingerprint: "abc", showDebugLayers: false)
        let b = MapTrailLayerState(graphFingerprint: "abc", showDebugLayers: false)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testTrailStateDifferentOnFingerprintChange() {
        let a = MapTrailLayerState(graphFingerprint: "abc", showDebugLayers: false)
        let b = MapTrailLayerState(graphFingerprint: "def", showDebugLayers: false)
        XCTAssertNotEqual(a, b)
    }

    func testTrailStateDifferentOnDebugFlag() {
        // Toggling debug layers must trigger rebuild even on the same graph.
        let a = MapTrailLayerState(graphFingerprint: "abc", showDebugLayers: false)
        let b = MapTrailLayerState(graphFingerprint: "abc", showDebugLayers: true)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - MapRouteLayerState.MeetingNodeKey

    func testMeetingNodeKeySameIdSameCoordIsEqual() {
        let n = GraphNode(
            id: "n1",
            coordinate: .init(latitude: 39.6, longitude: -106.36),
            elevation: 2500,
            kind: .junction
        )
        let a = MapRouteLayerState.MeetingNodeKey(n)
        let b = MapRouteLayerState.MeetingNodeKey(n)
        XCTAssertEqual(a, b)
    }

    func testMeetingNodeKeyMeaningfulMoveIsNotEqual() {
        let n1 = GraphNode(id: "n1",
                           coordinate: .init(latitude: 39.6, longitude: -106.36),
                           elevation: 2500, kind: .junction)
        let n2 = GraphNode(id: "n1",
                           coordinate: .init(latitude: 39.61, longitude: -106.36),
                           elevation: 2500, kind: .junction)
        let a = MapRouteLayerState.MeetingNodeKey(n1)
        let b = MapRouteLayerState.MeetingNodeKey(n2)
        XCTAssertNotEqual(a, b)
    }

    func testMeetingNodeKeyLandmarkCopyOrKindChangeTriggersRebuild() {
        let node = GraphNode(
            id: "n1",
            coordinate: .init(latitude: 39.6, longitude: -106.36),
            elevation: 2_500,
            kind: .liftBase
        )
        let base = MapRouteLayerState.MeetingNodeKey(
            node,
            displayName: "Peak Chair Base",
            rendezvousKind: .liftBase
        )
        let renamed = MapRouteLayerState.MeetingNodeKey(
            node,
            displayName: "Peak Express Base",
            rendezvousKind: .liftBase
        )
        let lodge = MapRouteLayerState.MeetingNodeKey(
            node,
            displayName: "Peak Chair Base",
            rendezvousKind: .lodge
        )
        let destination = MapRouteLayerState.MeetingNodeKey(
            node,
            displayName: "Peak Chair Base",
            rendezvousKind: .liftBase,
            markerVerb: "GO"
        )

        XCTAssertNotEqual(base, renamed)
        XCTAssertNotEqual(base, lodge)
        XCTAssertNotEqual(base, destination)
    }

    // MARK: - MapRouteLayerState

    func testRouteStateEqualOnIdenticalRoutes() {
        let a = MapRouteLayerState(routeAEdgeIds: ["e1", "e2"], routeBEdgeIds: ["e3"], meetingNode: nil)
        let b = MapRouteLayerState(routeAEdgeIds: ["e1", "e2"], routeBEdgeIds: ["e3"], meetingNode: nil)
        XCTAssertEqual(a, b)
    }

    func testRouteStateEdgeReorderTriggersRebuild() {
        // Edge order matters — a reverse-order route should rebuild.
        let a = MapRouteLayerState(routeAEdgeIds: ["e1", "e2"], routeBEdgeIds: [], meetingNode: nil)
        let b = MapRouteLayerState(routeAEdgeIds: ["e2", "e1"], routeBEdgeIds: [], meetingNode: nil)
        XCTAssertNotEqual(a, b)
    }
}
