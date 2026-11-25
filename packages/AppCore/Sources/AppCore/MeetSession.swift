import Foundation
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI

/// One meet on this phone, from the first solve to a terminal state
/// (`specs/03-PROTOCOL.md` section 4, `specs/07-CLIENT.md` section 1).
///
/// The server owns the meet row; this session owns only the phone's own route.
/// Every change of state happens in `handle(_:)`, which the run loop calls one
/// event at a time, so an await inside a transition cannot interleave with
/// another transition. Effects are named tasks in `bag`; leaving the session
/// cancels them.
public actor MeetSession {
    public enum Start: Sendable {
        /// The user wants to meet this friend: solve, pick, send.
        case propose(friend: UUID)
        /// A meet the server already has: an incoming proposal, or recovery after
        /// a relaunch through `meet_current()`.
        case adopt(Meet)
    }

    /// What the resort knows when the session starts; later changes arrive as events.
    public struct Context: Sendable {
        public var profile: Profile
        public var bundle: ResortBundle
        public var status: ResortStatus?
        public var conditions: Conditions?
        public var lastFix: Fix?
        public var partnerPresence: Presence?
        /// What the resort prefetched (`MeetPrefetch`): options shown before the
        /// first solve returns, and the partner's profile and both paces, which
        /// then need no read.
        public var seed: MeetPrefetch.Seed?

        public init(
            profile: Profile, bundle: ResortBundle, status: ResortStatus? = nil,
            conditions: Conditions? = nil, lastFix: Fix? = nil, partnerPresence: Presence? = nil,
            seed: MeetPrefetch.Seed? = nil
        ) {
            self.profile = profile
            self.bundle = bundle
            self.status = status
            self.conditions = conditions
            self.lastFix = lastFix
            self.partnerPresence = partnerPresence
            self.seed = seed
        }
    }

    public struct Proposing: Sendable, Hashable {
        public var friend: UUID
        /// The sent proposal this one will replace (`meet_propose(supersedes:)`).
        /// It stays live until the replacement is sent; backing out returns to it.
        public var replacing: Meet?
        /// Nil while solving or when the solve failed.
        public var options: MeetOptions?
        public var picked: Int?
        public var sending = false
        public var failure: PowderMeetError?
        /// A meeting place the user asked for by name; the solve adds it to
        /// the options when both skiers can reach it.
        public var requested: RendezvousID?
        /// The solve came back without the requested place: one of the two
        /// cannot get there.
        public var requestedUnreachable = false
    }

    public struct Incoming: Sendable, Hashable {
        public var meet: Meet
        /// Nil until this phone has a fix it can route from.
        public var ownRoute: Route?
        public var failure: PowderMeetError?
    }

    public struct Navigation: Sendable, Hashable {
        public var route: Route
        public var progress: RouteProgressValue
        /// Re-priced remainder; the variance is never dropped (I-10).
        public var eta: ETA
        public var maneuvers: [Maneuver]
        public var maneuverIndex: Int

        /// What is left of the step under way, for the pinned instruction:
        /// the route's remainder less the steps after this one.
        public var currentStepRemainingM: Double? {
            guard maneuvers.indices.contains(maneuverIndex) else { return nil }
            let after = maneuvers[(maneuverIndex + 1)...].reduce(0) { $0 + $1.lengthM }
            return min(maneuvers[maneuverIndex].lengthM, max(0, progress.remainingM - after))
        }
    }

    public struct Active: Sendable, Hashable {
        public var meet: Meet
        /// Nil until a routing-grade fix places this phone on the graph.
        public var navigation: Navigation?
        public var partner: MeetProgress?
        public var arrived = false
        /// Both phones' latest routing-grade fixes are within
        /// `togetherReachM` of each other: an end now is most likely a meet-up
        /// GPS could not confirm (a lodge, a poor fix).
        public var withinReach = false
        /// The last fix could not be placed on the graph.
        public var lost = false
        public var failure: PowderMeetError?
    }

    public struct Ended: Sendable, Hashable {
        /// Nil when the user backed out before sending a proposal.
        public var meet: Meet?
        public var reason: MeetEndReason?
        public var failure: PowderMeetError?
        /// The meet was active with both skiers there or within
        /// `togetherReachM` when it ended, so an end by hand reads as met up.
        public var wereTogether = false
    }

    public enum State: Sendable, Hashable {
        case proposing(Proposing)
        /// Outgoing, waiting for the invitee.
        case proposed(Meet)
        case incoming(Incoming)
        case active(Active)
        case ended(Ended)
    }

    public enum Event: Sendable {
        // Intents.
        case optionPicked(Int)
        /// Send the picked option as a proposal.
        case sent
        /// Solve again to replace the proposal already sent.
        case changeProposal
        case accepted
        case declined(MeetDeclineReason)
        case userEnded
        case retry
        // Inputs.
        case proposalUpdated(Meet)
        case fix(Fix)
        case statusChanged(ResortStatus)
        case conditionsChanged(Conditions)
        /// The user saved their profile (level, hardest run, avoid, gear):
        /// the options re-solve, an incoming request re-routes.
        case profileChanged(Profile)
        case progressFromPartner(MeetProgress)
        case partnerPresence(Presence)
        /// `meet_current()` returned null while this session still has a meet.
        case serverHasNoMeet
        /// Re-read the row (and the partner's progress while active): events
        /// are hints, and a lost `meet.updated` must not strand this phone
        /// (protocol section 3). Sent on reconnect and every `resyncIntervalS`.
        case resync
        // Results of the session's own work.
        /// The user searched for a meeting place and chose one (nil takes it
        /// back): the options are solved again with it among them.
        case placeRequested(RendezvousID?)
        case solved(version: Int, result: Result<MeetOptions, SolveFailure>, milliseconds: Int)
        case rerouted(Route)
        case progressTick
        /// The partner's route, solved here from their presence fix at `anchor`,
        /// for their ghost.
        case partnerRouted(Route, anchor: Date, profile: SkierProfile, pace: PaceModel?)
        /// The partner's profile and pace, read again because the copy held
        /// had aged past `partnerRefreshS`.
        case partnerRead(MeetPrefetch.Person)
    }

    /// Within this distance of the rendezvous node for `arrivalDwellS`, on
    /// routing-grade fixes, is arrival: the one meaning of `arrived`.
    public static let arrivalRadiusM = 30.0
    /// A fix's own accuracy widens the radius up to this, so a good but not
    /// perfect GPS can still arrive.
    public static let arrivalMaxRadiusM = 50.0
    public static let arrivalDwellS = 10.0
    /// A skier who arrived and is then this far from the meeting point has
    /// left it (a lap, the lodge next door): no longer `arrived`, so a meet
    /// never completes with one skier away.
    public static let arrivalLeaveRadiusM = 100.0
    /// The partner's `arrived` counts toward "both there" only while its fix
    /// is at most this old: a skier who arrived, lost service and left keeps
    /// `arrived` on the server. A phone still at the meeting point repeats its
    /// fix every 45 s, so it stays inside the bound. The server completes a
    /// meet on the same bound (migration 0028).
    public static let arrivalFreshS = 120.0
    /// Two skiers this close may well be together where GPS cannot tell.
    /// Above, an ended meet says only how it ended.
    public static let togetherReachM = 150.0
    /// The partner's level and pace can change during a session: a solve that
    /// finds its copy older than this reads them again.
    public static let partnerRefreshS = 120.0
    public static let progressIntervalS = 10.0
    /// The partner's ghost route is solved again from a presence fix at least
    /// this much newer than the one it was solved from.
    public static let partnerGhostRefreshS = 15.0
    /// While a meet row exists and has not ended, it is read again this often,
    /// in case a status change never arrived.
    public static let resyncIntervalS = 60.0

    public nonisolated let partnerID: UUID
    public internal(set) var state: State
    /// The server's id once a meet row exists.
    public internal(set) var meetID: UUID?
    /// While the meet is active, where both skiers will be when the timeline
    /// is scrubbed forward; nil otherwise.
    public internal(set) var ghostPlan: GhostPlan?

    let deps: Dependencies
    let me: UUID
    var profile: SkierProfile
    /// The next solve answers a changed profile: its pick starts at the top.
    private var repick = false
    /// The next solve answers a place the user just asked for: its page is shown.
    private var showRequested = false
    let bundle: ResortBundle
    var status: ResortStatus?
    var conditions: Conditions?
    var lastFix: Fix?
    var partnerPresence: Presence?
    var myPace: PaceModel?
    var partner: (profile: SkierProfile, pace: PaceModel?)?
    /// When `partner` was last read, or a read of it was last tried.
    var partnerReadAt: Date?
    /// The partner's display name, so a failed solve can say who it is about.
    var partnerName: String?

    /// Proposing the same option twice must reach the same row; a replacement
    /// is a new row, so it gets a new id.
    var proposalID = UUID()
    let cache = SolveCache()
    /// The one version check: a solve result applies only to the inputs it ran on.
    var inputVersion = 0
    var lastSwitchAt: Date?
    var nearSince: Date?
    /// Where this phone stood when an invitation's route was worked out: a
    /// skier who has moved on since gets a new one before they accept.
    var incomingRoutedFrom: Coordinate?
    /// `meet_end(arrived)` went through, or the meet is known to be over.
    var completionSent = false
    var publishedFixAt: Date?
    var publishedState: MeetProgressState?
    var ownProjection: RouteProjection?
    var partnerTrack: GhostPlan.Track?
    /// Capture time of the partner presence the ghost route was last asked for.
    var partnerGhostFrom: Date?
    let ghostChanges = Multicast<GhostPlan?>()

    var bag: TaskBag
    private let changes = Multicast<State>()
    private let mailbox: AsyncStream<Event>
    let inbox: AsyncStream<Event>.Continuation

    public init(start: Start, context: Context, dependencies: Dependencies) {
        deps = dependencies
        me = context.profile.id
        profile = SkierProfile(context.profile)
        bundle = context.bundle
        status = context.status
        conditions = context.conditions
        lastFix = context.lastFix
        partnerPresence = context.partnerPresence
        myPace = context.seed?.myPace
        partner = context.seed?.partner.map { ($0.profile, $0.pace) }
        partnerReadAt = context.seed?.partner?.readAt
        partnerName = context.seed?.partner?.name
        bag = TaskBag(census: dependencies.census)
        (mailbox, inbox) = AsyncStream.makeStream(of: Event.self)
        switch start {
        case .propose(let friend):
            partnerID = friend
            // Prefetched options show at once; the exact solve in `begin()`
            // replaces them.
            let seeded = context.seed?.options
            state = .proposing(Proposing(
                friend: friend, options: seeded, picked: seeded.flatMap { $0.options.isEmpty ? nil : 0 }
            ))
        case .adopt(let meet):
            partnerID = meet.partner(of: context.profile.id)
            meetID = meet.meetID
            state = switch meet.status {
            case .proposed where meet.proposerID == context.profile.id: .proposed(meet)
            case .proposed: .incoming(Incoming(meet: meet))
            case .active: .active(Active(meet: meet))
            default: .ended(Ended(meet: meet, reason: meet.endReason))
            }
        }
    }

    /// Posts an event. Safe from any thread; events are handled in order.
    public nonisolated func send(_ event: Event) {
        inbox.yield(event)
    }

    /// The current state, then every later one.
    public func states() -> AsyncStream<State> {
        changes.stream(initial: state)
    }

    /// The ghost plan now, then each change (a fix moves the user's anchor).
    /// Hold the latest and ask it `ghosts(at:)` while scrubbing.
    public func ghostPlans() -> AsyncStream<GhostPlan?> { ghostChanges.stream(initial: ghostPlan) }

    /// Each skier's ghost at a future instant; empty outside an active meet.
    public func ghosts(at instant: Date) -> [GhostPlan.Ghost] { ghostPlan?.ghosts(at: instant) ?? [] }

    public var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// Runs the meet until it ends or the task is cancelled. Cancellation is the
    /// teardown: effects are cancelled and awaited before this returns.
    public func run() async {
        startResyncTimer()
        await begin()
        if !isEnded {
            for await event in mailbox {
                await handle(event)
                if isEnded || Task.isCancelled { break }
            }
        }
        inbox.finish()
        for task in bag.cancelAll() { await task.value }
    }

    private func begin() async {
        await loadPeople()
        guard !Task.isCancelled else { return }
        switch state {
        case .proposing:
            requestSolve()
        case .incoming:
            await computeIncomingRoute()
        case .active:
            startActiveEffects()
            await navigate(rerouted: false)
        case .proposed, .ended:
            break
        }
    }

    // MARK: Transitions

    private func handle(_ event: Event) async {
        switch event {
        case .optionPicked(let index):
            guard case .proposing(var proposing) = state, !proposing.sending,
                  let count = proposing.options?.options.count, (0..<count).contains(index)
            else { return }
            proposing.picked = index
            set(.proposing(proposing))

        case .placeRequested(let place):
            guard case .proposing(var proposing) = state, !proposing.sending else { return }
            proposing.requested = place
            proposing.requestedUnreachable = false
            set(.proposing(proposing))
            showRequested = place != nil
            requestSolve()

        case .sent:
            await sendProposal()

        case .changeProposal:
            guard case .proposed(let sent) = state, sent.proposerID == me else { return }
            proposalID = UUID()
            set(.proposing(Proposing(friend: partnerID, replacing: sent)))
            await loadPeople()
            requestSolve()

        case .accepted:
            guard case .incoming(let incoming) = state else { return }
            if incoming.ownRoute == nil { await computeIncomingRoute() }
            guard case .incoming(let ready) = state, ready.ownRoute != nil else { return }
            await respond(accept: true, reason: nil)

        case .declined(let reason):
            await respond(accept: false, reason: reason)

        case .userEnded:
            switch state {
            case .proposing(let proposing):
                if let sent = proposing.replacing {
                    // The sent proposal is still live: keep it.
                    bag.cancel("solve")
                    inputVersion += 1
                    set(.proposed(sent))
                } else {
                    finish(Ended(meet: nil, reason: nil))
                }
            case .proposed, .active: await end(.userCancelled)
            case .incoming: await respond(accept: false, reason: .declinedByUser)
            case .ended: break
            }

        case .retry:
            guard case .proposing = state else { return }
            await loadPeople()
            requestSolve()

        case .proposalUpdated(let meet):
            await apply(meet)

        case .fix(let fix):
            await took(fix)

        case .statusChanged(let value):
            status = value
            switch state {
            case .proposing: requestSolve()
            case .incoming: await computeIncomingRoute()
            case .active: await reviewRoute()
            case .proposed, .ended: break
            }

        case .conditionsChanged(let value):
            conditions = value
            if case .proposing = state { requestSolve() }

        case .profileChanged(let row):
            let updated = SkierProfile(row)
            // A photo or name change saves the profile too; only what routing
            // reads starts a new solve.
            guard updated != profile else { return }
            profile = updated
            switch state {
            case .proposing:
                repick = true
                requestSolve()
            case .incoming: await computeIncomingRoute()
            case .proposed, .active, .ended: break
            }

        case .progressFromPartner(let progress):
            guard progress.meetID == meetID, progress.userID == partnerID else { return }
            guard case .active(var active) = state else {
                // The partner is navigating a meet this phone does not know is
                // active: the `meet.updated` that said so was lost.
                if !isEnded { await reconcile(quietly: true) }
                return
            }
            // I-19: receivers drop non-monotonic progress.
            if let known = active.partner, progress.fixAt <= known.fixAt { return }
            active.partner = progress
            set(.active(active))
            await completeIfBothArrived()

        case .partnerPresence(let presence):
            guard presence.userID == partnerID else { return }
            if let known = partnerPresence, presence.capturedAt <= known.capturedAt { return }
            partnerPresence = presence
            noteReach()
            if case .proposing(let proposing) = state, proposing.options == nil { requestSolve() }
            if case .active(let active) = state { requestPartnerGhost(to: active.meet.rendezvousID) }

        case .partnerRouted(let route, let anchor, let profile, let pace):
            guard case .active = state else { return }
            if partner == nil {
                partner = (profile, pace)
                partnerReadAt = deps.clock.now
            }
            if let known = partnerTrack, anchor <= known.anchor { return }
            guard let projection = RouteProjection(route: route, graph: bundle.graph) else { return }
            partnerTrack = GhostPlan.Track(
                userID: partnerID, isSelf: false, projection: projection, anchor: anchor, anchorRouteTimeS: 0
            )
            updateGhosts()

        case .serverHasNoMeet:
            guard meetID != nil else { return }
            await reconcile()

        case .resync:
            guard meetID != nil, !isEnded else { return }
            await reconcile(quietly: true)
            if case .active = state { readPartnerProgress() }

        case .solved(let version, let result, let milliseconds):
            guard version == inputVersion, case .proposing(var proposing) = state else { return }
            switch result {
            case .success(let options):
                proposing.options = options
                // After a profile change the answer is new: start on its best.
                proposing.picked = options.options.isEmpty
                    ? nil : repick ? 0 : min(proposing.picked ?? 0, options.options.count - 1)
                repick = false
                if let wanted = proposing.requested {
                    if let index = options.options.firstIndex(where: { $0.rendezvous == wanted }) {
                        // Asked for just now: its page comes up.
                        if showRequested { proposing.picked = index }
                        proposing.requestedUnreachable = false
                    } else {
                        proposing.requestedUnreachable = true
                    }
                }
                showRequested = false
                proposing.failure = nil
            case .failure(let failure):
                proposing.options = nil
                proposing.picked = nil
                proposing.failure = .routing(failure, me: me, partnerName: partnerName)
            }
            set(.proposing(proposing))
            await funnel("solve", ["ms": .number(Double(milliseconds))])

        case .rerouted(let route):
            guard case .active = state else { return }
            await adopt(route, rerouted: true)

        case .partnerRead(let person):
            partnerName = person.name ?? partnerName
            let changed = partner.map { $0.profile != person.profile || $0.pace != person.pace } ?? true
            partner = (person.profile, person.pace)
            guard changed else { return }
            switch state {
            case .proposing: requestSolve()
            case .active(let active):
                partnerGhostFrom = nil
                requestPartnerGhost(to: active.meet.rendezvousID)
            case .proposed, .incoming, .ended: break
            }

        case .progressTick:
            await publishProgress()
            // A completion that failed (offline, say) is tried again.
            await completeIfBothArrived()
        }
    }

    /// The server's row is the truth: every RPC result and `meet.updated` lands here.
    func apply(_ meet: Meet) async {
        guard meet.involves(me), meetID == nil || meetID == meet.meetID, !isEnded else { return }
        // A status only moves forward (protocol section 1) and the row carries
        // no version, so a proposed row reaching an active meet is an older read
        // or a replayed event.
        if case .active = state, meet.status == .proposed { return }
        if await applyWhileReplacing(meet) { return }
        if await followReplacement(meet) { return }
        meetID = meet.meetID
        switch meet.status {
        case .proposed:
            if meet.proposerID == me {
                set(.proposed(meet))
            } else if case .incoming(var incoming) = state {
                incoming.meet = meet
                set(.incoming(incoming))
            } else {
                set(.incoming(Incoming(meet: meet)))
                await computeIncomingRoute()
            }
        case .active:
            if case .active(var active) = state {
                active.meet = meet
                set(.active(active))
                return
            }
            // The route shown on the invitation carries into navigation
            // unchanged, unless GPS has been lost since: its time is from
            // where the skier was, and the first new fix routes again.
            var carried: Route?
            if case .incoming(let incoming) = state, routingFix != nil { carried = incoming.ownRoute }
            set(.active(Active(meet: meet)))
            await funnel("meet.active", [:])
            startActiveEffects()
            if let carried {
                await adopt(carried, rerouted: false)
            } else {
                await navigate(rerouted: false)
            }
        case .completed, .declined, .cancelled, .expired, .invalidated:
            finish(Ended(meet: meet, reason: meet.endReason))
        }
    }

    /// The proposer is choosing a replacement for `meet`. True when the row
    /// was handled here.
    private func applyWhileReplacing(_ meet: Meet) async -> Bool {
        guard case .proposing(var proposing) = state, let sent = proposing.replacing,
              sent.meetID == meet.meetID else { return false }
        switch meet.status {
        case .proposed:
            proposing.replacing = meet
            set(.proposing(proposing))
            return true
        case .active:
            // Accepted before the replacement went out: that meet is on.
            return false
        case .completed, .declined, .cancelled, .expired, .invalidated:
            // Our own replacement ends it; the new row follows from the RPC.
            if meet.endReason == .superseded { return true }
            // Declined or expired meanwhile: what is being picked becomes a
            // fresh proposal rather than a replacement.
            proposing.replacing = nil
            meetID = nil
            set(.proposing(proposing))
            return true
        }
    }

    /// The invitee's proposal was replaced: show the replacement in its place,
    /// so they see one proposal (D8). True when the session moved to it.
    private func followReplacement(_ meet: Meet) async -> Bool {
        guard meet.inviteeID == me, meet.endReason == .superseded,
              let next = meet.supersededBy, case .incoming = state else { return false }
        do {
            guard let row = try await deps.backend.meet(id: next), row.status == .proposed,
                  row.involves(me), !Task.isCancelled else { return false }
            meetID = row.meetID
            set(.incoming(Incoming(meet: row)))
            await computeIncomingRoute()
            return true
        } catch {
            // The replacement still arrives as `meet.proposed`; until then this
            // one ends as superseded.
            deps.log.info(.meet, "replacement proposal unavailable: \(error)")
            return false
        }
    }

    func finish(_ ended: Ended) {
        guard !isEnded else { return }
        var ended = ended
        if case .active(let active) = state {
            // Together means near each other, or both at the meeting point:
            // one skier there alone is not a meet-up.
            ended.wereTogether = active.withinReach
                || (active.arrived && active.partner?.state == .arrived)
        }
        set(.ended(ended))
        let reason = ended.reason?.rawValue ?? "abandoned"
        deps.log.info(.meet, "meet ended: \(reason)")
        if ended.meet != nil {
            let outbox = deps.outbox, user = me
            bag.start("funnel-end") {
                await outbox.enqueue(
                    key: "event:\(UUID().uuidString)", user: user,
                    .clientEvent(kind: "meet.ended", props: ["reason": .string(reason)])
                )
            }
        }
    }

    func set(_ new: State) {
        guard new != state else { return }
        state = new
        changes.send(new)
        updateGhosts()
    }

    /// Shows a failure where the current step renders it, and as a toast when
    /// waiting may fix it.
    func fail(_ error: PowderMeetError) async {
        switch state {
        case .proposing(var proposing):
            proposing.sending = false
            proposing.failure = error
            set(.proposing(proposing))
        case .incoming(var incoming):
            incoming.failure = error
            set(.incoming(incoming))
        case .active(var active):
            active.failure = error
            set(.active(active))
        case .proposed, .ended:
            break
        }
        deps.log.error(.meet, "meet step failed: \(error)")
        if error.isTransient || !rendersFailureInline { await deps.toasts.post(error) }
    }

    private var rendersFailureInline: Bool {
        if case .proposed = state { return false }
        return true
    }
}
