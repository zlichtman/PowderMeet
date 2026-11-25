import DescentKit
import Foundation
import MapScene
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI

/// One selected resort: its verified bundle, live status and conditions, friends'
/// positions, this phone's presence, and at most one meet
/// (`specs/07-CLIENT.md` section 1). Cancelling `run()` ends all of it.
public actor ResortSession {
    public struct Ready: Sendable, Hashable {
        public var bundle: ResortBundle
        public var status: ResortStatus?
        public var conditions: Conditions?

        public func statusFreshness(at now: Date) -> StatusFreshness { .of(status, at: now) }
    }

    public enum State: Sendable, Hashable {
        case loadingBundle
        case ready(Ready)
        case failed(DataFailure)
    }

    public enum Event: Sendable {
        case bundleLoaded(ResortBundle)
        case bundleFailed(DataFailure)
        case statusUpdated(ResortStatus)
        case conditionsUpdated(Conditions)
        case fix(Fix)
        case friendsPresence([Presence])
        case proposeRequested(friend: UUID)
        /// A meet the server has for this user here: a proposal or a recovery.
        case incomingMeet(Meet)
        case meetEnded
        /// Clears a finished meet from view.
        case meetDismissed
        /// The user saved their profile; a meet being planned re-solves.
        case profileChanged(Profile)
        case serverEvent(ServerEvent)
        /// The connection came back: re-read what events may have missed.
        case reconnected
        /// `meet_current()` returned null.
        case noCurrentMeet
        /// An unfriend or block either way: that person's trail is forgotten.
        case personRemoved(UUID)
        case retry
        /// The app came to the foreground (true) or left it (false).
        case appActive(Bool)
        /// A prefetch job's answer (`MeetPrefetch`).
        case prefetched(Prefetched)
        /// The gap between prefetch jobs is over.
        case prefetchDue
        /// The oldest friend's position reached `FriendSignal.forgetAfterS`.
        case friendsExpired
        /// The server answered this phone's `presence_update` for `fix`.
        case presenceAnswered(Fix, sent: Bool)
    }

    /// What one prefetch job learned. `options` is nil when the pair had no
    /// answer; `failed` when the job could not read what it needed.
    public struct Prefetched: Sendable {
        var key: MeetPrefetch.Key
        /// What the solve ran on; the answer is kept only if these still hold.
        var bundleID: BundleID
        var status: ResortStatus?
        var conditions: Conditions?
        var options: MeetOptions?
        var partner: MeetPrefetch.Person?
        var myPace: PaceModel??
        var solvedInS = 0.0
        var failed = false
    }

    /// Presence publishing: every 5 s while moving (10 s with the app in the
    /// background, where each publish wakes the radio), every 30 s while still.
    public static let movingIntervalS = 5.0
    public static let movingBackgroundIntervalS = 10.0
    public static let stillIntervalS = 30.0
    public static let movingSpeedMS = 0.5
    public static let conditionsRefreshS = 30.0 * 60

    public nonisolated let resortID: String
    public private(set) var state: State = .loadingBundle
    /// Friends' latest positions, newest fix per friend.
    public private(set) var friends: [UUID: Presence] = [:]
    public private(set) var meetSession: MeetSession?
    /// Where the user and friends have been at this resort since it opened,
    /// for the timeline's replay. Ends with the session.
    public private(set) var breadcrumbs = Breadcrumbs()
    /// The run or lift each person (friends and the user) is on now, where
    /// the map can tell (`PlaceLocator`); nobody is listed while unsure.
    public private(set) var places: [UUID: SkierPlace] = [:]

    private let deps: Dependencies
    private var profile: Profile
    private var pendingMeet: Meet?
    private var reloadedFor: UUID?
    private var lastFix: Fix?
    /// The last fix the server took; a failed publish leaves it alone.
    private var lastPublished: Fix?
    private var publishing = false
    private var locationStarted = false
    private var appActive = true
    private var prefetch = MeetPrefetch()
    /// A prefetch job, or the wait before one, is under way.
    private var prefetching = false
    /// When the oldest friend's position runs out, while a wake-up waits for it.
    private var friendsExpireAt: Date?
    /// Built once per bundle; each person's last reading is handed back with
    /// their next position, which keeps the answer steady.
    private var locator: PlaceLocator?
    private var placeReadings: [UUID: PlaceReading] = [:]

    private var bag: TaskBag
    private let changes = Multicast<State>()
    private let meetChanges = Multicast<MeetSession?>()
    private let friendChanges = Multicast<[UUID: Presence]>()
    private let breadcrumbChanges = Multicast<Breadcrumbs>()
    private let placeChanges = Multicast<[UUID: SkierPlace]>()
    private let mailbox: AsyncStream<Event>
    private let inbox: AsyncStream<Event>.Continuation

    public init(resortID: String, profile: Profile, pendingMeet: Meet? = nil, dependencies: Dependencies) {
        self.resortID = resortID
        self.profile = profile
        self.pendingMeet = pendingMeet
        deps = dependencies
        bag = TaskBag(census: dependencies.census)
        (mailbox, inbox) = AsyncStream.makeStream(of: Event.self)
    }

    public nonisolated func send(_ event: Event) {
        inbox.yield(event)
    }

    public func states() -> AsyncStream<State> { changes.stream(initial: state) }

    /// The current meet session (or nil), then every replacement.
    public func meetSessions() -> AsyncStream<MeetSession?> { meetChanges.stream(initial: meetSession) }

    public func friendUpdates() -> AsyncStream<[UUID: Presence]> { friendChanges.stream(initial: friends) }

    /// Who is on which run or lift now, then a copy each time someone's answer changes.
    public func placeUpdates() -> AsyncStream<[UUID: SkierPlace]> { placeChanges.stream(initial: places) }

    /// The breadcrumbs now, then a copy each time a crumb is kept (every
    /// 10 s per moving person at most). Hold the latest copy and scrub it.
    public func breadcrumbUpdates() -> AsyncStream<Breadcrumbs> { breadcrumbChanges.stream(initial: breadcrumbs) }

    /// One person's trail (the user's own id included) since `since`.
    public func trail(for user: UUID, since: Date) -> [Breadcrumbs.Crumb] {
        breadcrumbs.trail(for: user, since: since)
    }

    /// Everyone's position at a past instant, for scrubbing back.
    public func positions(at instant: Date) -> [UUID: Coordinate] {
        breadcrumbs.positions(at: instant)
    }

    /// Runs until cancelled. Loads, subscriptions, presence and the meet all stop
    /// with it, and have stopped by the time this returns.
    public func run() async {
        startLoad()
        startLocation()
        for await event in mailbox {
            await handle(event)
            if Task.isCancelled { break }
        }
        inbox.finish()
        for task in bag.cancelAll() { await task.value }
        if locationStarted { await deps.location.stop() }
    }

    // MARK: Transitions

    private func handle(_ event: Event) async {
        switch event {
        case .bundleLoaded(let bundle):
            var ready = Ready(bundle: bundle)
            var sameBundle = false
            if case .ready(let old) = state {
                ready.status = old.status
                ready.conditions = old.conditions
                sameBundle = old.bundle.id == bundle.id
            }
            set(.ready(ready))
            if !sameBundle || locator == nil {
                // Readings name lines of the old bundle: start again.
                locator = PlaceLocator(bundle: bundle)
                placeReadings = [:]
                if !places.isEmpty {
                    places = [:]
                    placeChanges.send(places)
                }
                if let fix = lastFix { locate(profile.id, Self.position(fix)) }
                for presence in friends.values { locate(presence) }
            }
            startConditionsRefresh()
            // A fix that came before the map could say where the resort is.
            if lastPublished == nil, let fix = lastFix, FixQuality.isRoutingGrade(fix, now: deps.clock.now),
               Self.isNear(fix, bundle) {
                publishPresenceIfDue(fix)
            }
            if let meet = pendingMeet {
                pendingMeet = nil
                await adopt(meet)
            }
            prefetch.forgetOptions()
            schedulePrefetch()

        case .bundleFailed(let failure):
            // A failed reload leaves a working map alone.
            if case .ready = state { return }
            set(.failed(failure))

        case .statusUpdated(let status):
            guard status.resortID == resortID, case .ready(var ready) = state else { return }
            if let known = ready.status, status.observedAt < known.observedAt { return }
            ready.status = status
            set(.ready(ready))
            deps.bundles.save(status)
            meetSession?.send(.statusChanged(status))
            prefetch.forgetOptions()
            schedulePrefetch()

        case .conditionsUpdated(let conditions):
            guard conditions.resortID == resortID, case .ready(var ready) = state else { return }
            ready.conditions = conditions
            set(.ready(ready))
            // Developer testing's pretend weather is never cached as the forecast.
            if conditions.source != PretendWeather.source { deps.bundles.save(conditions) }
            meetSession?.send(.conditionsChanged(conditions))
            prefetch.forgetOptions()
            schedulePrefetch()

        case .fix(let fix):
            // I-14: only a routing-grade fix routes or is published.
            guard FixQuality.isRoutingGrade(fix, now: deps.clock.now) else { return }
            if let last = lastFix, fix.capturedAt <= last.capturedAt { return }
            lastFix = fix
            recordCrumb(profile.id, fix.coordinate, fix.capturedAt)
            locate(profile.id, Self.position(fix))
            meetSession?.send(.fix(fix))
            // DECISION 7: presence is sharing where the skier is at a resort,
            // never a home address while browsing this map from afar.
            if case .ready(let ready) = state, Self.isNear(fix, ready.bundle) { publishPresenceIfDue(fix) }
            schedulePrefetch()

        case .friendsPresence(let rows):
            for row in rows { merge(row) }
            schedulePrefetch()

        case .proposeRequested(let friend):
            guard case .ready = state else { return }
            if let current = meetSession, await !current.isEnded {
                await deps.toasts.post(.meet(.alreadyActive))
                return
            }
            await startMeet(.propose(friend: friend))

        case .incomingMeet(let meet):
            await adopt(meet)

        case .meetEnded:
            // The ended session stays readable until it is dismissed or replaced.
            deps.log.info(.resort, "meet session finished")

        case .meetDismissed:
            if let task = bag.cancel("meet") { await task.value }
            meetSession = nil
            meetChanges.send(nil)
            schedulePrefetch()

        case .profileChanged(let updated):
            profile = updated
            meetSession?.send(.profileChanged(updated))

        case .serverEvent(let event):
            switch event {
            case .presence(let presence):
                merge(presence)
                schedulePrefetch()
            case .meetProposed(let meet):
                await adopt(meet)
            case .meetUpdated(let meet):
                if let current = meetSession, await current.meetID == meet.meetID {
                    current.send(.proposalUpdated(meet))
                } else if !meet.status.isTerminal {
                    await adopt(meet)
                }
            case .meetProgress(let progress):
                meetSession?.send(.progressFromPartner(progress))
            case .resortStatus(let status):
                await handle(.statusUpdated(status))
            case .reconnected:
                await handle(.reconnected)
            case .friendRemoved(let friend):
                await handle(.personRemoved(friend.userID))
            case .friendRequested, .friendAccepted, .unknown:
                break
            }

        case .reconnected:
            guard case .ready = state else { return }
            startRefresh()
            meetSession?.send(.resync)

        case .noCurrentMeet:
            meetSession?.send(.serverHasNoMeet)

        case .personRemoved(let user):
            prefetch.forget(user)
            forgetPlace(user)
            // I-22: an ex-friend's last position leaves the map now.
            if friends.removeValue(forKey: user) != nil { friendChanges.send(friends) }
            if breadcrumbs.trails[user] != nil {
                breadcrumbs.remove(user)
                breadcrumbChanges.send(breadcrumbs)
            }

        case .retry:
            guard case .failed = state else { return }
            set(.loadingBundle)
            startLoad()

        case .appActive(let active):
            guard active != appActive else { return }
            appActive = active
            if active { schedulePrefetch() } else { cancelPrefetch() }

        case .prefetched(let result):
            prefetching = false
            let now = deps.clock.now
            if let partner = result.partner { prefetch.remember(partner, for: result.key.friend) }
            if let pace = result.myPace { prefetch.rememberMyPace(pace) }
            if result.failed {
                prefetch.failed(now: now)
            } else if !prefetchInputsCurrent(result) {
                // Status, conditions or the bundle changed while it solved, or
                // the friend is gone: the answer is for a mountain that is not
                // this one.
                deps.log.debug(.meet, "prefetched options dropped: inputs changed")
            } else {
                prefetch.store(result.options, for: result.key, solvedInS: result.solvedInS, now: now)
                deps.log.debug(.meet, "prefetched options in \(Int(result.solvedInS * 1_000)) ms")
            }
            schedulePrefetch()

        case .prefetchDue:
            prefetching = false
            schedulePrefetch()

        case .presenceAnswered(let fix, let sent):
            publishing = false
            // A failed publish does not count: the next fix tries at once.
            if sent { lastPublished = fix }

        case .friendsExpired:
            friendsExpireAt = nil
            let now = deps.clock.now
            let gone = friends.values.filter { Self.hasExpired($0, now: now) }.map(\.userID)
            if !gone.isEmpty {
                for user in gone {
                    friends[user] = nil
                    prefetch.forget(user)
                    forgetPlace(user)
                }
                // Breadcrumbs stay: the timeline can still replay where they went.
                friendChanges.send(friends)
            }
            scheduleFriendExpiry()
        }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        changes.send(new)
    }

    /// I-19: a position older than the one already shown is dropped.
    private func merge(_ presence: Presence) {
        guard presence.userID != profile.id else { return }
        if let known = friends[presence.userID], presence.capturedAt <= known.capturedAt { return }
        // A row the server still served but this phone's clock calls too old
        // would appear and be dropped again at once.
        guard !Self.hasExpired(presence, now: deps.clock.now) else { return }
        friends[presence.userID] = presence
        friendChanges.send(friends)
        scheduleFriendExpiry()
        if presence.resortID == nil || presence.resortID == resortID {
            recordCrumb(presence.userID, Coordinate(lon: presence.lon, lat: presence.lat), presence.capturedAt)
        }
        locate(presence)
        if let meet = meetSession, meet.partnerID == presence.userID {
            meet.send(.partnerPresence(presence))
        }
    }

    /// A friend's position at another resort names nothing here.
    private func locate(_ presence: Presence) {
        if let other = presence.resortID, other != resortID {
            forgetPlace(presence.userID)
            return
        }
        locate(presence.userID, SkierPosition(
            coordinate: Coordinate(lon: presence.lon, lat: presence.lat), accuracyM: presence.accuracyM,
            speedMS: presence.speedMS, headingDeg: presence.headingDeg, capturedAt: presence.capturedAt
        ))
    }

    private func locate(_ user: UUID, _ position: SkierPosition) {
        guard let locator else { return }
        let reading = locator.locate(position, after: placeReadings[user])
        placeReadings[user] = reading
        if places[user] != reading.place {
            places[user] = reading.place
            placeChanges.send(places)
        }
    }

    /// A friend who closed the resort, signed out or quit sends nothing more,
    /// and no event says so: their last position is dropped once it is as old
    /// as the server's presence TTL, so the map stops showing where they were.
    private static func hasExpired(_ presence: Presence, now: Date) -> Bool {
        now.timeIntervalSince(presence.capturedAt) >= FriendSignal.forgetAfterS
    }

    private func scheduleFriendExpiry() {
        guard let oldest = friends.values.map(\.capturedAt).min() else {
            friendsExpireAt = nil
            bag.cancel("friend-expiry")
            return
        }
        let due = oldest.addingTimeInterval(FriendSignal.forgetAfterS)
        guard due != friendsExpireAt else { return }
        friendsExpireAt = due
        let clock = deps.clock, inbox = inbox
        bag.start("friend-expiry") {
            do {
                // Measured when the wait starts, which may be a moment later.
                try await clock.sleep(for: due.timeIntervalSince(clock.now))
            } catch {
                return
            }
            inbox.yield(.friendsExpired)
        }
    }

    private func forgetPlace(_ user: UUID) {
        placeReadings[user] = nil
        if places.removeValue(forKey: user) != nil { placeChanges.send(places) }
    }

    /// A fix has no heading; the locator works it out from the fixes before.
    private static func position(_ fix: Fix) -> SkierPosition {
        SkierPosition(
            coordinate: fix.coordinate, accuracyM: fix.accuracyM, speedMS: fix.speedMS, headingDeg: nil,
            capturedAt: fix.capturedAt
        )
    }

    private func recordCrumb(_ user: UUID, _ coordinate: Coordinate, _ time: Date) {
        if breadcrumbs.record(user, at: coordinate, time: time) { breadcrumbChanges.send(breadcrumbs) }
    }

    // MARK: Meets

    /// Hands a server meet to its session, creating one if needed.
    private func adopt(_ meet: Meet) async {
        guard meet.resortID == resortID, meet.involves(profile.id) else { return }
        guard case .ready(let ready) = state else {
            pendingMeet = meet
            return
        }
        if let current = meetSession, await current.meetID == meet.meetID {
            current.send(.proposalUpdated(meet))
            return
        }
        guard !meet.status.isTerminal else { return }
        if ready.bundle.rendezvous(meet.rendezvousID) == nil {
            // The proposer solved on a newer bundle: fetch the active one, once.
            // If it lacks the rendezvous too, the server has invalidated the meet.
            guard reloadedFor != meet.meetID else { return }
            reloadedFor = meet.meetID
            pendingMeet = meet
            startLoad(cachedFirst: false)
            return
        }
        await startMeet(.adopt(meet))
    }

    private func startMeet(_ start: MeetSession.Start) async {
        guard case .ready(let ready) = state else { return }
        // The meet's own solve has the phone to itself; nothing is prefetched
        // until the meet is dismissed.
        cancelPrefetch()
        if let task = bag.cancel("meet") { await task.value }
        let partner: UUID = switch start {
        case .propose(let friend): friend
        case .adopt(let meet): meet.partner(of: profile.id)
        }
        // A tap on a friend shows the prefetched options at once while both
        // people are still in the buckets they were solved for.
        var key: MeetPrefetch.Key?
        if case .propose = start, let fix = lastFix, let presence = friends[partner] {
            key = MeetPrefetch.Key(
                friend: partner, mine: fix.coordinate, theirs: Coordinate(lon: presence.lon, lat: presence.lat),
                profile: SkierProfile(profile), at: deps.solveClock.now
            )
        }
        let seed = prefetch.seed(for: key, friend: partner)
        if seed.options != nil { deps.log.info(.meet, "showing prefetched options") }
        let session = MeetSession(
            start: start,
            context: MeetSession.Context(
                profile: profile, bundle: ready.bundle, status: ready.status,
                conditions: ready.conditions, lastFix: lastFix, partnerPresence: friends[partner],
                seed: seed
            ),
            dependencies: deps
        )
        meetSession = session
        meetChanges.send(session)
        let inbox = inbox
        bag.start("meet") {
            await session.run()
            if !Task.isCancelled { inbox.yield(.meetEnded) }
        }
    }

    // MARK: Effects

    /// Loads the bundle and then keeps status flowing. A resort this phone has
    /// opened before is shown from disk at once (`cachedFirst`), and the catalog
    /// is asked afterwards whether a newer bundle is active; otherwise the catalog
    /// names the bundle and it comes from disk or the network. Posts events;
    /// touches no session state.
    private func startLoad(cachedFirst: Bool = true) {
        let deps = deps, resortID = resortID, inbox = inbox, user = profile.id
        bag.start("load") {
            let started = ContinuousClock.now
            func elapsedMS() -> Double {
                let elapsed = ContinuousClock.now - started
                return Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
            }
            func loaded(_ bundle: ResortBundle, from source: String) async {
                inbox.yield(.bundleLoaded(bundle))
                let ms = elapsedMS()
                deps.log.info(.resort, "bundle ready from \(source) in \(Int(ms)) ms")
                await deps.outbox.enqueue(
                    key: "event:\(UUID().uuidString)", user: user,
                    .clientEvent(kind: "bundle.loaded", props: ["ms": .number(ms)])
                )
            }

            var shown: BundleID?
            if cachedFirst, let id = deps.bundles.activeBundleID(resortID: resortID),
               let cached = deps.bundles.bundle(id) {
                guard !Task.isCancelled else { return }
                await loaded(cached, from: "cache")
                shown = id
            }

            // Which bundle is active: the catalog, or the last known pointer offline.
            var bundleID = shown
            do {
                if let resort = try await deps.backend.publishedResorts().first(where: { $0.id == resortID }) {
                    bundleID = resort.bundleID ?? shown
                }
            } catch {
                if Task.isCancelled { return }
                deps.log.notice(.resort, "catalog unavailable, using the cached pointer: \(error)")
                bundleID = bundleID ?? deps.bundles.activeBundleID(resortID: resortID)
            }
            guard let bundleID else {
                inbox.yield(.bundleFailed(.bundleUnavailable(resortID: resortID)))
                return
            }

            // `bundleFailed` leaves a map that is already showing alone.
            if bundleID != shown {
                if let cached = deps.bundles.bundle(bundleID) {
                    guard !Task.isCancelled else { return }
                    await loaded(cached, from: "cache")
                } else {
                    let data: Data
                    do {
                        data = try await deps.backend.bundleData(resortID: resortID, bundleID: bundleID)
                    } catch {
                        if Task.isCancelled { return }
                        deps.log.error(.resort, "bundle download failed: \(error)")
                        inbox.yield(.bundleFailed(.bundleUnavailable(resortID: resortID)))
                        if shown == nil { return }
                        data = Data()
                    }
                    if !data.isEmpty {
                        do {
                            let bundle = try BundleLoader.load(data: data, expectedID: bundleID)
                            deps.bundles.save(data, as: bundleID, activeFor: resortID)
                            guard !Task.isCancelled else { return }
                            await loaded(bundle, from: "network")
                        } catch {
                            deps.log.fault(.resort, "bundle failed verification: \(error)")
                            inbox.yield(.bundleFailed(.bundleCorrupt(bundleID)))
                            if shown == nil { return }
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }

            // Last known status first, so the map has a labelled state offline.
            if let status = deps.bundles.status(resortID: resortID) { inbox.yield(.statusUpdated(status)) }
            if let conditions = deps.bundles.conditions(resortID: resortID) {
                inbox.yield(.conditionsUpdated(conditions))
            }

            // Join the resort topic before reading, so no status row falls between.
            var events: AsyncStream<ServerEvent>?
            do {
                events = try await deps.backend.resortEvents(resortID: resortID)
            } catch {
                if Task.isCancelled { return }
                deps.log.error(.realtime, "resort topic unavailable: \(error)")
            }
            await Self.refresh(deps: deps, resortID: resortID, inbox: inbox)
            guard let events else { return }
            for await event in events {
                inbox.yield(.serverEvent(event))
            }
        }
    }

    private func startRefresh() {
        let deps = deps, resortID = resortID, inbox = inbox
        bag.start("refresh") {
            await Self.refresh(deps: deps, resortID: resortID, inbox: inbox)
        }
    }

    /// Reads status, conditions and friends' positions. Each is optional to the
    /// map, so a failure is logged and the last known value stays.
    private static func refresh(
        deps: Dependencies, resortID: String, inbox: AsyncStream<Event>.Continuation
    ) async {
        do {
            if let status = try await deps.backend.resortStatus(resortID: resortID) {
                inbox.yield(.statusUpdated(status))
            }
        } catch {
            if Task.isCancelled { return }
            deps.log.notice(.resort, "status unavailable: \(error)")
        }
        do {
            if let conditions = try await deps.backend.resortConditions(resortID: resortID) {
                inbox.yield(.conditionsUpdated(conditions))
            }
        } catch {
            if Task.isCancelled { return }
            deps.log.notice(.resort, "conditions unavailable: \(error)")
        }
        do {
            inbox.yield(.friendsPresence(try await deps.backend.presenceSnapshot(resortID: resortID)))
        } catch {
            if Task.isCancelled { return }
            deps.log.notice(.resort, "presence snapshot unavailable: \(error)")
        }
    }

    private func startConditionsRefresh() {
        let deps = deps, resortID = resortID, inbox = inbox
        bag.start("conditions") {
            while !Task.isCancelled {
                do {
                    try await deps.clock.sleep(for: Self.conditionsRefreshS)
                    if let conditions = try await deps.backend.resortConditions(resortID: resortID) {
                        inbox.yield(.conditionsUpdated(conditions))
                    }
                } catch {
                    if Task.isCancelled { return }
                    deps.log.notice(.resort, "conditions refresh failed: \(error)")
                }
            }
        }
    }

    private func startLocation() {
        locationStarted = true
        let location = deps.location, inbox = inbox
        bag.start("location") {
            let fixes = location.fixes()
            await location.start()
            for await fix in fixes {
                inbox.yield(.fix(fix))
            }
        }
    }

    /// At the resort: within the distance at which `ResortVicinity` lets a
    /// phone leave a resort's box.
    static func isNear(_ fix: Fix, _ bundle: ResortBundle) -> Bool {
        ResortVicinity.distanceM(fix.coordinate, to: bundle.bbox) <= ResortVicinity.leaveM
    }

    /// Only one `presence_update` is on its way at a time: on a slow cell a
    /// new one would cancel the last before it lands, and friends would see
    /// nothing. A fix due meanwhile is skipped rather than sent the moment
    /// the last one answers, which the server would drop (one fix per 2 s);
    /// the next fix after the answer goes.
    private func publishPresenceIfDue(_ fix: Fix) {
        guard !publishing else { return }
        if let last = lastPublished {
            let elapsed = fix.capturedAt.timeIntervalSince(last.capturedAt)
            let speed = elapsed > 0 ? Geo.haversineM(last.coordinate, fix.coordinate) / elapsed : 0
            let moving = appActive ? Self.movingIntervalS : Self.movingBackgroundIntervalS
            let interval = speed >= Self.movingSpeedMS ? moving : Self.stillIntervalS
            guard elapsed >= interval else { return }
        }
        publishing = true
        let backend = deps.backend, log = deps.log, resortID = resortID, inbox = inbox
        bag.start("presence") {
            do {
                try await backend.presenceUpdate(PresenceUpdate(
                    resortID: resortID, lon: fix.coordinate.lon, lat: fix.coordinate.lat,
                    accuracyM: fix.accuracyM, speedMS: fix.speedMS, capturedAt: fix.capturedAt
                ))
                inbox.yield(.presenceAnswered(fix, sent: true))
            } catch {
                if Task.isCancelled { return }
                log.info(.location, "presence not published: \(error)")
                inbox.yield(.presenceAnswered(fix, sent: false))
            }
        }
    }

    // MARK: Prefetch

    /// Starts the next prefetch job, or the wait before it, when one is wanted
    /// and none is under way (`MeetPrefetch`).
    private func schedulePrefetch() {
        guard !prefetching, appActive, meetSession == nil, !MeetPrefetch.deviceSavingPower,
              case .ready(let ready) = state, let fix = lastFix,
              FixQuality.isRoutingGrade(fix, now: deps.clock.now) else { return }
        let now = deps.clock.now, at = deps.solveClock.now
        guard let key = prefetch.next(
            friends: Array(friends.values), resortID: resortID, mine: fix.coordinate,
            profile: SkierProfile(profile), at: at, now: now
        ), let presence = friends[key.friend] else { return }
        prefetching = true
        let deps = deps, inbox = inbox
        let wait = prefetch.notBefore.timeIntervalSince(now)
        guard wait <= 0 else {
            bag.start("prefetch") {
                do {
                    try await deps.clock.sleep(for: wait)
                } catch {
                    return
                }
                inbox.yield(.prefetchDue)
            }
            return
        }
        let me = profile.id, knownPartner = prefetch.freshPerson(key.friend, now: now), knownPace = prefetch.myPace
        let inputs = Solving.Inputs(bundle: ready.bundle, status: ready.status, conditions: ready.conditions, at: at)
        bag.start("prefetch") {
            var result = Prefetched(
                key: key, bundleID: inputs.bundle.id, status: inputs.status, conditions: inputs.conditions
            )
            do {
                var myPace = knownPace
                if myPace == nil {
                    myPace = .some(try await deps.backend.paceModel(owner: me).flatMap(PaceModel.init))
                    result.myPace = myPace
                }
                var partner = knownPartner
                if partner == nil, let row = try await deps.backend.profile(id: key.friend) {
                    let pace = try await deps.backend.paceModel(owner: key.friend).flatMap(PaceModel.init)
                    partner = MeetPrefetch.Person(
                        profile: SkierProfile(row), pace: pace, name: row.displayName, readAt: now
                    )
                    result.partner = partner
                }
                guard !Task.isCancelled else { return }
                if let partner,
                   let mine = OriginResolver.origin(for: fix, in: inputs.bundle),
                   let theirs = OriginResolver.origin(for: presence.fix, in: inputs.bundle) {
                    let input = Solving.input(
                        inputs,
                        SkierInput(id: me, profile: key.profile, pace: myPace ?? nil, origin: mine),
                        SkierInput(id: key.friend, profile: partner.profile, pace: partner.pace, origin: theirs)
                    )
                    let started = ContinuousClock.now
                    if case .success(let options) = MeetSolver.solve(input) { result.options = options }
                    let elapsed = ContinuousClock.now - started
                    result.solvedInS = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                }
            } catch {
                if Task.isCancelled { return }
                deps.log.info(.meet, "prefetch skipped: \(error)")
                result.failed = true
            }
            guard !Task.isCancelled else { return }
            inbox.yield(.prefetched(result))
        }
    }

    private func prefetchInputsCurrent(_ result: Prefetched) -> Bool {
        guard case .ready(let ready) = state, friends[result.key.friend] != nil else { return false }
        return ready.bundle.id == result.bundleID && ready.status == result.status
            && ready.conditions == result.conditions
    }

    private func cancelPrefetch() {
        bag.cancel("prefetch")
        prefetching = false
    }

    /// Whether a tap on this friend would show options at once (tests).
    func hasPrefetchedOptions(for friend: UUID) -> Bool {
        guard let fix = lastFix, let presence = friends[friend] else { return false }
        let key = MeetPrefetch.Key(
            friend: friend, mine: fix.coordinate, theirs: Coordinate(lon: presence.lon, lat: presence.lat),
            profile: SkierProfile(profile), at: deps.solveClock.now
        )
        return prefetch.options(for: key) != nil
    }
}

extension SkierPlace {
    /// How the app says it: "On Pika's Traverse", "Riding Peak Express".
    public var phrase: String {
        switch self {
        case .run(let name, _): "On \(name)"
        case .lift(let name): "Riding \(name)"
        }
    }
}
