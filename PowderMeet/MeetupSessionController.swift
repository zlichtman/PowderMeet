//
//  MeetupSessionController.swift
//  PowderMeet
//
//  Owns the meetup-session lifecycle that used to live as ~400 lines
//  of methods on `ContentCoordinator`: activate-route (sender/receiver/
//  shared), reroute, end, and the navigation-layer service ensemble
//  (NavigationDirector, NavigationViewModel, RouteChoreographer,
//  BlendedETAEstimator). The audit's §11.2 narrowing target.
//
//  Boundary: this controller MUTATES SwiftUI-bound @Observable state on
//  the parent `ContentCoordinator` (`meetingResult`, `activeMeetSession`,
//  `routeAnimationTrigger`, `transientMessage`) via a weak back-reference.
//  Moving those properties off the coordinator would force a parallel
//  rewrite of every ContentView read site — out of scope for this pass.
//  The controller's own @Observable surface is the four navigation
//  services it owns, so `coordinator.navigationViewModel` (forwarded
//  via a pass-through computed property) still drives SwiftUI invalidation
//  through this layer.
//
//  Threading: `@MainActor` to match every collaborator. Heavy compute
//  (Dijkstra) runs through `MeetingPointSolver` which is already
//  `nonisolated`; this controller is purely a sequencer.
//

import Foundation
import CoreLocation
import Observation
import SwiftUI

@MainActor
@Observable
final class MeetupSessionController {

    // MARK: - Owned navigation services

    /// Built up while a meetup session is active and torn back down
    /// when it ends. Driven by `syncNavigationServices()` from both
    /// the `onChange(of: activeMeetSession?.id)` watcher in ContentView
    /// and from `reroute()` (since reroute keeps the session id stable
    /// and the watcher wouldn't fire).
    private(set) var navigationDirector: NavigationDirector?
    private(set) var navigationViewModel: NavigationViewModel?
    private(set) var routeChoreographer: RouteChoreographer?
    private(set) var etaEstimator: BlendedETAEstimator?

    // MARK: - Back-reference

    /// Weak so the controller can't keep the coordinator alive past
    /// teardown. Set immediately after construction in
    /// `ContentCoordinator.init` — methods short-circuit if it's nil
    /// (which only happens after explicit teardown).
    @ObservationIgnored weak var coordinator: ContentCoordinator?

    init() {}

    // MARK: - Solver / node resolution

    /// Configures a solver with current environmental conditions. The
    /// only consumer outside the activate/reroute paths is the receiver
    /// fallback chain — anywhere else, prefer `MeetSolver.solve(...)`
    /// which already applies these defaults.
    func configureSolver(graph: MountainGraph) -> MeetingPointSolver {
        let solver = MeetingPointSolver(graph: graph)
        solver.solveTime = Date.now
        if let entry = coordinator?.resortManager.currentEntry {
            solver.resortLatitude = (entry.bounds.minLat + entry.bounds.maxLat) / 2
            solver.resortLongitude = (entry.bounds.minLon + entry.bounds.maxLon) / 2
        }
        if let conditions = coordinator?.resortConditions {
            solver.temperatureC = conditions.temperatureC
            solver.windSpeedKmh = conditions.windSpeedKph
            solver.freshSnowCm = conditions.snowfallLast24hCm
            solver.visibilityKm = conditions.visibilityKm
            solver.cloudCoverPercent = conditions.cloudCoverPercent
            solver.stationElevationM = conditions.stationElevationM
        }
        // Phase 2 — let the solver use the local user's per-edge speed
        // history when computing traversal times. Empty if I haven't
        // imported anything yet; falls through to bucketed-difficulty
        // speeds identically.
        solver.edgeSpeedHistory = SupabaseManager.shared.currentEdgeSpeeds
        return solver
    }

    /// Resolves a node ID for the current user. Priority:
    ///  1. Live GPS sticky node (user is at this resort)
    ///  2. Fresh GPS nearestNode (also gated to resort by 1000m cap inside)
    ///  3. Tester-picked node (debug/TestFlight manual placement)
    ///  4. nil — user is not at this resort and no manual placement set
    ///
    /// Live location always wins over the tester pick.
    func resolveMyNodeId(graph: MountainGraph) -> String? {
        guard let coord = coordinator else { return nil }
        if let sticky = coord.locationManager.gpsStickyGraphNodeId, graph.nodes[sticky] != nil {
            return sticky
        }
        if let loc = coord.locationManager.currentLocation,
           let node = graph.nearestNode(to: loc) { return node.id }
        if let testId = coord.testMyNodeId, graph.nodes[testId] != nil { return testId }
        return nil
    }

