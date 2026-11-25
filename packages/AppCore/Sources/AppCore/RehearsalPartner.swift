import Foundation
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI
import Synchronization

/// A friend's phone the app plays itself, for developer testing's dev people
/// (`specs/07-CLIENT.md` section 8). It stands where it
/// is put and reports that as a still phone does. It accepts every meet it is
/// invited to after a few seconds, with its own estimate; then it travels its
/// route to the meeting point at several times real speed, and moves this phone
/// along a route of its own too (when `moveMe` allows it), so propose, accept,
/// navigate and arrive can all be watched on one phone, on any mountain.
///
/// The phone is a `FakeBackendClient`: the demo's server, or the developer
/// sandbox's, never the live one.
public final class RehearsalPartner: Sendable {
    public struct Timing: Sendable {
        /// How long the partner takes to accept.
        public var answersAfterS: Double
        /// How much faster than the solver's estimate both skiers travel.
        public var speedup: Double
        public var tickS: Double
        /// A partner standing still reports as often as a real phone does, so
        /// their marker and chip stay live.
        public var idleReportS: Double

        public init(
            answersAfterS: Double = 4, speedup: Double = 6, tickS: Double = 2,
            idleReportS: Double = ResortSession.stillIntervalS
        ) {
            self.answersAfterS = answersAfterS
            self.speedup = speedup
            self.tickS = tickS
            self.idleReportS = idleReportS
        }
    }

    /// The mountain the partner routes on, with the status and weather it is
    /// priced with.
    public struct Stage: Sendable {
        public var bundle: ResortBundle
        public var status: ResortStatus?
        public var conditions: Conditions?

        public init(bundle: ResortBundle, status: ResortStatus? = nil, conditions: Conditions? = nil) {
            self.bundle = bundle
            self.status = status
            self.conditions = conditions
        }
    }

    public let id: UUID
    private let me: UUID
    private let phone: FakeBackendClient
    private let solveClock: any Clock
    private let timing: Timing
    private let log: PMLog
    private let whereAmI: @Sendable () -> Coordinate?
    private let moveMe: @Sendable (Coordinate) -> Void
    private let profileOf: @Sendable (UUID) -> SkierProfile

    private struct State {
        var stage: Stage?
        var place: Coordinate?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// - Parameters:
    ///   - me: this phone's user, whose route the partner works out as well.
    ///   - solveClock: the instant routes are priced at, as the meet's own solves.
    ///   - whereAmI: this phone's position when a meet is accepted.
    ///   - moveMe: called with this phone's position along its route while both
    ///     travel; it decides whether to move anything.
    ///   - profileOf: how the partner or this phone's user skis, so each route
    ///     keeps to that skier's own limits, as the meet's own solve does.
    public init(
        id: UUID, me: UUID, phone: FakeBackendClient, solveClock: any Clock, timing: Timing = Timing(),
        log: PMLog, whereAmI: @escaping @Sendable () -> Coordinate?,
        moveMe: @escaping @Sendable (Coordinate) -> Void,
        profileOf: @escaping @Sendable (UUID) -> SkierProfile
    ) {
        self.id = id
        self.me = me
        self.phone = phone
        self.solveClock = solveClock
        self.timing = timing
        self.log = log
        self.whereAmI = whereAmI
        self.moveMe = moveMe
        self.profileOf = profileOf
    }

    deinit {
        stop()
    }

    /// Where the partner stands, or nil before it is put anywhere.
    public var place: Coordinate? { state.withLock { $0.place } }

    public var stage: Stage? { state.withLock { $0.stage } }

    public func setStage(_ stage: Stage?) {
        state.withLock { $0.stage = stage }
    }

    /// Stands here and says so at once. Nil stops the idle reports.
    public func stand(at coordinate: Coordinate?) async {
        state.withLock { $0.place = coordinate }
        if let coordinate { await report(coordinate) }
    }

    /// Starts answering invitations and reporting while still.
    public func start() {
        let tasks = [answering(), reportingWhileStill()]
        state.withLock { $0.tasks.append(contentsOf: tasks) }
    }

