import Foundation
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI

extension MeetSession {
    // MARK: Proposing

    func loadPeople() async {
        let backend = deps.backend
        do {
            if myPace == nil { myPace = try await backend.paceModel(owner: me).flatMap(PaceModel.init) }
        } catch {
            // Routing works on the baseline; learned pace only sharpens it.
            deps.log.info(.meet, "own pace unavailable: \(error)")
        }
        guard case .proposing = state, partner == nil, !Task.isCancelled else { return }
        partnerReadAt = deps.clock.now
        do {
            guard let row = try await backend.profile(id: partnerID) else {
                await fail(.meet(.notFriends))
                return
            }
            let pace = try await backend.paceModel(owner: partnerID).flatMap(PaceModel.init)
            partner = (SkierProfile(row), pace)
            partnerName = row.displayName
        } catch {
            if !Task.isCancelled { await fail(PowderMeetError(error)) }
        }
    }

    /// Reads the partner's profile and pace again when the copy held is older
    /// than `partnerRefreshS`, so a level changed mid-session reaches the
    /// solver. The solve under way keeps the old copy; `partnerRead` solves
    /// again only if something changed. Stamped when tried, so a failed read
    /// waits as long as a good one.
    func refreshPartnerIfStale() {
        let now = deps.clock.now
        guard partner != nil,
              partnerReadAt.map({ now.timeIntervalSince($0) >= Self.partnerRefreshS }) ?? true else { return }
        partnerReadAt = now
        let backend = deps.backend, log = deps.log, inbox = inbox, partnerID = partnerID
        bag.start("partner-read") {
            do {
                guard let row = try await backend.profile(id: partnerID) else { return }
                let pace = try await backend.paceModel(owner: partnerID).flatMap(PaceModel.init)
                guard !Task.isCancelled else { return }
                inbox.yield(.partnerRead(MeetPrefetch.Person(
                    profile: SkierProfile(row), pace: pace, name: row.displayName, readAt: now
                )))
            } catch {
                if !Task.isCancelled { log.info(.meet, "partner not read again: \(error)") }
            }
        }
    }

    var solveInputs: Solving.Inputs {
        Solving.Inputs(bundle: bundle, status: status, conditions: conditions, at: deps.solveClock.now)
    }

    /// I-14: the last fix, while it is routing grade. An older one says where
    /// the skier was, not where they are, and takes the no-fix path.
    var routingFix: Fix? {
        guard let lastFix, FixQuality.isRoutingGrade(lastFix, now: deps.clock.now) else { return nil }
        return lastFix
    }

    /// The partner's last presence, while fresh enough to solve from (the
    /// same bound as `MeetPrefetch`).
    var freshPartnerPresence: Presence? {
        guard let partnerPresence,
              deps.clock.now.timeIntervalSince(partnerPresence.capturedAt) < MeetPrefetch.freshPresenceS
        else { return nil }
        return partnerPresence
    }

    func mySkier(at fix: Fix) -> SkierInput? {
        OriginResolver.origin(for: fix, in: bundle).map {
            SkierInput(id: me, profile: profile, pace: myPace, origin: $0)
        }
    }

    /// While on a route the origin is the position along it (I-11, I-12): two
    /// edges that run side by side must not swap under a noisy fix.
    func routeSkier(at fix: Fix) -> SkierInput? {
        guard case .active(let active) = state, let navigation = active.navigation,
              navigation.progress.state == .onRoute,
              navigation.route.legs.indices.contains(navigation.progress.legIndex),
              let edge = bundle.graph.edge(navigation.route.legs[navigation.progress.legIndex].edgeID)
        else { return mySkier(at: fix) }
        let fraction = navigation.progress.fractionAlongLeg
        let origin: RoutingOrigin = fraction <= 0
            ? .node(edge.from, fixAccuracyM: fix.accuracyM)
            : fraction >= 1
                ? .node(edge.to, fixAccuracyM: fix.accuracyM)
                : .onEdge(edge.id, fraction: fraction, fixAccuracyM: fix.accuracyM)
        return SkierInput(id: me, profile: profile, pace: myPace, origin: origin)
    }

    /// Starts a solve on the current inputs. A result for older inputs is dropped
    /// by the version check in `.solved`.
    func requestSolve() {
        guard case .proposing(var proposing) = state, !proposing.sending, let partner else { return }
        refreshPartnerIfStale()
        inputVersion += 1
        guard let fix = routingFix, let mine = mySkier(at: fix) else {
            proposing.options = nil
            proposing.failure = .routing(.originNotOnGraph(me))
            set(.proposing(proposing))
            return
        }
        guard let presence = freshPartnerPresence,
              let theirOrigin = OriginResolver.origin(for: presence.fix, in: bundle) else {
            proposing.options = nil
            proposing.failure = .routing(.originNotOnGraph(partnerID))
            set(.proposing(proposing))
            return
        }
        let theirs = SkierInput(
            id: partnerID, profile: partner.profile, pace: partner.pace, origin: theirOrigin
        )
        var asked = Solving.input(solveInputs, mine, theirs)
        asked.options.requested = proposing.requested
        let input = asked
        let version = inputVersion, cache = cache, inbox = inbox
        bag.start("solve") {
            let started = ContinuousClock.now
            let result = cache.value(for: input) { MeetSolver.solve(input) }
            guard !Task.isCancelled else { return }
            let elapsed = ContinuousClock.now - started
            inbox.yield(.solved(
                version: version, result: result,
                milliseconds: Int(elapsed.components.seconds * 1_000)
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            ))
        }
    }

