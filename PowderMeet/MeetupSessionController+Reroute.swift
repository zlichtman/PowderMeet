//
//  MeetupSessionController+Reroute.swift
//  PowderMeet
//
//  Extension of MeetupSessionController — re-route on graph change + live faster-route evaluation (throttled).
//  Split out of MeetupSessionController.swift (behavior-preserving code motion;
//  the determinism-sensitive receiver path is moved verbatim). @MainActor inherited.
//

import Foundation
import CoreLocation
import SwiftUI

extension MeetupSessionController {
    // MARK: - Reroute

    /// Re-routes to the SAME meeting node when deviation is detected.
    /// Does NOT re-solve the meeting point — both users already agreed
    /// on it.
    ///
    /// Wraps `performReroute` so the in-flight task is tracked on
    /// `rerouteTask` and a resort switch / session teardown can
    /// cancel it explicitly (otherwise an `await Task.sleep` parked
    /// inside the GPS-wait loop outlives the implicit teardown).
    /// Replaces any prior in-flight reroute — only the latest matters.
    func reroute(
        optimizationOnly: Bool = false,
        invalidateIfUnavailable: Bool = false
    ) async {
        // Background optimization cannot replace a safety/deviation recovery
        // or make its unverified route appear usable again.
        if optimizationOnly,
           rerouteTask != nil || coordinator?.activeMeetSession?.routeRecoveryState != .ready {
            return
        }
        rerouteTask?.cancel()
        let recoverySessionID = coordinator?.activeMeetSession?.id
        if !optimizationOnly, var session = coordinator?.activeMeetSession {
            session.routeRecoveryState = .recalculating
            coordinator?.activeMeetSession = session
        }
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.performReroute(
                optimizationOnly: optimizationOnly,
                invalidateIfUnavailable: invalidateIfUnavailable
            )
        }
        rerouteTask = task
        await task.value
        if rerouteTask == task {
            rerouteTask = nil
            if var session = coordinator?.activeMeetSession,
               session.id == recoverySessionID,
               session.routeRecoveryState == .recalculating {
                session.routeRecoveryState = .unavailable
                coordinator?.activeMeetSession = session
            }
        }
    }

    func performReroute(
        optimizationOnly: Bool,
        invalidateIfUnavailable: Bool
    ) async {
        guard let coord = coordinator,
              var session = coord.activeMeetSession,
              var myProfile = SupabaseManager.shared.currentUserProfile,
              var graph = coord.resortManager.currentGraph else { return }

        // Faster-route checks aren't user-visible; only deviation reroutes
        // (no threshold) get the recalculating banner. The threshold path
        // already has its own "FASTER ROUTE — UPDATING" pill below.
        let isDeviationReroute = !optimizationOnly
            && !invalidateIfUnavailable
        if isDeviationReroute {
            coord.transientMessage = "RECALCULATING ROUTE…"
        }

        // 30-second budget with rough exponential backoff (2 + 4 + 8 + 8 + 8).
        // Replaces the old 2× recursive retry with a hard 8 s ceiling that
        // silently gave up in the exact terrain (lift sheds, gondolas,
        // tree cover) where GPS reacquisition takes the longest.
        let backoffs: [Double] = [2, 4, 8, 8, 8]

        let target = session.meetingNodeId
        var solver = configureSolver(
            graph: graph,
            participantProfiles: [myProfile, session.friendProfile]
        )
        var myOrigin: RoutingOrigin?
        var myRoute: (path: [GraphEdge], time: Double, etaStdSeconds: Double)?
        var attemptIdx = 0

        while myRoute == nil {
            if Task.isCancelled { return }
            guard let currentSession = coord.activeMeetSession,
                  currentSession.id == session.id,
                  let currentProfile = SupabaseManager.shared.currentUserProfile,
                  currentProfile.id == myProfile.id else { return }
            session = currentSession
            myProfile = currentProfile
            let attemptTime = Date.now
            guard let dataset = coord.resortManager.currentDataset,
                  let currentGraph = coord.resortManager.currentGraph,
                  session.datasetIdentity.matches(dataset: dataset, graph: currentGraph) else {
                invalidateActiveSessionForDatasetDrift(session, coordinator: coord)
                return
            }
            // A pre-release test meet on a preview map has no status to
            // require; `datasetIdentity.matches` already pinned the exact map.
            if !session.datasetIdentity.isPreview {
                guard let status = coord.resortManager.currentStatus,
                      status.resortID == dataset.resortID,
                      status.datasetVersion == dataset.version,
                      status.isRoutable(at: attemptTime) else {
                    let message = coord.resortManager.currentStatus?.operatingMode == .offSeason
                        ? "MOUNTAIN OFF SEASON — MEET ENDED"
                        : "LIVE MOUNTAIN STATUS EXPIRED — START A NEW MEET"
                    invalidateActiveSession(session, coordinator: coord, message: message,
                                            reason: "operational status unavailable during reroute retry")
                    return
                }
            }
            // Rebuild after every suspension: queues, closures, capability,
            // forecast and last-chair timing can all change during the wait.
            graph = currentGraph
            solver = configureSolver(graph: graph, solveTime: attemptTime,
                                     participantProfiles: [myProfile, session.friendProfile])
            myOrigin = RoutingFixPolicy.currentOrigin(
                in: graph,
                coordinate: coord.locationManager.currentLocation,
                horizontalAccuracyMeters: coord.locationManager.currentAccuracy,
                capturedAt: coord.locationManager.currentFixTimestamp,
                travelCourseDegrees: coord.locationManager.usableTravelCourse,
                altitudeMeters: coord.locationManager.routingAltitudeMeters,
                verticalAccuracyMeters: coord.locationManager.currentVerticalAccuracy,
                now: attemptTime
            )

            if let origin = myOrigin {
                myRoute = solver.pathTo(target: target, from: origin, skier: myProfile)
                if myRoute != nil { break }
                AppLog.meet.info("reroute: no path from \(origin.cacheFingerprint) — backoff \(attemptIdx)")
            } else {
                AppLog.meet.info("reroute: no GPS fix yet — backoff \(attemptIdx)")
            }

            guard attemptIdx < backoffs.count else {
                if invalidateIfUnavailable {
                    invalidateActiveSession(
                        session,
                        coordinator: coord,
                        message: "ROUTE CLOSED — START A NEW MEET",
                        reason: "no safe replacement route after operational change"
                    )
                    return
                }
                AppLog.meet.info("reroute: budget exhausted after \(backoffs.reduce(0, +))s — leaving session active")
                if isDeviationReroute && coord.transientMessage == "RECALCULATING ROUTE…" {
                    coord.transientMessage = "ROUTE STALE — WAITING FOR GPS"
                }
                return
            }
            let delay = backoffs[attemptIdx]
            attemptIdx += 1
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }

        guard let myOrigin, let myRoute else { return }

        // Stability gate (live-faster-route case): only swap when the
        // newly-computed path is meaningfully faster than what remains. The
        // policy also rejects same-path timing noise and briefly raises the
        // bar after an applied swap so the route line cannot oscillate.
        var fasterRouteGainSeconds: Double?
        if optimizationOnly {
            let remaining = ActiveRouteOperationalValidator.remainingRoute(
                path: session.routeTracker?.path ?? session.meetingResult.pathA,
                currentEdgeIndex: session.routeTracker?.currentEdgeIndex ?? 0,
                currentEdgeFraction: session.routeTracker?.currentEdgeFraction
                    ?? session.meetingResult.initialEdgeFractionA
            )
            let remainingEdgeIDs = remaining.edgeIDs
            let currentInitialFraction = remaining.initialEdgeFraction
            let currentRemainingPath = remainingEdgeIDs.compactMap(graph.edge(byID:))
            guard currentRemainingPath.count == remainingEdgeIDs.count,
                  let currentMetrics = solver.metrics(
                    for: currentRemainingPath,
                    skier: myProfile,
                    initialEdgeFraction: currentInitialFraction
                  ) else {
                AppLog.meet.debug("reroute:rejected:current route metrics unavailable")
                return
            }
            let sinceLastSwitch = lastAppliedFasterRerouteAt.map {
                Date.now.timeIntervalSince($0)
            }
            let decision = RouteSwitchPolicy.decide(
                currentRemainingSeconds: currentMetrics.time,
                candidateSeconds: myRoute.time,
                currentUncertaintySeconds: currentMetrics.etaStdSeconds,
                candidateUncertaintySeconds: myRoute.etaStdSeconds,
                currentRemainingEdgeIDs: remainingEdgeIDs,
                candidateEdgeIDs: myRoute.path.map(\.id),
                secondsSinceLastAppliedSwitch: sinceLastSwitch
            )
            guard case .switchRoute(let gain) = decision else {
                AppLog.meet.debug("reroute:rejected:decision=\(String(describing: decision))")
                return
            }
            fasterRouteGainSeconds = gain
            AppLog.meet.debug("reroute:accepted:gain=\(Int(gain))s")
            // Brief amber banner so the user knows why their route line
            // just changed — uses the existing `transientMessage` shape
            // used by graph-drift-on-activate. 2 s lifetime.
            coord.transientMessage = "FASTER ROUTE — UPDATING"
            Task { [weak coord] in
                try? await Task.sleep(for: .seconds(2))
                if coord?.transientMessage == "FASTER ROUTE — UPDATING" {
                    coord?.transientMessage = nil
                }
            }
        }

        // Recompute friend's route only when we have a real graph position
        // (no fake "at meeting node").
        let friendId = session.friendProfile.id
        let prev = session.meetingResult
        let friendLocation = coord.realtimeLocation?.friendLocations[friendId]
        let friendLocationIsLive = friendLocation.map {
            FriendSignalClassifier.isEligibleForRouting(
                locationResortID: $0.resortId,
                selectedResortID: graph.resortID,
                lastSeen: $0.capturedAt,
                accuracyMeters: $0.accuracyMeters,
                now: .now
            )
        } ?? false
        let friendRoute: (path: [GraphEdge], time: Double, etaStdSeconds: Double?)?
        let friendInitialEdgeFraction: Double
        if friendLocationIsLive, let friendLoc = friendLocation {
            let lc = CLLocationCoordinate2D(latitude: friendLoc.latitude, longitude: friendLoc.longitude)
            if let friendOrigin = graph.routingOrigin(
                to: lc,
                travelCourseDegrees: friendLoc.usableTravelCourse,
                altitudeMeters: friendLoc.routingAltitudeMeters,
                verticalAccuracyMeters: friendLoc.verticalAccuracyMeters,
                maximumSnapDistanceMeters: RoutingFixPolicy.networkSnapTolerance(
                    horizontalAccuracyMeters: friendLoc.accuracyMeters
                ),
                positionUncertaintyMeters: RoutingFixPolicy.positionUncertaintyMeters(
                    horizontalAccuracyMeters: friendLoc.accuracyMeters
                )
            ),
               let fr = solver.pathTo(
                target: target,
                from: friendOrigin,
                skier: session.friendProfile
               ) {
                friendRoute = fr
                friendInitialEdgeFraction = friendOrigin.initialFraction(
                    forFirstEdgeID: fr.path.first?.id
                )
            } else {
                friendRoute = nil
                friendInitialEdgeFraction = 0
            }
        } else {
            let retainedRoute = validatedExistingRoute(
                path: session.friendRouteTracker?.path ?? prev.pathB,
                currentEdgeIndex: session.friendRouteTracker?.currentEdgeIndex ?? 0,
                currentEdgeFraction: session.friendRouteTracker?.currentEdgeFraction
                    ?? prev.initialEdgeFractionB,
                targetID: target,
                profile: session.friendProfile,
                graph: graph,
                solver: solver
            )
            friendRoute = retainedRoute.map { ($0.path, $0.time, $0.etaStdSeconds) }
            friendInitialEdgeFraction = retainedRoute?.initialEdgeFraction ?? 0
        }

        guard let friendRoute else {
            invalidateActiveSession(
                session,
                coordinator: coord,
                message: "PARTNER ROUTE CHANGED — START A NEW MEET",
                reason: "friend route could not be revalidated after status change"
            )
            return
        }

        let meetingNode = graph.nodes[target] ?? session.meetingResult.meetingNode
        let result = MeetingResult(
            meetingNode: meetingNode,
            pathA: myRoute.path,
            pathB: friendRoute.path,
            timeA: myRoute.time,
            timeB: friendRoute.time,
            alternates: [],
            initialEdgeFractionA: myOrigin.initialFraction(
                forFirstEdgeID: myRoute.path.first?.id
            ),
            initialEdgeFractionB: friendInitialEdgeFraction,
            meetingDisplayName: prev.meetingDisplayName,
            rendezvousPoint: prev.rendezvousPoint,
            etaStdSecondsA: myRoute.etaStdSeconds,
            etaStdSecondsB: friendRoute.etaStdSeconds
        )

        coord.meetingResult = result
        session.meetingResult = result
        session.routeRecoveryState = .ready
        session.routePlanStartedAt = .now
        session.routeTracker = RouteProgressTracker(
            path: result.pathA,
            graph: graph,
            meetingNodeId: target,
            initialEdgeFraction: result.initialEdgeFractionA
        )
        session.friendRouteTracker = RouteProgressTracker(
            path: result.pathB,
            graph: graph,
            meetingNodeId: target,
            initialEdgeFraction: result.initialEdgeFractionB
        )
        coord.activeMeetSession = session
        if fasterRouteGainSeconds != nil {
            lastAppliedFasterRerouteAt = .now
        }
        // Reroute keeps `session.id` constant, so the
        // `onChange(of: activeMeetSession?.id)` hook doesn't fire.
        // Re-sync directly — otherwise NavigationDirector /
        // NavigationViewModel keep pointing at the old tracker and
        // stop firing advance/deviate events.
        syncNavigationServices()
        coord.refreshGhostCache(force: true)
        let completedBannerMessages: Set<String> = isDeviationReroute
            ? ["RECALCULATING ROUTE…", "ROUTE STALE — WAITING FOR GPS"]
            : (invalidateIfUnavailable
                ? ["MOUNTAIN STATUS CHANGED — RECALCULATING", "ROUTE CONDITIONS CHANGED — RECALCULATING"]
                : [])
        if let message = coord.transientMessage,
           completedBannerMessages.contains(message) {
            coord.transientMessage = nil
        }
        AppLog.meet.debug("reroute: new path from \(myOrigin.cacheFingerprint) to \(target), ETA \(myRoute.time)s")
    }

    /// Retains only the last observed unfinished route when the partner has
    /// no eligible live fix. This is not a fresh location or an extrapolation.
    func validatedExistingRoute(
        path: [GraphEdge],
        currentEdgeIndex: Int,
        currentEdgeFraction: Double,
        targetID: String,
        profile: UserProfile,
        graph: MountainGraph,
        solver: MeetingPointSolver
    ) -> (path: [GraphEdge], time: Double, etaStdSeconds: Double?, initialEdgeFraction: Double)? {
        let remaining = ActiveRouteOperationalValidator.remainingRoute(
            path: path, currentEdgeIndex: currentEdgeIndex,
            currentEdgeFraction: currentEdgeFraction
        )
        let expectedStartID = remaining.edgeIDs.first
            .flatMap { graph.edge(byID: $0)?.sourceID } ?? targetID
        guard case .success(let currentPath) = StoredRouteValidator.validate(
            edgeIDs: remaining.edgeIDs,
            in: graph,
            expectedStartID: expectedStartID,
            targetID: targetID
        ) else { return nil }

        guard let metrics = solver.metrics(
            for: currentPath, skier: profile,
            initialEdgeFraction: remaining.initialEdgeFraction
        ) else {
            return nil
        }
        return (currentPath, metrics.time, metrics.etaStdSeconds, remaining.initialEdgeFraction)
    }

    // MARK: - Live faster-route evaluation


    /// Called from the `currentGraph?.fingerprint` watcher in
    /// ContentView when a meetup is active. Computes the user's
    /// remaining ETA on the current path; if we're not nearly arrived,
    /// kicks an optimization-only reroute. RouteSwitchPolicy admits a
    /// meaningfully faster newly-opened path but rejects timing noise and
    /// back-and-forth swaps.
    func evaluateFasterRerouteIfNeeded() {
        guard let coord = coordinator,
              let session = coord.activeMeetSession,
              let tracker = session.routeTracker,
              let myProfile = SupabaseManager.shared.currentUserProfile,
              let dataset = coord.resortManager.currentDataset,
              let graph = coord.resortManager.currentGraph else { return }
        guard session.datasetIdentity.matches(dataset: dataset, graph: graph) else {
            invalidateActiveSessionForDatasetDrift(session, coordinator: coord)
            return
        }
        switch ActiveRouteOperationalValidator.evaluate(
            identity: session.datasetIdentity,
            dataset: dataset,
            status: coord.resortManager.currentStatus,
            localRemainingEdgeIDs: ActiveRouteOperationalValidator.remainingEdgeIDs(
                path: tracker.path,
                currentEdgeIndex: tracker.currentEdgeIndex,
                currentEdgeFraction: tracker.currentEdgeFraction
            ),
            friendEdgeIDs: session.friendRouteTracker.map {
                ActiveRouteOperationalValidator.remainingEdgeIDs(
                    path: $0.path,
                    currentEdgeIndex: $0.currentEdgeIndex,
                    currentEdgeFraction: $0.currentEdgeFraction
                )
            } ?? session.meetingResult.pathB.map(\.id),
            meetingNodeID: session.meetingNodeId
        ) {
        case .valid:
            break
        case .datasetDrift:
            invalidateActiveSessionForDatasetDrift(session, coordinator: coord)
            return
        case .statusUnavailable:
            invalidateActiveSession(
                session,
                coordinator: coord,
                message: "LIVE MOUNTAIN STATUS EXPIRED — START A NEW MEET",
                reason: "operational status unavailable during faster-route evaluation"
            )
            return
        case .mountainOffSeason:
            invalidateActiveSession(
                session,
                coordinator: coord,
                message: "MOUNTAIN OFF SEASON — MEET ENDED",
                reason: "mountain entered off-season mode"
            )
            return
        case .routeRequiresReroute:
            coord.transientMessage = "MOUNTAIN STATUS CHANGED — RECALCULATING"
            Task { [weak self] in
                await self?.reroute(invalidateIfUnavailable: true)
            }
            return
        }
        let now = Date.now
        guard now.timeIntervalSince(lastFasterRerouteAt) >= fasterRerouteThrottle else {
            return
        }

        let solver = configureSolver(
            graph: graph,
            participantProfiles: [myProfile, session.friendProfile]
        )
        let context = solver.makeContext(for: myProfile.id.uuidString)
        let remaining = remainingEtaSeconds(session: session, profile: myProfile, context: context)
        if !remaining.isFinite {
            coord.transientMessage = "ROUTE CONDITIONS CHANGED — RECALCULATING"
            Task { [weak self] in
                await self?.reroute(invalidateIfUnavailable: true)
            }
            return
        }
        // RouteSwitchPolicy repeats this final-arrival gate with the candidate
        // in hand. Avoid launching a solve at all when it is already obvious.
        if remaining <= RouteSwitchPolicy.nearArrivalSeconds {
            return
        }
        lastFasterRerouteAt = now
        // Keep the tracker reference live for the closure
        _ = tracker
        Task { [weak self] in
            // Non-nil selects optimization-only policy. Safety and deviation
            // reroutes use their separate un-gated paths.
            await self?.reroute(optimizationOnly: true)
        }
    }

    /// Sum of `traverseTime` over the remaining edges of the current
    /// path. Used as the "are we faster?" baseline for the live
    /// re-route threshold check.
    func remainingEtaSeconds(
        session: ActiveMeetSession,
        profile: UserProfile,
        context: TraversalContext
    ) -> Double {
        guard let tracker = session.routeTracker else { return .infinity }
        return ActiveRouteETA.seconds(
            path: tracker.path,
            currentEdgeIndex: tracker.currentEdgeIndex,
            currentEdgeFraction: tracker.currentEdgeFraction,
            profile: profile,
            context: context
        ) ?? .infinity
    }

    /// A route is a chain of IDs in one immutable dataset. If the loaded
    /// mountain identity changes underneath an active meetup, keeping the old
    /// navigation HUD or solving over the replacement graph would be unsafe.
    private func invalidateActiveSession(
        _ session: ActiveMeetSession,
        coordinator coord: ContentCoordinator,
        message: String,
        reason: String
    ) {
        rerouteTask?.cancel()
        rerouteTask = nil
        coord.meetRequestService.trackActiveRequest(nil)
        coord.meetingResult = nil
        coord.activeMeetSession = nil
        syncNavigationServices()
        coord.transientMessage = message
        coord.meetRequestService.endRequestEventually(session.id)
        AppLog.meet.error("active meet invalidated: \(reason)")
    }

    private func invalidateActiveSessionForDatasetDrift(
        _ session: ActiveMeetSession,
        coordinator coord: ContentCoordinator
    ) {
        invalidateActiveSession(
            session,
            coordinator: coord,
            message: "MOUNTAIN DATA UPDATED — START A NEW MEET",
            reason: "dataset drift from \(session.datasetIdentity.datasetVersion)"
        )
    }

    /// Called after a forced foreground status/manifest refresh. A status-only
    /// projection keeps the same immutable dataset identity and may reroute;
    /// a changed dataset ends the old plan before another GPS fix can advance it.
    func invalidateActiveSessionIfDatasetDrifted() {
        guard let coord = coordinator,
              let session = coord.activeMeetSession,
              let dataset = coord.resortManager.currentDataset,
              let graph = coord.resortManager.currentGraph,
              !session.datasetIdentity.matches(dataset: dataset, graph: graph) else {
            return
        }
        invalidateActiveSessionForDatasetDrift(session, coordinator: coord)
    }

    /// Re-checks both accepted routes after every canonical status refresh.
    /// Expired status ends navigation immediately; a newly closed segment
    /// triggers a strict same-meeting reroute instead of leaving the old line
    /// active or silently forcing the segment open.
    func revalidateActiveSessionAfterOperationalRefresh(now: Date = .now) {
        guard let coord = coordinator,
              let session = coord.activeMeetSession else { return }

        let localRemainingEdgeIDs: [String]
        if let tracker = session.routeTracker {
            localRemainingEdgeIDs = ActiveRouteOperationalValidator.remainingEdgeIDs(
                path: tracker.path,
                currentEdgeIndex: tracker.currentEdgeIndex,
                currentEdgeFraction: tracker.currentEdgeFraction
            )
        } else {
            localRemainingEdgeIDs = session.meetingResult.pathA.map(\.id)
        }
        let friendRemainingEdgeIDs: [String]
        if let tracker = session.friendRouteTracker {
            friendRemainingEdgeIDs = ActiveRouteOperationalValidator.remainingEdgeIDs(
                path: tracker.path,
                currentEdgeIndex: tracker.currentEdgeIndex,
                currentEdgeFraction: tracker.currentEdgeFraction
            )
        } else {
            friendRemainingEdgeIDs = session.meetingResult.pathB.map(\.id)
        }

        switch ActiveRouteOperationalValidator.evaluate(
            identity: session.datasetIdentity,
            dataset: coord.resortManager.currentDataset,
            status: coord.resortManager.currentStatus,
            localRemainingEdgeIDs: localRemainingEdgeIDs,
            friendEdgeIDs: friendRemainingEdgeIDs,
            meetingNodeID: session.meetingNodeId,
            now: now
        ) {
        case .valid:
            return
        case .datasetDrift:
            invalidateActiveSessionForDatasetDrift(session, coordinator: coord)
        case .statusUnavailable:
            invalidateActiveSession(
                session,
                coordinator: coord,
                message: "LIVE MOUNTAIN STATUS EXPIRED — START A NEW MEET",
                reason: "operational status expired or mismatched"
            )
        case .mountainOffSeason:
            invalidateActiveSession(
                session,
                coordinator: coord,
                message: "MOUNTAIN OFF SEASON — MEET ENDED",
                reason: "mountain entered off-season mode"
            )
        case .routeRequiresReroute:
            coord.transientMessage = "MOUNTAIN STATUS CHANGED — RECALCULATING"
            Task { [weak self] in
                await self?.reroute(invalidateIfUnavailable: true)
            }
        }
    }
}