    // MARK: - Navigation services lifecycle

    /// Bring up or tear down the navigation-layer services when the
    /// active meetup session transitions. Called from
    /// `onChange(of: activeMeetSession?.id)` so both the accept and
    /// cancel paths trigger the same sync, and explicitly from
    /// `reroute()` because reroute keeps `session.id` constant.
    func syncNavigationServices() {
        guard let coord = coordinator else { return }
        // Tracker is nil while a reroute is mid-rebuild — tearing services
        // down here would drop NavigationDirector just long enough for the
        // `.advanced`/`.deviated` pipeline to miss fixes, then come back
        // up stale. If the session is still active, just hold the existing
        // services; the follow-up tracker-identity onChange will re-run
        // us once the new tracker is attached.
        if coord.activeMeetSession != nil, coord.activeMeetSession?.routeTracker == nil {
            return
        }
        if let session = coord.activeMeetSession,
           let tracker = session.routeTracker,
           let graph = coord.resortManager.currentGraph,
           let myProfile = SupabaseManager.shared.currentUserProfile {
            navigationViewModel = NavigationViewModel(tracker: tracker, profile: myProfile, graph: graph)

            // NavigationDirector — CinemaDirector conforms to CameraController
            // so deviation refit now works when the bridge is populated.
            navigationDirector = NavigationDirector(
                tracker: tracker,
                graph: graph,
                camera: coord.mapBridge.cinemaDirector,
                haptics: HapticService.shared
            )

            // RouteChoreographer — arrival celebration only. Route reveal
            // (camera framing + line-trim animation) is owned by
            // MountainMapView; the prior showRoutes timeline was unused.
            let bridge = coord.mapBridge
            routeChoreographer = RouteChoreographer(.init(
                haptics: HapticService.shared,
                audio: AudioService.shared,
                meetingBloom: { bridge.triggerArrivalBloom?() }
            ))

            let estimator = BlendedETAEstimator()
            let priorSeconds = session.meetingResult.timeA
            let totalRemaining = tracker.path.reduce(0.0) { $0 + $1.attributes.lengthMeters }
            estimator.reset(solverEstimateSeconds: priorSeconds, remainingMeters: totalRemaining)
            etaEstimator = estimator
        } else {
            routeChoreographer?.cancel()
            navigationDirector = nil
            navigationViewModel = nil
            routeChoreographer = nil
            etaEstimator = nil
        }
    }

    // MARK: - End meetup

    /// Cancel the active meetup in DB so the other user sees it end too,
    /// then clear local session state.
    func endActiveMeetup() {
        guard let coord = coordinator else { return }
        if let sessionId = coord.activeMeetSession?.id {
            Task { try? await coord.meetRequestService.cancelRequest(sessionId) }
        }
        coord.activeMeetSession = nil
        coord.meetingResult = nil
    }

