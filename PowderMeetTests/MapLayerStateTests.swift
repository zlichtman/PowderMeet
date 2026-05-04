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
@testable import PowderMeet

final class MapLayerStateTests: XCTestCase {

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
