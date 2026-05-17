//
//  RouteProgressTracker.swift
//  PowderMeet
//
//  Tracks the user's real-time GPS position along their solved route path.
//  Detects edge completion (arrival at edge target node), skip-ahead
//  (shortcut), and route deviation (off-route). Drives the auto-advancing
//  EdgeInfoCard and progress bar in the CompactRouteSummary.
//

import Foundation
import CoreLocation
import Observation

// MARK: - Route Events

enum RouteEvent {
    case advanced(GraphEdge)          // moved to next edge
    case skippedAhead(Int)            // jumped ahead N edges (shortcut)
    case completed                    // arrived at meeting point
    case deviated(currentNodeId: String)  // went off-route
}

// MARK: - Route Progress Tracker

@MainActor @Observable
final class RouteProgressTracker {
    let path: [GraphEdge]
    let graph: MountainGraph
    let meetingNodeId: String?

    private(set) var currentEdgeIndex: Int = 0
    private(set) var isOffRoute: Bool = false
    private(set) var isComplete: Bool = false
    private(set) var progress: Double = 0.0   // 0.0 – 1.0

    /// Threshold distance (meters) — node is "reached" if GPS is within this radius.
    private let arrivalRadius: CLLocationDistance = 80

    /// Must be this close to the meeting point (meters) before we mark the route
    /// complete. Prevents graph snap / shared hub nodes from firing "arrived"
    /// when the skier has not physically reached the pin.
    private let meetingArrivalMaxDistanceMeters: CLLocationDistance = 110

    /// True when we don't have a route to track (solver failed, stale catalog,
    /// etc). UI uses this to suppress the "arrived" banner — an empty path
    /// used to auto-complete on init, which surfaced as a false positive.
    var hasPath: Bool { !path.isEmpty }

    // MARK: - Deviation debouncing (Phase 4.7)
    //
    // A single off-route GPS fix used to instantly fire `.deviated`, which
    // made spurious stitches from urban canyons / tree cover register as
    // real deviations and triggered re-solve spam. We now require the
    // deviation to persist for at least 20s AND move the user > 150m from
    // the route before we signal.
    //
    // Sticky-clear: once the deviation timer has started, a single on-route
    // GPS fix won't cancel it — we require `stickyOnRouteRequired` consecutive
    // on-route fixes before clearing. Prevents a lone reflected fix inside
    // a tree well from flapping the deviation state.
    private var deviationStartTime: Date?
    private var consecutiveOnRouteFixes: Int = 0
    private let deviationPersistenceSeconds: TimeInterval = 20
    private let deviationDistanceMeters: Double = 150
    private let stickyOnRouteRequired: Int = 3

    // MARK: - Cached node lookups
    //
    // `update(location:)` runs per GPS fix (1 Hz active, faster during a
    // meetup). Each call needs the source + target node coords for the
    // current edge — three separate `graph.nodes[...]` dictionary lookups
    // every fix. These only change when `currentEdgeIndex` advances, so
    // resolve once per advance and reuse.
    private var cachedSourceNode: GraphNode?
    private var cachedTargetNode: GraphNode?
    private var cachedNodesForIndex: Int = -1

    private func resolvedNodes() -> (source: GraphNode?, target: GraphNode?) {
        if cachedNodesForIndex != currentEdgeIndex {
            cachedNodesForIndex = currentEdgeIndex
            if let edge = currentEdge {
                cachedSourceNode = graph.nodes[edge.sourceID]
                cachedTargetNode = graph.nodes[edge.targetID]
            } else {
                cachedSourceNode = nil
                cachedTargetNode = nil
            }
        }
        return (cachedSourceNode, cachedTargetNode)
    }

    // MARK: - Computed

    var currentEdge: GraphEdge? {
        guard currentEdgeIndex < path.count else { return nil }
        return path[currentEdgeIndex]
    }

    var nextEdge: GraphEdge? {
        let next = currentEdgeIndex + 1
        guard next < path.count else { return nil }
        return path[next]
    }

