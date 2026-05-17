//
//  MapLayerState.swift
//  PowderMeet
//
//  Hashable state structs that drive the diffs in
//  `MountainMapView.Coordinator.updateDataLayers`. Replaces the old
//  ad-hoc `lastGraphFingerprint` + `lastFriendLocationsHash` +
//  `lastRouteAHash` + … fields. The wins:
//
//  1. **Compiler-enforced field membership.** Adding a new field to
//     a state struct forces the diff site to acknowledge it. Before,
//     a hand-rolled `friendLocationsHash` could silently drop a new
//     property (the `signalQualities → friend dot rendering` example
//     in the audit log was exactly that bug — `signalQualities`
//     wasn't part of the hash, so live/stale/cold styling didn't
//     re-render until something else triggered a refresh). The
//     `MapFriendLayerState` below now includes `signalQualities` and
//     the 60s `clock`; auto-`Hashable` keeps them in the comparison.
//
//  2. **No more `Hasher.combine(...)` walks at every diff.**
//     `==` on the struct is the diff. The struct itself can be
//     stored as the previous-frame snapshot.
//
//  3. **Granular sub-source rebuilds preserved.** `MapRouteLayerState`
//     covers route A + route B + the meeting node, but the consumer
//     in `updateDataLayers` still compares each sub-field against the
//     previous snapshot before rebuilding the corresponding GeoJSON
//     source — so a route-A-only change doesn't pay route-B's
//     GeoJSON cost.
//
//

import Foundation
import CoreLocation

// MARK: - Trail layer

/// Drives the TRAIL / LIFT / TRAVERSE / POI / DEAD-END / PHANTOM /
/// LIFT-ENDPOINT / TEMPERATURE GeoJSON sources — every layer that's
/// keyed off graph topology. The original gating combined a graph
/// fingerprint with the debug-layers toggle; this struct keeps both
/// behind one `==`.
struct MapTrailLayerState: Hashable {
    /// `MountainGraph.fingerprint` is precomputed at load/mutation
    /// time so reading it is O(1) even at Whistler's ~8k edges.
    var graphFingerprint: String?
    var showDebugLayers: Bool
}

// MARK: - Friend layer

/// Drives the friend-dots layer. The original `friendLocationsHash`
/// only covered (latitude, longitude, capturedAt, nearestNodeId,
/// displayName, visibleOnMap, mapFriendLayerClock, signalQuality)
/// — close to this set, but adding a field meant remembering to
/// extend the hash. This struct makes that automatic.
struct MapFriendLayerState: Hashable {
    var locations: [UUID: FriendLocationKey]
    var signalQualities: [UUID: FriendSignalQuality]
    /// Bumped every 60s on the Map tab so the friend dot layer
    /// re-renders for the 3h visibility cutoff and age pills without
    /// waiting for a new peer location update.
    var clock: Int

    /// Per-friend snapshot used as the dictionary value. Coordinates
    /// are bucketed to ~1.1 m (1e6 quantisation) so sub-meter GPS
    /// jitter doesn't thrash the diff.
    struct FriendLocationKey: Hashable {
        var latMicro: Int
        var lonMicro: Int
        var capturedAtSeconds: Double
        var nearestNodeId: String?
        var displayName: String?
        /// `FriendSignalClassifier.isVisibleOnMap(lastSeen:now:)`
        /// computed at struct-construction time. Bundled in here so
        /// when `now` advances past the 3h cutoff, the diff fires
        /// and the dot disappears.
        var visibleOnMap: Bool
    }
}

extension MapFriendLayerState.FriendLocationKey {
    nonisolated init(_ loc: RealtimeLocationService.FriendLocation, now: Date) {
        self.latMicro = Int(loc.latitude * 1_000_000)
        self.lonMicro = Int(loc.longitude * 1_000_000)
        self.capturedAtSeconds = loc.capturedAt.timeIntervalSince1970
        self.nearestNodeId = loc.nearestNodeId
        self.displayName = loc.displayName
        self.visibleOnMap = FriendSignalClassifier.isVisibleOnMap(lastSeen: loc.capturedAt, now: now)
    }
}

// MARK: - Route layer

/// Drives the ROUTE A / ROUTE B / MEETING POINT / MEETING BEAM
/// sources. Stored as a single struct so the compiler enforces
/// "if you add a route field, decide whether it triggers a refresh,"
/// but the consumer in `updateDataLayers` still compares per-field
/// to keep the rebuilds granular.
struct MapRouteLayerState: Hashable {
    var routeAEdgeIds: [String]
    var routeBEdgeIds: [String]
    var meetingNode: MeetingNodeKey?

    struct MeetingNodeKey: Hashable {
        var id: String
        /// Coordinate quantised to ~1.1 m so `==` only fires on real moves.
        var latMicro: Int
        var lonMicro: Int
    }

    static let empty = MapRouteLayerState(
        routeAEdgeIds: [],
        routeBEdgeIds: [],
        meetingNode: nil
    )
}

extension MapRouteLayerState.MeetingNodeKey {
    nonisolated init(_ node: GraphNode) {
        self.id = node.id
        self.latMicro = Int(node.coordinate.latitude * 1_000_000)
        self.lonMicro = Int(node.coordinate.longitude * 1_000_000)
    }
}
