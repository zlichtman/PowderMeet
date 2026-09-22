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

// MARK: - Live route presentation

/// The map is an instruction surface during an active meetup, not a historical
/// breadcrumb. Keep only the unfinished local route and clip its first edge to
/// the tracker's monotonic projected progress. The accepted result still keeps
/// the full immutable path for validation, replay, and analytics.
nonisolated struct ActiveMapRouteSlice: Sendable {
    let edges: [GraphEdge]
    let initialEdgeFraction: Double

    func visible(isGuidancePaused: Bool) -> ActiveMapRouteSlice {
        isGuidancePaused ? ActiveMapRouteSlice(edges: [], initialEdgeFraction: 0) : self
    }

    static func remaining(
        path: [GraphEdge],
        currentEdgeIndex: Int,
        currentEdgeFraction: Double
    ) -> ActiveMapRouteSlice {
        let index = min(max(0, currentEdgeIndex), path.count)
        guard index < path.count else {
            return ActiveMapRouteSlice(edges: [], initialEdgeFraction: 0)
        }
        return ActiveMapRouteSlice(
            edges: Array(path.dropFirst(index)),
            initialEdgeFraction: max(0, min(1, currentEdgeFraction))
        )
    }
}

nonisolated enum MapGuidancePresentation {
    /// Future-position ghosts imply the accepted route remains usable. Keep
    /// only the independently represented partner when local guidance pauses.
    static func visibleProjections<Value>(
        _ positions: [UUID: Value], localGuidancePaused: Bool, partnerID: UUID?
    ) -> [UUID: Value] {
        guard localGuidancePaused else { return positions }
        guard let partnerID, let partner = positions[partnerID] else { return [:] }
        return [partnerID: partner]
    }
}

/// Route reveals are for a new plan. Removing a completed prefix is routine
/// live progress and must not repeatedly redraw/chase the entire suffix.
nonisolated enum MapRouteAnimationPolicy {
    static func shouldReplay(
        previousA: [String],
        previousB: [String],
        nextA: [String],
        nextB: [String],
        forced: Bool
    ) -> Bool {
        if forced { return !nextA.isEmpty || !nextB.isEmpty }
        let changedA = previousA != nextA
        let changedB = previousB != nextB
        guard changedA || changedB else { return false }
        guard !nextA.isEmpty || !nextB.isEmpty else { return false }

        func isCompletedPrefixRemoval(
            previous: [String],
            next: [String]
        ) -> Bool {
            guard next.count < previous.count else { return false }
            if next.isEmpty { return !previous.isEmpty }
            return Array(previous.suffix(next.count)) == next
        }

        let aIsProgress = !changedA || isCompletedPrefixRemoval(
            previous: previousA,
            next: nextA
        )
        let bIsProgress = !changedB || isCompletedPrefixRemoval(
            previous: previousB,
            next: nextB
        )
        return !(aIsProgress && bIsProgress)
    }
}

/// Stable route styling after the finite reveal. Direction comes from the
/// ordered maneuver HUD and live corridor trimming, not perpetual map motion.
nonisolated enum ActiveRouteLineStyle {
    static let dashArray: [Double] = [1, 0]
}

/// Camera input for an explicit "Show Route on Map" action. Geometry is
/// filtered against the selected resort before it reaches Mapbox, so a stale
/// route from a prior resort cannot reproduce the old middle-of-nowhere jump.
/// Automatic meet acceptance never calls this policy.
nonisolated enum ExplicitRoutePreviewFraming {
    static func coordinates(
        routes: [[GraphEdge]],
        graph: MountainGraph?,
        meetingNode: GraphNode?,
        resortBounds: BoundingBox,
        maximumCount: Int = 64
    ) -> [CLLocationCoordinate2D] {
        let latPadding = max(0.002, (resortBounds.maxLat - resortBounds.minLat) * 0.15)
        let lonPadding = max(0.002, (resortBounds.maxLon - resortBounds.minLon) * 0.15)
        func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
            coordinate.latitude.isFinite
                && coordinate.longitude.isFinite
                && (-90...90).contains(coordinate.latitude)
                && (-180...180).contains(coordinate.longitude)
                && coordinate.latitude >= resortBounds.minLat - latPadding
                && coordinate.latitude <= resortBounds.maxLat + latPadding
                && coordinate.longitude >= resortBounds.minLon - lonPadding
                && coordinate.longitude <= resortBounds.maxLon + lonPadding
        }

        var seen: Set<String> = []
        var collected: [CLLocationCoordinate2D] = []
        func append(_ coordinate: CLLocationCoordinate2D) {
            guard isValid(coordinate) else { return }
            let key = "\(Int((coordinate.latitude * 10_000_000).rounded())):\(Int((coordinate.longitude * 10_000_000).rounded()))"
            if seen.insert(key).inserted { collected.append(coordinate) }
        }

        for route in routes {
            for edge in route {
                if edge.geometry.count >= 2 {
                    edge.geometry.forEach(append)
                } else if let graph {
                    if let source = graph.nodes[edge.sourceID] { append(source.coordinate) }
                    if let target = graph.nodes[edge.targetID] { append(target.coordinate) }
                }
            }
        }
        if let meetingNode { append(meetingNode.coordinate) }

        let limit = max(2, maximumCount)
        guard collected.count > limit else { return collected }
        let step = Double(collected.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            collected[Int((Double(index) * step).rounded())]
        }
    }
}

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
        /// Whole-metre accuracy is enough for halo diffing. Omitting this made
        /// an improving/worsening halo stay frozen until another field changed.
        var accuracyMetersRounded: Int
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
        self.accuracyMetersRounded = loc.accuracyMeters.map {
            $0.isFinite && $0 >= 0 ? Int($0.rounded()) : -1
        } ?? -1
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
    var routeAInitialPermille: Int = 0
    var routeBInitialPermille: Int = 0
    var meetingNode: MeetingNodeKey?

    struct MeetingNodeKey: Hashable {
        var id: String
        /// Coordinate quantised to ~1.1 m so `==` only fires on real moves.
        var latMicro: Int
        var lonMicro: Int
        var displayName: String?
        var rendezvousKind: RendezvousPoint.Kind?
        var markerVerb: String
    }

    static let empty = MapRouteLayerState(
        routeAEdgeIds: [],
        routeBEdgeIds: [],
        routeAInitialPermille: 0,
        routeBInitialPermille: 0,
        meetingNode: nil
    )
}

extension MapRouteLayerState.MeetingNodeKey {
    nonisolated init(
        _ node: GraphNode,
        displayName: String? = nil,
        rendezvousKind: RendezvousPoint.Kind? = nil,
        markerVerb: String = "MEET"
    ) {
        self.id = node.id
        self.latMicro = Int(node.coordinate.latitude * 1_000_000)
        self.lonMicro = Int(node.coordinate.longitude * 1_000_000)
        self.displayName = displayName
        self.rendezvousKind = rendezvousKind
        self.markerVerb = markerVerb
    }
}