    func sendProposal() async {
        guard case .proposing(var proposing) = state, !proposing.sending,
              let options = proposing.options, let picked = proposing.picked,
              options.options.indices.contains(picked) else { return }
        let option = options.options[picked]
        proposing.sending = true
        proposing.failure = nil
        set(.proposing(proposing))
        // No newer solve may replace the options the proposal was built from.
        bag.cancel("solve")
        inputVersion += 1
        let backend = deps.backend, partnerID = partnerID, bundle = bundle
        func propose(_ id: UUID, supersedes: UUID?) async throws -> Meet {
            try await backend.meetPropose(
                meetID: id, invitee: partnerID, resortID: bundle.resortID,
                rendezvousID: option.rendezvous, bundleID: bundle.id,
                proposerEtaS: Self.seconds(option.routes.0.eta.meanS),
                proposerEtaSdS: Self.seconds(option.routes.0.eta.sdS),
                supersedes: supersedes
            )
        }
        do {
            var meet = try await propose(proposalID, supersedes: proposing.replacing?.meetID)
            // An earlier send that seemed to fail had reached the server with
            // another option: the id is idempotent, so its row came back. The
            // option picked now replaces it.
            if meet.rendezvousID != option.rendezvous, meet.status == .proposed, meet.proposerID == me {
                proposalID = UUID()
                meet = try await propose(proposalID, supersedes: meet.meetID)
            }
            await funnel(proposing.replacing == nil ? "meet.proposed" : "meet.superseded", [:])
            // A replacement is a new row: follow it from here on.
            guard case .proposing = state else { return }
            meetID = meet.meetID
            await apply(meet)
        } catch {
            // The old proposal was accepted while this one was being sent.
            guard case .proposing = state else { return }
            if !Task.isCancelled { await fail(PowderMeetError(error)) }
        }
    }

    static func seconds(_ value: Double) -> Int {
        value.isFinite ? max(0, Int(value.rounded())) : 0
    }

    // MARK: Incoming

    /// Step 2 and 3 of "Respond": route to the rendezvous, and decline for the
    /// user when the mountain rules it out.
    func computeIncomingRoute() async {
        guard case .incoming(var incoming) = state else { return }
        guard let fix = routingFix, let skier = mySkier(at: fix) else {
            incoming.ownRoute = nil
            incoming.failure = .routing(.originNotOnGraph(me))
            set(.incoming(incoming))
            return
        }
        let result = await Solving.route(skier, to: incoming.meet.rendezvousID, solveInputs)
        guard !Task.isCancelled, case .incoming = state else { return }
        switch result {
        case .success(let route):
            incoming.ownRoute = route
            incoming.failure = nil
            incomingRoutedFrom = fix.coordinate
            set(.incoming(incoming))
        case .failure(.noRendezvousReachable), .failure(.abilityBlocksAll), .failure(.liftDeadlineRisk):
            await respond(accept: false, reason: .declinedCannotRoute)
        case .failure(let failure):
            // Not knowing where this phone is, or a bundle that lacks the
            // rendezvous, is not a reason to decline for the user.
            incoming.ownRoute = nil
            incoming.failure = .routing(failure)
            set(.incoming(incoming))
        }
    }

    func respond(accept: Bool, reason: MeetDeclineReason?) async {
        guard case .incoming(let incoming) = state else { return }
        // GPS lost since the route was worked out: the proposer must not be
        // shown a time from where the skier was. The first new fix routes.
        let route = accept && routingFix != nil ? incoming.ownRoute : nil
        do {
            let meet = try await deps.backend.meetRespond(
                meetID: incoming.meet.meetID, accept: accept,
                inviteeEtaS: route.map { Self.seconds($0.eta.meanS) },
                inviteeEtaSdS: route.map { Self.seconds($0.eta.sdS) },
                declineReason: accept ? nil : reason ?? .declinedByUser
            )
            await funnel(accept ? "meet.accepted" : "meet.declined", [:])
            await apply(meet)
        } catch BackendError.meetNotProposed, BackendError.meetExpired, BackendError.notParticipant {
            // D2: the proposal went away first. The row says how.
            await reconcile()
            // Past its time but not yet swept, the row still reads as proposed:
            // without a word the tap would seem to do nothing.
            if case .incoming = state { await fail(.meet(.meetGone)) }
        } catch {
            if !Task.isCancelled { await fail(PowderMeetError(error)) }
        }
    }
}
