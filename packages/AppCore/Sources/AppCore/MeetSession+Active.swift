import Foundation
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI

extension MeetSession {
    // MARK: Active

    func startActiveEffects() {
        let clock = deps.clock, inbox = inbox
        bag.start("progress-timer") {
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.progressIntervalS)
                } catch {
                    return
                }
                inbox.yield(.progressTick)
            }
        }
        // After a relaunch the partner's last progress is already on the server.
        readPartnerProgress()
    }

    /// Reads the partner's stored progress; `progressFromPartner` drops a row
    /// that is not newer than the one held.
    func readPartnerProgress() {
        guard let meetID else { return }
        let inbox = inbox, backend = deps.backend, log = deps.log, partnerID = partnerID
        bag.start("partner-progress") {
            do {
                for row in try await backend.meetProgress(meetID: meetID) where row.userID == partnerID {
                    inbox.yield(.progressFromPartner(row))
                }
            } catch {
                if !Task.isCancelled { log.info(.meet, "partner progress unavailable: \(error)") }
            }
        }
    }

    /// Routes from the last fix. A blocked mountain ends the meet with a reason;
    /// an unplaceable fix is "lost" and waits for the next one.
    func navigate(rerouted: Bool) async {
        guard case .active(var active) = state else { return }
        guard let fix = routingFix, let skier = routeSkier(at: fix) else {
            // No fix yet is not "lost"; an old one or one off the map is.
            active.lost = lastFix != nil
            if lastFix != nil { active.failure = .routing(.originNotOnGraph(me)) }
            set(.active(active))
            await publishProgress()
            return
        }
        let result = await Solving.route(skier, to: active.meet.rendezvousID, solveInputs)
        guard !Task.isCancelled, case .active = state else { return }
        switch result {
        case .success(let route):
            await adopt(route, rerouted: rerouted)
        case .failure(.noRendezvousReachable), .failure(.abilityBlocksAll), .failure(.liftDeadlineRisk):
            deps.log.notice(.meet, "no route remains: \(result)")
            await end(.statusBlocksRoute)
        case .failure(let failure):
            active.lost = true
            active.failure = .routing(failure)
            set(.active(active))
            await publishProgress()
        }
    }

    func adopt(_ route: Route, rerouted: Bool) async {
        guard case .active(var active) = state else { return }
        active.navigation = Navigation(
            route: route, progress: RouteProgress.start(route, in: bundle), eta: route.eta,
            maneuvers: Maneuvers.build(for: route, in: bundle), maneuverIndex: 0
        )
        active.lost = false
        active.failure = nil
        set(.active(active))
        if rerouted {
            lastSwitchAt = deps.clock.now
            await funnel("reroute", [:])
        }
        await publishProgress()
    }

    func took(_ fix: Fix) async {
        if let last = lastFix, fix.capturedAt <= last.capturedAt { return }
        lastFix = fix
        noteReach()
        switch state {
        case .proposing(let proposing):
            if proposing.options == nil { requestSolve() }
        case .incoming(let incoming):
            if incoming.ownRoute == nil {
                await computeIncomingRoute()
            } else if let from = incomingRoutedFrom, let here = routingFix,
                      Geo.haversineM(from, here.coordinate) >= RouteProgress.deviationDistanceM {
                // The skier has skied on since the route and its time were
                // worked out: accepting must not start from where they were.
                await computeIncomingRoute()
            }
        case .active(var active):
            let wasArrived = active.arrived
            if isDwelling(at: active.meet.rendezvousID, fix) {
                active.arrived = true
            } else if active.arrived, hasLeft(active.meet.rendezvousID, fix) {
                active.arrived = false
            }
            guard var navigation = active.navigation else {
                set(.active(active))
                if active.arrived != wasArrived { await publishProgress() }
                if active.arrived, !wasArrived { await completeIfBothArrived() }
                await navigate(rerouted: false)
                return
            }
            navigation.progress = RouteProgress.project(
                fix: fix, onto: navigation.route, in: bundle, after: navigation.progress
            )
            // A used-up route is only "nearly there"; arrival is the dwell above.
            active.navigation = navigation

            if !active.arrived, navigation.progress.state == .arrived {
                // The route is finished but the skier is not at the meeting
                // point. Once clearly past it, route again from here.
                if let fix = routingFix, distanceToRendezvous(fix, active.meet.rendezvousID)
                    >= RouteProgress.deviationDistanceM {
                    set(.active(active))
                    await navigate(rerouted: true)
                    return
                }
                navigation.eta = ETA(meanS: 0, sdS: 0)
            } else if !active.arrived {
                // Off the route, or a remaining leg can no longer be taken (I-09):
                // route again from here.
                var blocked = navigation.progress.state == .offRoute
                if !blocked, let skier = mySkier(at: fix) {
                    if let eta = await Solving.recost(
                        navigation.route, from: navigation.progress, skier: skier, solveInputs
                    ) {
                        navigation.eta = eta
                    } else {
                        blocked = true
                    }
                }
                guard !Task.isCancelled, case .active = state else { return }
                if blocked {
                    set(.active(active))
                    await navigate(rerouted: true)
                    return
                }
            } else {
                navigation.eta = ETA(meanS: 0, sdS: 0)
            }

            let leg = navigation.progress.legIndex
            let edge = navigation.route.legs.indices.contains(leg)
                ? navigation.route.legs[leg].edgeID : nil
            let maneuver = edge.flatMap { edge in
                navigation.maneuvers.firstIndex { $0.edgeIDs.contains(edge) }
            } ?? navigation.maneuverIndex
            let maneuverChanged = maneuver != navigation.maneuverIndex
            navigation.maneuverIndex = maneuver
            active.navigation = navigation
            set(.active(active))
            if maneuverChanged || active.arrived != wasArrived { await publishProgress() }
            if active.arrived, !wasArrived { await completeIfBothArrived() }
        case .proposed, .ended:
            break
        }
    }

    /// Arrival: routing-grade fixes within `arrivalRadiusM` of the meeting
    /// point, widened by the fix's own accuracy up to `arrivalMaxRadiusM`, for
    /// `arrivalDwellS`. A fix too poor to route from neither starts nor breaks
    /// the dwell: it says nothing about where the skier is.
    private func isDwelling(at rendezvous: RendezvousID, _ fix: Fix) -> Bool {
        guard FixQuality.isRoutingGrade(fix, now: deps.clock.now) else { return false }
        let radius = min(Self.arrivalMaxRadiusM, max(Self.arrivalRadiusM, fix.accuracyM))
        guard distanceToRendezvous(fix, rendezvous) <= radius else {
            nearSince = nil
            return false
        }
        let since = nearSince ?? fix.capturedAt
        nearSince = since
        return fix.capturedAt.timeIntervalSince(since) >= Self.arrivalDwellS
    }

    /// Having arrived, the skier is now clearly somewhere else: a
    /// routing-grade fix past `arrivalLeaveRadiusM`. A poor fix says nothing.
    private func hasLeft(_ rendezvous: RendezvousID, _ fix: Fix) -> Bool {
        guard FixQuality.isRoutingGrade(fix, now: deps.clock.now) else { return false }
        return distanceToRendezvous(fix, rendezvous) > Self.arrivalLeaveRadiusM
    }

    /// Keeps `Active.withinReach` in step with both skiers' latest
    /// routing-grade positions.
    func noteReach() {
        guard case .active(var active) = state else { return }
        let presence = freshPartnerPresence
        let near: Bool = {
            guard let mine = routingFix, let presence,
                  FixQuality.isRoutingGrade(presence.fix, now: deps.clock.now) else { return false }
            return Geo.haversineM(mine.coordinate, presence.fix.coordinate) <= Self.togetherReachM
        }()
        guard near != active.withinReach else { return }
        active.withinReach = near
        set(.active(active))
    }

    private func distanceToRendezvous(_ fix: Fix, _ rendezvous: RendezvousID) -> Double {
        guard let node = bundle.rendezvous(rendezvous).flatMap({ bundle.graph.nodes[$0.nodeID] })
        else { return .infinity }
        return Geo.haversineM(fix.coordinate, node.coordinate)
    }

    /// Both skiers have arrived: the meet is over. A current server completes
    /// it from the second `arrived` progress; an older one does not, so the
    /// phone that sees both asks too. Safe to race the other phone or the
    /// server: a meet already ended answers with its row or `invalid_state`,
    /// and either way the row is read. Nobody tapped anything, so a failure is
    /// only logged and the next progress tick tries again. The partner's
    /// arrival counts only while current (`arrivalFreshS`).
    func completeIfBothArrived() async {
        guard case .active(let active) = state, active.arrived, let partner = active.partner,
              partner.state == .arrived,
              deps.clock.now.timeIntervalSince(partner.fixAt) <= Self.arrivalFreshS,
              !completionSent, let meetID else { return }
        do {
            let row = try await deps.backend.meetEnd(meetID: meetID, reason: .arrived)
            completionSent = true
            await apply(row)
        } catch BackendError.notParticipant, BackendError.invalidState {
            completionSent = true
            await reconcile(quietly: true)
        } catch {
            if !Task.isCancelled { deps.log.info(.meet, "meet not completed yet: \(error)") }
        }
    }

    /// A status change: reroute if the remainder closed, and take a clearly
    /// better route if one opened. Without a routing-grade fix the route stands
    /// until the next fix, which `took` checks again: an old position must not
    /// end the meet.
    func reviewRoute() async {
        guard case .active(var active) = state, var navigation = active.navigation,
              !active.arrived, let fix = routingFix, let skier = routeSkier(at: fix) else { return }
        guard let eta = await Solving.recost(
            navigation.route, from: navigation.progress, skier: skier, solveInputs
        ) else {
            guard !Task.isCancelled else { return }
            await navigate(rerouted: true)
            return
        }
        navigation.eta = eta
        active.navigation = navigation
        set(.active(active))

        let candidate = await Solving.route(skier, to: active.meet.rendezvousID, solveInputs)
        guard !Task.isCancelled, case .active = state, case .success(let route) = candidate
        else { return }
        // An easiest way down gives way as soon as a route within the level opens.
        if navigation.route.easiestWayDown != nil, route.easiestWayDown == nil {
            await adopt(route, rerouted: true)
            return
        }
        let remaining = navigation.route.legs[min(navigation.progress.legIndex, navigation.route.legs.count)...]
        let decision = RouteSwitchPolicy.decide(
            current: eta, currentRemainingEdgeIDs: remaining.map(\.edgeID), candidate: route,
            secondsSinceLastSwitch: lastSwitchAt.map { deps.clock.now.timeIntervalSince($0) }
        )
        if case .switchRoute = decision { await adopt(route, rerouted: true) }
    }

    /// Queues this phone's progress. The outbox keeps only the latest per meet.
    func publishProgress() async {
        guard case .active(let active) = state, let meetID, let fix = lastFix else { return }
        let progressState: MeetProgressState = active.arrived
            ? .arrived : active.lost || active.navigation == nil ? .lost : .navigating
        guard publishedFixAt != fix.capturedAt || publishedState != progressState else { return }
        publishedFixAt = fix.capturedAt
        publishedState = progressState
        let navigation = active.navigation
        await deps.outbox.enqueue(
            key: "progress:\(meetID.uuidString)", user: me,
            .progress(.init(
                meetID: meetID, etaS: navigation.map { Self.seconds($0.eta.meanS) },
                etaSdS: navigation.map { Self.seconds($0.eta.sdS) },
                remainingM: navigation.map { Self.seconds($0.progress.remainingM) },
                state: progressState, fixAt: fix.capturedAt
            ))
        )
    }

    // MARK: Ending and recovery

    func end(_ reason: MeetEndRequest) async {
        guard let meetID, !isEnded else { return }
        do {
            await apply(try await deps.backend.meetEnd(meetID: meetID, reason: reason))
        } catch BackendError.notParticipant, BackendError.invalidState {
            await reconcile()
        } catch {
            if !Task.isCancelled { await fail(PowderMeetError(error)) }
        }
    }

    /// Reads the row when local state and the server disagree. A meet the server
    /// no longer shows ended while this phone was away. `quietly` is a read
    /// nobody asked for (the resync timer, a hint): a failure is only logged,
    /// and the next one tries again.
    func reconcile(quietly: Bool = false) async {
        guard let meetID, !isEnded else { return }
        do {
            if let row = try await deps.backend.meet(id: meetID) {
                await apply(row)
            } else {
                finish(Ended(meet: currentMeet, reason: nil, failure: .meet(.meetGone)))
            }
        } catch {
            guard !Task.isCancelled else { return }
            if quietly {
                deps.log.info(.meet, "meet not re-read: \(error)")
            } else {
                await fail(PowderMeetError(error))
            }
        }
    }

    func startResyncTimer() {
        let clock = deps.clock, inbox = inbox
        bag.start("resync") {
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.resyncIntervalS)
                } catch {
                    return
                }
                inbox.yield(.resync)
            }
        }
    }

    /// The user is leaving this meet's resort or signing out: tell the partner
    /// now rather than leave them waiting for the sweep. Called by `AppSession`
    /// once the session's tasks have ended. Best effort: leaving is never
    /// blocked, so a failure is only logged.
    public func leave() async {
        let backend = deps.backend
        do {
            switch state {
            case .proposed(let meet):
                _ = try await backend.meetEnd(meetID: meet.meetID, reason: .userCancelled)
            case .proposing(let proposing):
                guard let sent = proposing.replacing else { return }
                _ = try await backend.meetEnd(meetID: sent.meetID, reason: .userCancelled)
            case .incoming(let incoming):
                _ = try await backend.meetRespond(
                    meetID: incoming.meet.meetID, accept: false, inviteeEtaS: nil, inviteeEtaSdS: nil,
                    declineReason: .declinedByUser
                )
            case .active(let active):
                _ = try await backend.meetEnd(meetID: active.meet.meetID, reason: .partnerLeft)
            case .ended:
                return
            }
            deps.log.info(.meet, "meet ended on leaving")
        } catch {
            deps.log.notice(.meet, "meet not ended on leaving: \(error)")
        }
    }

    private var currentMeet: Meet? {
        switch state {
        case .proposed(let meet): meet
        case .incoming(let incoming): incoming.meet
        case .active(let active): active.meet
        case .ended(let ended): ended.meet
        case .proposing: nil
        }
    }

    func funnel(_ kind: String, _ props: [String: JSONValue]) async {
        await deps.outbox.enqueue(
            key: "event:\(UUID().uuidString)", user: me, .clientEvent(kind: kind, props: props)
        )
    }
}