    var remainingEdges: Int {
        max(0, path.count - currentEdgeIndex)
    }

    var completedEdges: Int {
        min(currentEdgeIndex, path.count)
    }

    /// Distance-along-route progress (stable bar; matches remaining meters).
    private func recalculateProgress() {
        // Empty path isn't "100% complete" — it's "nothing to track".
        // Forcing 1.0 here would paint the progress bar full even before
        // the user starts moving, matching the old auto-complete bug.
        guard !path.isEmpty else { progress = 0.0; return }
        let total = path.reduce(0.0) { $0 + $1.attributes.lengthMeters }
        guard total > 0 else {
            progress = Double(completedEdges) / Double(path.count)
            return
        }
        let remaining = path[currentEdgeIndex...].reduce(0.0) { $0 + $1.attributes.lengthMeters }
        progress = max(0, min(1, 1.0 - remaining / total))
    }

    private func isPhysicallyNearMeeting(_ location: CLLocationCoordinate2D) -> Bool {
        let meetingId = path.last?.targetID ?? meetingNodeId
        guard let meetingId, let node = graph.nodes[meetingId] else { return false }
        let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let m = CLLocation(
            latitude: node.coordinate.latitude,
            longitude: node.coordinate.longitude
        )
        return loc.distance(from: m) <= meetingArrivalMaxDistanceMeters
    }

    // MARK: - Init

    init(path: [GraphEdge], graph: MountainGraph, meetingNodeId: String? = nil) {
        self.path = path
        self.graph = graph
        self.meetingNodeId = meetingNodeId ?? path.last?.targetID
        // Empty path used to auto-complete here; that produced a false
        // "ARRIVED" the instant a meetup activated without a solved route.
        // Completion now only fires through `update(location:)` when the
        // skier is physically close to the meeting pin.
    }

    // MARK: - Update

