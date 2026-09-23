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

/// Generation-safe single-flight gate for ETA writes. A cancelled older write
/// cannot clear the slot owned by a newer session, and overlapping GPS fixes
/// are coalesced into one latest-value follow-up instead of launching writes
/// that may land at the server out of order.
nonisolated struct ETABroadcastSingleFlight: Equatable, Sendable {
    private(set) var activeToken: UInt64?
    private(set) var hasDeferredWrite = false
    private var nextToken: UInt64 = 0

    mutating func beginOrDefer() -> UInt64? {
        guard activeToken == nil else {
            hasDeferredWrite = true
            return nil
        }
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    mutating func finish(_ token: UInt64) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    mutating func beginDeferredIfNeeded() -> UInt64? {
        guard activeToken == nil, hasDeferredWrite else { return nil }
        hasDeferredWrite = false
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    mutating func discardDeferred() {
        hasDeferredWrite = false
    }

    mutating func cancel() {
        nextToken &+= 1
        activeToken = nil
        hasDeferredWrite = false
    }
}

private struct ETABroadcastIntent {
    let sessionID: UUID
    let localRole: ActiveMeetParticipantRole
    let etaSeconds: Double
    let estimator: BlendedETAEstimator
    let now: Date
}

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

    /// In-flight reroute task. Tracked so a resort switch (or any
    /// teardown of the active session) can explicitly cancel it —
    /// otherwise the implicit teardown depends on which await point
    /// the task is currently parked at, and a parked
    /// `Task.sleep(for: .seconds(8))` keeps running through the
    /// teardown.
    @ObservationIgnored var rerouteTask: Task<Void, Never>?

    /// At most one ETA mutation may be in flight from this device. Without a
    /// single-flight boundary, a slower older HTTP update can land after a
    /// newer one and make the partner's ETA jump backward.
    @ObservationIgnored var etaBroadcastTask: Task<Void, Never>?
    @ObservationIgnored var etaBroadcastGate = ETABroadcastSingleFlight()
    @ObservationIgnored private var pendingETABroadcast: ETABroadcastIntent?

    /// De-duplicates cold-launch recovery and a simultaneous Realtime accepted
    /// event. Both can legitimately observe the same server row; only one may
    /// construct trackers, navigation services, and route choreography.
    @ObservationIgnored var activationRequestIDs: Set<UUID> = []

    /// Throttle for `evaluateFasterRerouteIfNeeded` — at most one
    /// attempt per 30 s. Background enrichment tends to land in
    /// bursts (Epic + MtnPowder + Liftie all return within seconds
    /// of each other on cold load), and the `MountainGraph.fingerprint`
    /// shifts on each one. Without throttling the watcher could
    /// fire a re-route 3 times in 5 s, producing flickering route
    /// lines.
    @ObservationIgnored var lastFasterRerouteAt: Date = .distantPast
    /// Time of the last route-line swap caused only by an optimization. Used
    /// by RouteSwitchPolicy to raise the bar briefly after a change. Closure
    /// and deviation reroutes never consult it.
    @ObservationIgnored var lastAppliedFasterRerouteAt: Date?
    let fasterRerouteThrottle: TimeInterval = 30.0

    init() {}

    /// Consume a fresh partner fix into their own monotonic route tracker.
    /// Events are deliberately ignored: only the partner's phone may reroute
    /// or announce navigation actions for them. Locally this trims completed
    /// map history and keeps closure validation scoped to unfinished edges.
    func updateFriendRouteProgress() {
        guard let coord = coordinator,
              let session = coord.activeMeetSession,
              let tracker = session.friendRouteTracker,
              let location = coord.realtimeLocation?.friendLocations[
                  session.friendProfile.id
              ],
              FriendSignalClassifier.isEligibleForRouting(
                  locationResortID: location.resortId,
                  selectedResortID: session.datasetIdentity.resortID,
                  lastSeen: location.capturedAt,
                  accuracyMeters: location.accuracyMeters,
                  now: .now
              ) else { return }
        tracker.update(location: CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude
        ), at: location.capturedAt)
    }

    // MARK: - Solver / node resolution

    /// Configures a solver with current environmental conditions. The
    /// Used by activation and rerouting. Interactive pair solving should use
    /// `MeetSolver.solve(...)`, which applies the same strict defaults.
    func configureSolver(
        graph: MountainGraph,
        solveTime: Date = .now,
        participantProfiles: [UserProfile] = []
    ) -> MeetingPointSolver {
        let solver = MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: coordinator?.resortManager.currentDataset?.rendezvousCatalog
                ?? .derived(from: graph)
        )
        solver.datasetVersion = coordinator?.resortManager.currentDataset?.version.identifier
        // A frozen preview map has no verified lift hours or status, so every
        // pre-release exercise on it (Go To preview, route rehearsal, test
        // meetup) is a timeless graph solve. Otherwise an evening tester was
        // told every lift is closed. Canonical data keeps arrival-time hours.
        solver.solveTime = coordinator?.resortManager.currentDataset?.source == .canonicalServer
            ? solveTime
            : nil
        if let hours = CuratedResortLoader.load(resortId: graph.resortID)?.operatingHours {
            solver.liftOpenHour = hours.openHour
            solver.liftCloseHour = hours.closeHour
        }
        if let entry = coordinator?.resortManager.currentEntry {
            solver.resortLatitude = (entry.bounds.minLat + entry.bounds.maxLat) / 2
            solver.resortLongitude = (entry.bounds.minLon + entry.bounds.maxLon) / 2
        }
        if let conditions = coordinator?.resortConditions,
           conditions.isFreshForRouting() {
            solver.resortUTCOffsetSeconds = conditions.utcOffsetSeconds
            solver.temperatureC = conditions.temperatureC
            solver.windSpeedKmh = conditions.windSpeedKph
            solver.freshSnowCm = conditions.snowfallLast24hCm
            solver.visibilityKm = conditions.visibilityKm
            solver.cloudCoverPercent = conditions.cloudCoverPercent
            solver.stationElevationM = conditions.stationElevationM
            solver.hourlyWeather = conditions.hourlyForecast
        }
        // Keep activation ETA attribution per skier just like the original
        // two-person solve. The shared dict remains the single-skier fallback;
        // explicit profile slots prevent the local user's learned speeds from
        // bleeding into the friend's strict validation/re-solve.
        let supabase = SupabaseManager.shared
        solver.edgeSpeedHistory = supabase.currentEdgeSpeeds
        var histories = Dictionary(
            uniqueKeysWithValues: supabase.friendEdgeSpeeds.map {
                ($0.key.uuidString, $0.value)
            }
        )
        if let myID = supabase.currentUserProfile?.id.uuidString {
            histories[myID] = supabase.currentEdgeSpeeds
        }
        solver.edgeSpeedHistoryByProfile = histories

        // An accepted session owns an authoritative snapshot of both skier
        // profiles. Prefer those explicit participants over the eventually
        // consistent friends cache so cold recovery, activation, rerouting,
        // ETA projection, and closure revalidation all use the skis that were
        // actually selected by each skier.
        var equipment: [String: SkiPerformanceProfile] = [:]
        let profiles = Self.resolvedRoutingProfiles(
            currentUser: supabase.currentUserProfile,
            cachedFriends: coordinator?.friendService.friends ?? [],
            participants: participantProfiles
        )
        for profile in profiles.values {
            if let entry = supabase.skiCatalogEntry(forSkiId: profile.preferredSkiId) {
                equipment[profile.id.uuidString] = SkiPerformanceProfile(entry: entry)
            }
        }
        solver.equipmentByProfile = equipment
        return solver
    }

    nonisolated static func resolvedRoutingProfiles(
        currentUser: UserProfile?,
        cachedFriends: [UserProfile],
        participants: [UserProfile]
    ) -> [UUID: UserProfile] {
        var profiles = Dictionary(uniqueKeysWithValues: cachedFriends.map { ($0.id, $0) })
        if let currentUser {
            profiles[currentUser.id] = currentUser
        }
        for participant in participants {
            profiles[participant.id] = participant
        }
        return profiles
    }

    /// Resolves a node ID for the current user. Priority:
    ///  1. Live GPS sticky node (user is at this resort)
    ///  2. Fresh GPS nearestNode (also gated to resort by 1000m cap inside)
    ///  3. Tester-picked node (debug/TestFlight manual placement)
    ///  4. nil — user is not at this resort and no manual placement set
    ///
    /// Live location always wins over the tester pick.
    func resolveMyNodeId(graph: MountainGraph) -> String? {
        resolveMyOrigin(graph: graph)?.startNodeID
    }

    func resolveMyOrigin(graph: MountainGraph) -> RoutingOrigin? {
        guard let coord = coordinator else { return nil }
        if let loc = coord.locationManager.currentLocation,
           RoutingFixPolicy.isUsable(
                horizontalAccuracyMeters: coord.locationManager.currentAccuracy,
                capturedAt: coord.locationManager.currentFixTimestamp
           ),
           let origin = graph.routingOrigin(
                to: loc,
                travelCourseDegrees: coord.locationManager.usableTravelCourse,
                altitudeMeters: coord.locationManager.routingAltitudeMeters,
                verticalAccuracyMeters: coord.locationManager.currentVerticalAccuracy,
                maximumSnapDistanceMeters: RoutingFixPolicy.networkSnapTolerance(
                    horizontalAccuracyMeters: coord.locationManager.currentAccuracy
                ),
                positionUncertaintyMeters: RoutingFixPolicy.positionUncertaintyMeters(
                    horizontalAccuracyMeters: coord.locationManager.currentAccuracy
                )
           ) { return origin }
        if let testId = coord.testMyNodeId, graph.nodes[testId] != nil { return .node(testId) }
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
            let solver = configureSolver(
                graph: graph,
                participantProfiles: [myProfile, session.friendProfile]
            )
            let context = solver.makeContext(for: myProfile.id.uuidString)
            let routeEstimate = ActiveRouteETA.estimate(
                path: tracker.path,
                currentEdgeIndex: tracker.currentEdgeIndex,
                currentEdgeFraction: tracker.currentEdgeFraction,
                profile: myProfile,
                context: context
            )
            let computedRemaining = routeEstimate?.totalSeconds ?? .infinity
            let priorSeconds = computedRemaining.isFinite
                ? computedRemaining
                : session.meetingResult.timeA
            let totalRemaining = tracker.remainingRouteMeters
            estimator.reset(solverEstimateSeconds: priorSeconds, remainingMeters: totalRemaining)
            if let estimate = routeEstimate {
                estimator.updateRouteEstimate(
                    estimate,
                    currentEdgeRemainingMeters: tracker.currentEdgeRemainingMeters,
                    edgeID: tracker.currentEdge?.id,
                    edgeKind: tracker.currentEdge?.kind
                )
            }
            etaEstimator = estimator
        } else {
            routeChoreographer?.cancel()
            navigationDirector = nil
            navigationViewModel = nil
            routeChoreographer = nil
            etaEstimator = nil
        }
    }

    /// Re-cost the unfinished route at the fix timestamp. This keeps future
    /// lift queues, operating hours, and forecast conditions in the baseline;
    /// the estimator then applies measured pace only to the current edge.
    func liveRouteETAEstimate(
        session: ActiveMeetSession,
        at now: Date
    ) -> ActiveRouteETAEstimate? {
        guard let coord = coordinator,
              let tracker = session.routeTracker,
              let dataset = coord.resortManager.currentDataset,
              let graph = coord.resortManager.currentGraph,
              session.datasetIdentity.matches(dataset: dataset, graph: graph),
              let profile = SupabaseManager.shared.currentUserProfile else { return nil }

        // Preserve accepted edge identity while taking mutable closures and
        // queue values from the current same-version graph. Context creation
        // is lightweight; no Dijkstra/route selection runs on this GPS path.
        let currentPath = tracker.path.compactMap { graph.edge(byID: $0.id) }
        guard currentPath.count == tracker.path.count else { return nil }
        let solver = configureSolver(
            graph: graph,
            solveTime: now,
            participantProfiles: [profile, session.friendProfile]
        )
        let context = solver.makeContext(for: profile.id.uuidString)
        return ActiveRouteETA.estimate(
            path: currentPath,
            currentEdgeIndex: tracker.currentEdgeIndex,
            currentEdgeFraction: tracker.currentEdgeFraction,
            profile: profile,
            context: context.rebased(to: now)
        )
    }

    // MARK: - End meetup

    /// Cancel any in-flight reroute task. Called from every active-session
    /// teardown path (end-meetup, other-user-cancelled, resort switch) so a
    /// reroute parked on `Task.sleep` doesn't keep running and stomp on
    /// the new state when it wakes.
    func cancelActiveSession() {
        rerouteTask?.cancel()
        rerouteTask = nil
        etaBroadcastGate.cancel()
        etaBroadcastTask?.cancel()
        etaBroadcastTask = nil
        pendingETABroadcast = nil
        lastFasterRerouteAt = .distantPast
        lastAppliedFasterRerouteAt = nil
    }

    /// Cancel the active meetup in DB so the other user sees it end too,
    /// then clear local session state.
    func endActiveMeetup() {
        guard let coord = coordinator else { return }
        if let sessionId = coord.activeMeetSession?.id {
            coord.meetRequestService.endRequestEventually(sessionId)
        }
        coord.meetRequestService.trackActiveRequest(nil)
        cancelActiveSession()
        coord.activeMeetSession = nil
        coord.meetingResult = nil
    }

    /// Driven from `MeetRequestService.onEvent(.expired)` — the other user
    /// ended the meetup. Clear our session if the request id matches;
    /// otherwise leave state alone (a different session is in flight).
    func handleMeetupCancelledByOther(requestId: UUID) {
        guard let coord = coordinator,
              coord.activeMeetSession?.id == requestId else { return }
        coord.meetRequestService.trackActiveRequest(nil)
        cancelActiveSession()
        withAnimation(.easeInOut(duration: 0.2)) {
            coord.activeMeetSession = nil
            coord.meetingResult = nil
        }
    }

    /// Keep the local HUD honest on every accepted GPS fix, not only when the
    /// database broadcast cadence fires. The active-session result always uses
    /// local=A and partner=B regardless of who created the request.
    func updateLocalETA(_ etaSeconds: Double) {
        guard etaSeconds.isFinite, etaSeconds >= 0,
              let coord = coordinator,
              var session = coord.activeMeetSession else { return }
        session.meetingResult.timeA = etaSeconds
        coord.activeMeetSession = session
        if var mapResult = coord.meetingResult,
           mapResult.meetingNode.id == session.meetingNodeId {
            mapResult.timeA = etaSeconds
            coord.meetingResult = mapResult
        }
    }

    /// Serializes best-effort ETA writes while leaving the on-device HUD fully
    /// responsive. While one request is in flight, only the newest eligible ETA
    /// is retained and drained afterward. Failure does not advance the estimator
    /// baseline; teardown invalidates the generation token and queued value.
    func broadcastLocalETAIfNeeded(
        sessionID: UUID,
        localRole: ActiveMeetParticipantRole,
        etaSeconds: Double,
        estimator: BlendedETAEstimator,
        now: Date
    ) {
        guard etaSeconds.isFinite, etaSeconds >= 0,
              estimator.shouldBroadcast(now: now),
              coordinator != nil else { return }
        let intent = ETABroadcastIntent(
            sessionID: sessionID,
            localRole: localRole,
            etaSeconds: etaSeconds,
            estimator: estimator,
            now: now
        )
        guard let token = etaBroadcastGate.beginOrDefer() else {
            pendingETABroadcast = intent
            return
        }
        startETABroadcast(intent, token: token)
    }

    private func startETABroadcast(
        _ intent: ETABroadcastIntent,
        token: UInt64
    ) {
        guard let service = coordinator?.meetRequestService else {
            _ = etaBroadcastGate.finish(token)
            etaBroadcastGate.discardDeferred()
            pendingETABroadcast = nil
            return
        }
        let update = intent.localRole.etaUpdate(localETA: intent.etaSeconds)
        let task = Task { @MainActor [weak self] in
            let succeeded = await service.updateETAReportingSuccess(
                requestId: intent.sessionID,
                newTimeA: update.sender,
                newTimeB: update.receiver
            )
            guard let self,
                  !Task.isCancelled,
                  self.etaBroadcastGate.finish(token) else { return }
            self.etaBroadcastTask = nil
            if succeeded,
               self.coordinator?.activeMeetSession?.id == intent.sessionID,
               self.etaEstimator === intent.estimator {
                intent.estimator.didBroadcast(
                    etaSeconds: intent.etaSeconds,
                    now: intent.now
                )
            }
            self.drainDeferredETABroadcast()
        }
        etaBroadcastTask = task
    }

    private func drainDeferredETABroadcast() {
        guard let intent = pendingETABroadcast else {
            etaBroadcastGate.discardDeferred()
            return
        }
        pendingETABroadcast = nil
        guard coordinator?.activeMeetSession?.id == intent.sessionID,
              etaEstimator === intent.estimator,
              intent.estimator.shouldBroadcast(now: intent.now),
              let token = etaBroadcastGate.beginDeferredIfNeeded() else {
            etaBroadcastGate.discardDeferred()
            return
        }
        startETABroadcast(intent, token: token)
    }

    /// Applies only the opposite participant's role-specific ETA column. An
    /// echoed update from this device therefore cannot overwrite its own local
    /// estimator, and a stale/unrelated request cannot touch the active HUD.
    func handleRemoteETAUpdate(_ request: MeetRequest) {
        guard let coord = coordinator,
              var session = coord.activeMeetSession,
              session.id == request.id,
              let partnerETA = session.localRole.partnerETA(
                  senderETA: request.senderEtaSeconds,
                  receiverETA: request.receiverEtaSeconds
              ),
              partnerETA.isFinite,
              partnerETA >= 0 else { return }
        session.meetingResult.timeB = partnerETA
        coord.activeMeetSession = session
        if var mapResult = coord.meetingResult,
           mapResult.meetingNode.id == session.meetingNodeId {
            mapResult.timeB = partnerETA
            coord.meetingResult = mapResult
        }
    }

}