    /// Driven from `MeetRequestService.onMeetupCancelled` — the other user
    /// ended the meetup. Clear our session if the request id matches;
    /// otherwise leave state alone (a different session is in flight).
    func handleMeetupCancelledByOther(requestId: UUID) {
        guard let coord = coordinator,
              coord.activeMeetSession?.id == requestId else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            coord.activeMeetSession = nil
            coord.meetingResult = nil
        }
    }

    // MARK: - Activate route

    /// Activates routing when a sent meet request is accepted. Prefers
    /// the sender's pre-computed result (set on map when request was
    /// sent) to avoid 0s friend ETA caused by unknown friend position.
    func activateRoute(for request: MeetRequest) async {
        guard let coord = coordinator else { return }
        AppLog.meet.debug("activateRoute(sender): request.meetingNodeId=\(request.meetingNodeId), meetingResult?.node=\(coord.meetingResult?.meetingNode.id ?? "nil")")
        if let precomputed = coord.meetingResult, precomputed.meetingNode.id == request.meetingNodeId {
            let friendId = request.receiverId
            let friendProfile: UserProfile = coord.friendService.friends.first { $0.id == friendId }
                ?? {
                    var p = UserProfile.defaultProfile(id: friendId)
                    p.displayName = "Friend"
                    p.onboardingCompleted = true
                    return p
                }()

            let graph = coord.resortManager.currentGraph
            let tracker = graph.map {
                RouteProgressTracker(
                    path: precomputed.pathA,
                    graph: $0,
                    meetingNodeId: request.meetingNodeId
                )
            }
            coord.activeMeetSession = ActiveMeetSession(
                id: request.id,
                friendProfile: friendProfile,
                meetingResult: precomputed,
                meetingNodeId: request.meetingNodeId,
                startedAt: Date.now,
                routeTracker: tracker
            )
            coord.routeAnimationTrigger += 1
            return
        }
        // Fallback: re-compute routes
        await activateRouteShared(for: request, isSender: true)
    }

    func activateRouteAsReceiver(for request: MeetRequest) async {
        await activateRouteShared(for: request, isSender: false)
    }

    private func activateRouteShared(for request: MeetRequest, isSender: Bool) async {
        guard let coord = coordinator else { return }
        // Ensure correct resort is loaded — wait for graph before proceeding
        if coord.resortManager.currentGraph == nil || coord.resortManager.currentEntry?.id != request.resortId {
            if let entry = ResortEntry.catalog.first(where: { $0.id == request.resortId }) {
                coord.selectedEntry = entry
                await coord.resortManager.loadResort(entry)
                // Route through the coordinator on this path too — otherwise
                // a meet-request-driven resort load would bypass the snapshot
                // gate and re-introduce the "accept-everyone" window.
                let rtl = coord.ensureRealtimeLocationService()
                let presence = coord.ensurePresenceCoordinator(using: rtl)
                presence.enter(resortId: entry.id)
                await presence.waitForEnter()
            } else {
                AppLog.meet.debug("activateRoute: unknown resort_id \(request.resortId) — add it to ResortCatalog to load trail data")
            }
        }

        guard let myProfile = SupabaseManager.shared.currentUserProfile,
              let graph = coord.resortManager.currentGraph else {
            AppLog.meet.error("activateRoute failed — no profile or graph (check resort catalog for id \(request.resortId))")
            return
        }

        let friendId = isSender ? request.receiverId : request.senderId
        let friendProfile: UserProfile = coord.friendService.friends.first { $0.id == friendId }
            ?? {
                var p = UserProfile.defaultProfile(id: friendId)
                p.displayName = "Friend"
                p.onboardingCompleted = true
                return p
            }()

        let target = request.meetingNodeId
        let meetingNode = graph.nodes[target]
            ?? GraphNode(id: target, coordinate: .init(latitude: 0, longitude: 0),
                         elevation: request.meetingNodeElevation, kind: .junction)

        let myStoredPathIds = isSender ? request.senderPathEdgeIds : request.receiverPathEdgeIds
        let friendStoredPathIds = isSender ? request.receiverPathEdgeIds : request.senderPathEdgeIds
        let myStoredEta = isSender ? request.senderEtaSeconds : request.receiverEtaSeconds
        let friendStoredEta = isSender ? request.receiverEtaSeconds : request.senderEtaSeconds

        // Lenient reconstruct: returns whatever edges resolve in the
        // current graph rather than nil-on-any-miss. The previous
        // strict version meant a single edge id that didn't survive
        // graph drift kicked the whole flow into the fallback solve,
        // which itself often returned nil and landed the receiver on
        // "ROUTING DATA OUT OF SYNC — PULL TO REFRESH" even though
        // 90% of the path was perfectly resolvable. Returns nil only
        // when ZERO edges match — that's the genuine "wrong graph"
        // signal worth re-solving from.
        func reconstructPath(_ ids: [String]?) -> [GraphEdge]? {
            guard let ids, !ids.isEmpty else { return nil }
            let edges = ids.compactMap { graph.edge(byID: $0) }
            if edges.isEmpty { return nil }
            if edges.count < ids.count {
                AppLog.meet.info("activateRoute: stored path partially reconstructed (\(edges.count)/\(ids.count) edges) — graph drift suspected")
            }
            return edges
        }

        let storedMyPath = reconstructPath(myStoredPathIds)
        let storedFriendPath = reconstructPath(friendStoredPathIds)

        let myPath: [GraphEdge]
        let myTime: Double
        if let stored = storedMyPath {
            myPath = stored
            myTime = myStoredEta ?? 0
            AppLog.meet.debug("activateRoute(\(isSender ? "sender" : "receiver")): using stored path (\(stored.count) edges)")
        } else {
            // Fallback: re-solve locally from live/stored position.
            let myStoredNodeId = isSender ? request.senderPositionNodeId : request.receiverPositionNodeId
            let myNodeId = resolveMyNodeId(graph: graph)
                ?? myStoredNodeId.flatMap({ graph.nodes[$0] != nil ? $0 : nil })

            if let myNodeId {
                let solver = configureSolver(graph: graph)
                // 3-attempt fallback chain mirrors MeetSolver:
                //   (1) strict pathTo with live skill gates,
                //   (2) relaxed skill gates,
                //   (3) force-open everything + relaxed gates.
                let attempt1 = solver.pathTo(target: target, from: myNodeId, skier: myProfile)
                let attempt2: (path: [GraphEdge], time: Double)? = attempt1 != nil ? nil : solver.pathTo(target: target, from: myNodeId, skier: myProfile, ignoreSkillGates: true)
                let attempt3: (path: [GraphEdge], time: Double)? = (attempt1 == nil && attempt2 == nil) ? {
                    var open = graph
                    for i in open.edges.indices {
                        var attrs = open.edges[i].attributes
                        attrs.isOpen = true
                        open.edges[i] = GraphEdge(
                            id: open.edges[i].id,
                            sourceID: open.edges[i].sourceID,
                            targetID: open.edges[i].targetID,
                            kind: open.edges[i].kind,
                            geometry: open.edges[i].geometry,
                            attributes: attrs
                        )
                    }
                    open.rebuildIndices()
                    let openSolver = MeetingPointSolver(graph: open)
                    openSolver.solveTime = solver.solveTime
                    openSolver.resortLatitude = solver.resortLatitude
                    openSolver.resortLongitude = solver.resortLongitude
                    openSolver.temperatureC = solver.temperatureC
                    openSolver.windSpeedKmh = solver.windSpeedKmh
                    openSolver.freshSnowCm = solver.freshSnowCm
                    openSolver.visibilityKm = solver.visibilityKm
                    openSolver.cloudCoverPercent = solver.cloudCoverPercent
                    openSolver.stationElevationM = solver.stationElevationM
                    openSolver.edgeSpeedHistory = solver.edgeSpeedHistory
                    return openSolver.pathTo(target: target, from: myNodeId, skier: myProfile, ignoreSkillGates: true)
                }() : nil

                if let myRoute = attempt1 ?? attempt2 ?? attempt3 {
                    myPath = myRoute.path
                    myTime = myRoute.time
                    let tier = attempt1 != nil ? "live" : (attempt2 != nil ? "skill-relaxed" : "all-open")
                    AppLog.meet.debug("activateRoute(\(isSender ? "sender" : "receiver")): re-solved locally (\(myRoute.path.count) edges, tier=\(tier))")
                } else {
                    AppLog.meet.info("activateRoute(\(isSender ? "sender" : "receiver")): fallback solve returned nil even after relax+force-open — activating with empty path")
                    myPath = []
                    myTime = myStoredEta ?? 0
                    coord.setTransientMessage("ROUTING DATA OUT OF SYNC — PULL TO REFRESH")
                }
            } else {
                AppLog.meet.debug("activateRoute(\(isSender ? "sender" : "receiver")): no stored path and cannot resolve position — activating with empty path")
                myPath = []
                myTime = myStoredEta ?? 0
                coord.setTransientMessage("ROUTING DATA OUT OF SYNC — PULL TO REFRESH")
            }
        }

        let friendPath: [GraphEdge]
        let friendEta: Double
        if let stored = storedFriendPath {
            friendPath = stored
            friendEta = friendStoredEta ?? 0
        } else {
            let friendStoredNodeId = isSender ? request.receiverPositionNodeId : request.senderPositionNodeId
            if let fnId = friendStoredNodeId, graph.nodes[fnId] != nil {
                let solver = configureSolver(graph: graph)
                let fr = solver.pathTo(target: target, from: fnId, skier: friendProfile)
                    ?? solver.pathTo(target: target, from: fnId, skier: friendProfile, ignoreSkillGates: true)
                if let fr {
                    friendPath = fr.path
                    friendEta = fr.time
                    AppLog.meet.debug("activateRoute: re-solved friend path locally (\(fr.path.count) edges)")
                } else if let fallbackEta = friendStoredEta {
                    friendPath = []
                    friendEta = fallbackEta
                } else {
                    friendPath = []
                    friendEta = 0
                }
            } else if let fallbackEta = friendStoredEta {
                friendPath = []
                friendEta = fallbackEta
            } else {
                friendPath = []
                friendEta = 0
            }
        }

        let result = MeetingResult(
            meetingNode: meetingNode,
            pathA: myPath,
            pathB: friendPath,
            timeA: myTime,
            timeB: friendEta,
            alternates: []
        )

        coord.meetingResult = result
        let tracker = RouteProgressTracker(
            path: result.pathA,
            graph: graph,
            meetingNodeId: target
        )
        coord.activeMeetSession = ActiveMeetSession(
            id: request.id,
            friendProfile: friendProfile,
            meetingResult: result,
            meetingNodeId: target,
            startedAt: Date.now,
            routeTracker: tracker
        )
        coord.routeAnimationTrigger += 1
    }

    // MARK: - Reroute

    /// Re-routes to the SAME meeting node when deviation is detected.
    /// Does NOT re-solve the meeting point — both users already agreed
    /// on it.
    func reroute(retryAttempt: Int = 0) async {
        guard let coord = coordinator,
              var session = coord.activeMeetSession,
              let myProfile = SupabaseManager.shared.currentUserProfile,
              let graph = coord.resortManager.currentGraph else { return }

        let myNodeId: String
        if let myCoord = coord.locationManager.currentLocation,
           let myNode = graph.nearestNode(to: myCoord) {
            myNodeId = myNode.id
        } else if retryAttempt < 2 {
            // No GPS fix yet — sleep briefly and try again. Without this
            // retry the first reroute request after a tunnel / chairlift
            // occlusion silently no-ops.
            try? await Task.sleep(for: .seconds(3))
            await reroute(retryAttempt: retryAttempt + 1)
            return
        } else {
            AppLog.meet.info("reroute: giving up — no GPS fix after \(retryAttempt) retries")
            return
        }

        // Path-find to the SAME agreed meeting node (don't re-solve)
        let target = session.meetingNodeId
        let solver = configureSolver(graph: graph)

        guard let myRoute = solver.pathTo(target: target, from: myNodeId, skier: myProfile) else {
            if retryAttempt < 2 {
                AppLog.meet.info("reroute: no path from \(myNodeId) — retry \(retryAttempt + 1)")
                try? await Task.sleep(for: .seconds(4))
                await reroute(retryAttempt: retryAttempt + 1)
            } else {
                AppLog.meet.debug("reroute: no path from \(myNodeId) to \(target), giving up")
            }
            return
        }

        // Recompute friend's route only when we have a real graph position
        // (no fake "at meeting node").
        let friendId = session.friendProfile.id
        let prev = session.meetingResult
        let (friendPath, friendTime): ([GraphEdge], Double)
        if let reportedId = coord.realtimeLocation?.friendLocations[friendId]?.nearestNodeId,
           graph.nodes[reportedId] != nil,
           let fr = solver.pathTo(target: target, from: reportedId, skier: session.friendProfile) {
            friendPath = fr.path
            friendTime = fr.time
        } else if let friendLoc = coord.realtimeLocation?.friendLocations[friendId] {
            let lc = CLLocationCoordinate2D(latitude: friendLoc.latitude, longitude: friendLoc.longitude)
            if let fn = graph.nearestNode(to: lc),
               let fr = solver.pathTo(target: target, from: fn.id, skier: session.friendProfile) {
                friendPath = fr.path
                friendTime = fr.time
            } else {
                friendPath = prev.pathB
                friendTime = prev.timeB
            }
        } else {
            friendPath = prev.pathB
            friendTime = prev.timeB
        }

        let meetingNode = graph.nodes[target] ?? session.meetingResult.meetingNode
        let result = MeetingResult(
            meetingNode: meetingNode,
            pathA: myRoute.path,
            pathB: friendPath,
            timeA: myRoute.time,
            timeB: friendTime,
            alternates: []
        )

        coord.meetingResult = result
        session.meetingResult = result
        session.routeTracker = RouteProgressTracker(
            path: result.pathA,
            graph: graph,
            meetingNodeId: target
        )
        coord.activeMeetSession = session
        // Reroute keeps `session.id` constant, so the
        // `onChange(of: activeMeetSession?.id)` hook doesn't fire.
        // Re-sync directly — otherwise NavigationDirector /
        // NavigationViewModel keep pointing at the old tracker and
        // stop firing advance/deviate events.
        syncNavigationServices()
        coord.refreshGhostCache(force: true)
        AppLog.meet.debug("reroute: new path from \(myNodeId) to \(target), ETA \(myRoute.time)s")
    }
}