    /// Call with the user's latest GPS coordinate. Returns a RouteEvent if
    /// the state changed (advanced, completed, deviated), or nil if no change.
    @discardableResult
    func update(location: CLLocationCoordinate2D) -> RouteEvent? {
        guard !isComplete else { return nil }

        // No solved path for this leg — still fire `.completed` when the
        // skier physically reaches the agreed meeting pin, so the arrival
        // celebration isn't lost if the solver never produced edges.
        if path.isEmpty {
            if isPhysicallyNearMeeting(location) {
                isComplete = true
                progress = 1.0
                return .completed
            }
            return nil
        }

        let snapped = graph.nearestNode(to: location)
        guard let snappedNode = snapped else { return nil }

        let snappedId = snappedNode.id

        // ── 1. Check if we've arrived at the current edge's target ──
        if let current = currentEdge, snappedId == current.targetID {
            // Require physical proximity. Snapping to a node whose coordinate
            // is hundreds of metres from the user's actual fix should NOT
            // count as arrival — that happens at shared hub nodes when
            // `nearestNode` returns a topologically-close-but-physically-
            // distant match. Skip-ahead (block 2 below) already has this
            // guard; mirror it here so primary advancement is just as safe.
            if let target = resolvedNodes().target {
                let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                let tl  = CLLocation(latitude: target.coordinate.latitude,
                                     longitude: target.coordinate.longitude)
                if loc.distance(from: tl) > arrivalRadius * 2 {
                    // Topological match but physically far — don't advance.
                    // Fall through to off-route / deviation handling below.
                } else {
                    let willComplete = currentEdgeIndex + 1 >= path.count
                    if willComplete, !isPhysicallyNearMeeting(location) {
                        isOffRoute = false
                        deviationStartTime = nil
                        return nil
                    }
                    currentEdgeIndex += 1
                    isOffRoute = false
                    deviationStartTime = nil
                    recalculateProgress()

                    if currentEdgeIndex >= path.count {
                        isComplete = true
                        progress = 1.0
                        return .completed
                    }
                    return .advanced(path[currentEdgeIndex])
                }
            }
        }

        // ── 2. Check if we've skipped ahead (shortcut / took a faster route) ──
        for i in (currentEdgeIndex + 1)..<path.count {
            if snappedId == path[i].targetID {
                // Require physical proximity to the claimed skip target.
                // Without this, a spurious far-field snap (e.g., shared
                // hub node for a disjoint lift) can leap the index forward
                // even though the user is still back at the current edge.
                if let skipTarget = graph.nodes[path[i].targetID] {
                    let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                    let sl = CLLocation(
                        latitude: skipTarget.coordinate.latitude,
                        longitude: skipTarget.coordinate.longitude
                    )
                    if loc.distance(from: sl) > arrivalRadius * 2 { continue }
                }
                let newIndex = i + 1
                if newIndex >= path.count, !isPhysicallyNearMeeting(location) {
                    continue
                }
                let skipped = i - currentEdgeIndex
                currentEdgeIndex = newIndex
                isOffRoute = false
                recalculateProgress()

                if currentEdgeIndex >= path.count {
                    isComplete = true
                    progress = 1.0
                    return .completed
                }
                return .skippedAhead(skipped)
            }
        }

        // Sticky-clear helper: on-route fixes accumulate a counter; we only
        // clear the deviation timer once it hits `stickyOnRouteRequired`
        // consecutive hits. A stray on-route snap between two clearly-off
        // fixes therefore doesn't reset the 20s persistence timer.
        func registerOnRouteFix() {
            consecutiveOnRouteFixes += 1
            if consecutiveOnRouteFixes >= stickyOnRouteRequired {
                deviationStartTime = nil
            }
            isOffRoute = false
        }

        // ── 3. Check if still on-route (at source of current or any future edge) ──
        let onRouteNodeIds = Set(
            path[currentEdgeIndex...].flatMap { [$0.sourceID, $0.targetID] }
        )
        if onRouteNodeIds.contains(snappedId) {
            registerOnRouteFix()
            return nil
        }

        // ── 4. Check proximity to route geometry (GPS might be between nodes) ──
        if let targetNode = resolvedNodes().target {
            let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let targetLoc = CLLocation(
                latitude: targetNode.coordinate.latitude,
                longitude: targetNode.coordinate.longitude
            )
            if loc.distance(from: targetLoc) < arrivalRadius * 3 {
                registerOnRouteFix()
                return nil
            }
        }

        // Below this point the fix is off-route — reset the consecutive
        // on-route counter so a future recovery must rebuild the streak.
        consecutiveOnRouteFixes = 0

        // ── 5. Off route — debounce. Start a deviation timer; only emit the
        // `.deviated` event once it's persisted long enough and far enough.
        let now = Date()
        if deviationStartTime == nil {
            deviationStartTime = now
        }
        let elapsed = now.timeIntervalSince(deviationStartTime ?? now)

        // Distance from the current edge's source/target — a crude proxy for
        // distance to the polyline, good enough for the gate.
        let distance: Double = {
            let (src, dst) = resolvedNodes()
            guard let src, let dst else { return .infinity }
            let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let srcLoc = CLLocation(latitude: src.coordinate.latitude, longitude: src.coordinate.longitude)
            let dstLoc = CLLocation(latitude: dst.coordinate.latitude, longitude: dst.coordinate.longitude)
            return min(loc.distance(from: srcLoc), loc.distance(from: dstLoc))
        }()

        let persistedLongEnough = elapsed >= deviationPersistenceSeconds
        let farEnough = distance >= deviationDistanceMeters

        if !isOffRoute, persistedLongEnough, farEnough {
            isOffRoute = true
            return .deviated(currentNodeId: snappedId)
        }

        // Already flagged as off-route, don't re-trigger
        return nil
    }

    // MARK: - Reset (after reroute)

    /// Replaces the current tracking with a new path (after reroute).
    /// Returns a new tracker since path is let.
    static func rerouted(
        newPath: [GraphEdge],
        graph: MountainGraph,
        meetingNodeId: String? = nil
    ) -> RouteProgressTracker {
        RouteProgressTracker(path: newPath, graph: graph, meetingNodeId: meetingNodeId)
    }
}