    public func stop() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            defer { state.tasks = [] }
            return state.tasks
        }
        for task in tasks { task.cancel() }
    }

    // MARK: Behaviour

    private func answering() -> Task<Void, Never> {
        let phone = phone, id = id, me = me, timing = timing, log = log
        return Task { [weak self] in
            var travel: Task<Void, Never>?
            defer { travel?.cancel() }
            do {
                for await event in try await phone.events() {
                    switch event {
                    case .meetProposed(let meet) where meet.inviteeID == id:
                        try await Task.sleep(for: .seconds(timing.answersAfterS))
                        let theirs = self?.route(for: id, from: self?.place, to: meet.rendezvousID)
                        let mine = self?.route(for: me, from: self?.whereAmI(), to: meet.rendezvousID)
                        do {
                            _ = try await phone.meetRespond(
                                meetID: meet.meetID, accept: true,
                                inviteeEtaS: theirs.map { Int($0.eta.meanS) } ?? meet.proposerEtaS ?? 300,
                                inviteeEtaSdS: theirs.map { Int($0.eta.sdS) } ?? meet.proposerEtaSdS ?? 60,
                                declineReason: nil
                            )
                        } catch {
                            // Withdrawn or replaced before the answer: wait for the next one.
                            log.info(.meet, "rehearsal: answer refused: \(error)")
                            continue
                        }
                        travel?.cancel()
                        travel = Task { [weak self] in
                            await self?.travel(meetID: meet.meetID, to: meet.rendezvousID, mine: mine, theirs: theirs)
                        }
                    case .meetUpdated(let meet) where meet.status.isTerminal:
                        travel?.cancel()
                        travel = nil
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled { log.error(.meet, "rehearsal: partner stopped: \(error)") }
            }
        }
    }

    private func reportingWhileStill() -> Task<Void, Never> {
        let interval = timing.idleReportS
        return Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, let place = self.place else { continue }
                await self.report(place)
            }
        }
    }

    private func report(_ place: Coordinate) async {
        guard let resortID = state.withLock({ $0.stage?.bundle.resortID }) else { return }
        do {
            try await phone.presenceUpdate(PresenceUpdate(
                resortID: resortID, lon: place.lon, lat: place.lat, accuracyM: 8, capturedAt: Date()
            ))
        } catch {
            if !Task.isCancelled { log.info(.location, "rehearsal: report refused: \(error)") }
        }
    }

    /// The route `user` standing at `here` would take.
    private func route(for user: UUID, from here: Coordinate?, to rendezvous: RendezvousID) -> Route? {
        guard let stage = state.withLock({ $0.stage }), let here,
              let node = stage.bundle.graph.nodes.values.min(by: {
                  Geo.haversineM(here, $0.coordinate) < Geo.haversineM(here, $1.coordinate)
              })
        else { return nil }
        let skier = SkierInput(id: user, profile: profileOf(user), origin: .node(node.id))
        let input = SolveInput(
            bundle: stage.bundle, status: stage.status, conditions: stage.conditions,
            at: solveClock.now, skiers: (skier, skier)
        )
        if case .success(let route) = MeetSolver.route(for: skier, to: rendezvous, in: input) {
            return route
        }
        return nil
    }

    /// Where a skier is `elapsedS` route-seconds into `route`.
    private func position(on route: Route, at elapsedS: Double) -> Coordinate? {
        guard let bundle = state.withLock({ $0.stage?.bundle }), let last = route.legs.last else { return nil }
        let leg = route.legs.first { elapsedS < $0.exitS } ?? last
        guard let edge = bundle.graph.edge(leg.edgeID) else { return nil }
        let span = max(leg.exitS - leg.enterS, 0.001)
        let along = min(max((elapsedS - leg.enterS) / span, 0), 1)
        return Geo.interpolate(
            along: edge.coordinates, fraction: leg.startFraction + (1 - leg.startFraction) * along)
    }

    /// Moves both skiers down their routes until both have arrived or the meet ends.
    private func travel(meetID: UUID, to rendezvous: RendezvousID, mine: Route?, theirs: Route?) async {
        let started = Date()
        let resortID = state.withLock { $0.stage?.bundle.resortID }
        // Already standing at the meeting point there is no route to ski: say
        // so, or the meet could never complete.
        if theirs?.legs.isEmpty ?? true, let there = place, let bundle = state.withLock({ $0.stage?.bundle }),
           let node = bundle.rendezvous(rendezvous).flatMap({ bundle.graph.nodes[$0.nodeID] }),
           Geo.haversineM(there, node.coordinate) <= MeetSession.arrivalRadiusM {
            do {
                try await phone.meetProgressUpdate(
                    meetID: meetID, etaS: 0, etaSdS: 0, remainingM: 0, state: .arrived, fixAt: Date()
                )
            } catch {
                if !Task.isCancelled { log.info(.meet, "rehearsal: progress refused: \(error)") }
            }
        }
        while !Task.isCancelled {
            let elapsedS = Date().timeIntervalSince(started) * timing.speedup
            if let mine, let here = position(on: mine, at: elapsedS) {
                moveMe(here)
            }
            if let theirs, let there = position(on: theirs, at: elapsedS) {
                state.withLock { $0.place = there }
                let now = Date()
                let remainingS = max(0, theirs.eta.meanS - elapsedS)
                do {
                    try await phone.presenceUpdate(PresenceUpdate(
                        resortID: resortID, lon: there.lon, lat: there.lat, accuracyM: 8, capturedAt: now
                    ))
                    try await phone.meetProgressUpdate(
                        meetID: meetID, etaS: Int(remainingS), etaSdS: Int(theirs.eta.sdS),
                        remainingM: nil, state: remainingS > 0 ? .navigating : .arrived, fixAt: now
                    )
                } catch {
                    if !Task.isCancelled { log.info(.meet, "rehearsal: progress refused: \(error)") }
                    return
                }
            }
            if elapsedS > max(mine?.eta.meanS ?? 0, theirs?.eta.meanS ?? 0) { return }
            do {
                try await Task.sleep(for: .seconds(timing.tickS))
            } catch {
                return
            }
        }
    }
}
