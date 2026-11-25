import Foundation
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI
import Synchronization

/// Developer testing's dev people, Dev 1 to Dev 3: people who exist on this
/// phone only (`specs/07-CLIENT.md` section 8). Their accounts, their
/// friendships with the signed-in user, their positions and every meet with
/// them live in a private `FakeBackend`, each played by a `RehearsalPartner`;
/// `SandboxedBackend` sends each call about them there and everything else to
/// the real backend, so neither the server nor anyone on it ever sees them.
public final class DeveloperSandbox: Sendable {
    /// One of the dev people.
    public struct DevPerson: Sendable, Hashable, Identifiable {
        public let number: Int
        public let id: UUID

        public var name: String { "Dev \(number)" }
    }

    /// Dev 1 to Dev 3, the three "Show dev people" puts on the mountain. Dev 1
    /// keeps the id the pretend friend had, which the demo's friend photo and
    /// the Debug launch scripts use.
    public static let devPeople: [DevPerson] = (1...3).map { number in
        DevPerson(number: number, id: UUID(uuidString: "00000000-0000-4000-8000-0000000\(number - 1)f00d")!)
    }

    /// Dev 1's id.
    public static let pretendFriendID = devPeople[0].id

    /// The strongest tier, so a dev person rarely blocks a meet unless asked to.
    public static let defaultLevel = Ability.expert

    public static func devPerson(_ id: UUID) -> DevPerson? { devPeople.first { $0.id == id } }

    public static func isDevPerson(_ id: UUID) -> Bool { devPerson(id) != nil }

    /// A dev person's profile at a level: that tier's pace and its usual
    /// hardest run, as onboarding saves them.
    public static func skillLevel(_ level: Ability) -> SkillLevel {
        let preset = SkierProfile.preset(level, userID: UUID())
        return SkillLevel(
            ability: level.rawValue, maxDifficulty: preset.maxDifficulty.rawValue,
            baselineSpeeds: Dictionary(uniqueKeysWithValues: preset.baselineSpeedMS.map { ($0.key.rawValue, $0.value) })
        )
    }

    /// The meet funnel events (`client_event`) a phone with a dev person on
    /// the mountain does not send, so rehearsals stay out of the server's numbers.
    static let rehearsalEventKinds: Set<String> = [
        "meet.proposed", "meet.superseded", "meet.accepted", "meet.declined", "meet.active",
        "meet.ended", "reroute", "solve",
    ]

    public enum Failure: Error, Sendable, Hashable {
        /// No mountain is staged yet, or nobody is signed in.
        case notReady
    }

    let server: FakeBackend
    /// Each dev person's phone on the sandbox server.
    private let phones: [UUID: FakeBackendClient]
    private let location: PlaceableLocationProvider
    private let solveClock: any Clock
    private let log: PMLog
    private let timing: RehearsalPartner.Timing

    private struct State {
        var me: UUID?
        var myPhone: FakeBackendClient?
        /// The signed-in user's own row, as the real backend last returned it,
        /// so a rehearsal moves this phone along a route at their own limits.
        var ownProfile: Profile?
        var partners: [UUID: RehearsalPartner] = [:]
        var levels: [UUID: Ability] = [:]
        var placed: Set<UUID> = []
        var stage: RehearsalPartner.Stage?
        var stagedBundle: BundleID?
        /// A dev person has been placed since sign-in, so a rehearsal may exist.
        var hasRehearsed = false
        var withholdsPresence = false
        var pretendWeather = PretendWeather.real
        /// The last real `resort_conditions` row per mountain, so switching the
        /// pretend weather shows at once, with no read.
        var realConditions: [String: Conditions] = [:]
        var serverClock: Task<Void, Never>?
    }

    private let state = Mutex(State())

    /// - Parameters:
    ///   - location: this phone's location; a rehearsal moves this phone along
    ///     its route only while it is placed by hand.
    ///   - solveClock: the instant routes are priced at (`Dependencies.solveClock`).
    public init(
        location: PlaceableLocationProvider, solveClock: any Clock, log: PMLog = PMLog(),
        timing: RehearsalPartner.Timing = RehearsalPartner.Timing()
    ) {
        let server = FakeBackend(now: Date())
        self.server = server
        phones = Dictionary(uniqueKeysWithValues: Self.devPeople.map { ($0.id, server.client(signedInAs: $0.id)) })
        self.location = location
        self.solveClock = solveClock
        self.log = log
        self.timing = timing
    }

    deinit {
        state.withLock { state in
            state.serverClock?.cancel()
            for partner in state.partners.values { partner.stop() }
        }
    }

    // MARK: What the developer screen reads

    /// The dev people on the staged mountain.
    public var placedPeople: Set<UUID> { state.withLock { $0.placed } }

    /// At least one dev person is on the staged mountain.
    public var hasDevPeople: Bool { state.withLock { !$0.placed.isEmpty } }

    /// Where a dev person stands, while they are on the mountain.
    public func place(of id: UUID) -> Coordinate? {
        state.withLock { state in state.placed.contains(id) ? state.partners[id]?.place : nil }
    }

    public func level(of id: UUID) -> Ability {
        state.withLock { $0.levels[id] ?? Self.defaultLevel }
    }

    /// The mountain the sandbox serves.
    public var stagedResortID: String? { state.withLock { $0.stage?.bundle.resortID } }

    /// While true, this phone's position is not published to the real backend.
    public var withholdsPresence: Bool { state.withLock { $0.withholdsPresence } }

    public func setWithholdsPresence(_ value: Bool) {
        state.withLock { $0.withholdsPresence = value }
    }

    /// The weather the solver and the weather card read on this phone.
    public func setPretendWeather(_ weather: PretendWeather) {
        state.withLock { $0.pretendWeather = weather }
    }

    /// The row a mountain's weather reads as now: the pretend weather over the
    /// last real row. Nil when real weather is on and no real row was read.
    public func conditions(resortID: String, now: Date = Date()) -> Conditions? {
        let (weather, real) = state.withLock { ($0.pretendWeather, $0.realConditions[resortID]) }
        return weather.apply(to: real, resortID: resortID, now: now)
    }

    /// A `resort_conditions` row from the real backend, as this phone reads it.
    func shown(real: Conditions?, resortID: String) -> Conditions? {
        let weather = state.withLock { state -> PretendWeather in
            if let real { state.realConditions[resortID] = real }
            return state.pretendWeather
        }
        return weather.apply(to: real, resortID: resortID, now: Date())
    }

    // MARK: Driving it

    /// The mountain on screen, its status and its weather. A new bundle puts
    /// every dev person away until they are placed again.
    public func stage(_ stage: RehearsalPartner.Stage) async {
        let bundle = stage.bundle
        let (isNew, partners) = state.withLock { state -> (Bool, [RehearsalPartner]) in
            let isNew = state.stagedBundle != bundle.id
            state.stage = stage
            state.stagedBundle = bundle.id
            if isNew { state.placed = [] }
            return (isNew, Array(state.partners.values))
        }
        for partner in partners { partner.setStage(stage) }
        guard isNew else { return }
        for partner in partners { await partner.stand(at: nil) }
        await server.addResort(PublishedResort(
            id: bundle.resortID, name: bundle.name, timezone: bundle.timezone, bbox: bundle.bbox,
            center: bundle.center
        ))
        // Nobody downloads from the sandbox: the phone has the bundle already.
        // The rendezvous are what `meet_propose` checks.
        await server.publishBundle(
            resortID: bundle.resortID, bundleID: bundle.id, data: Data(),
            rendezvousIDs: bundle.rendezvous.map(\.id)
        )
    }

    /// Puts a dev person at a place on the staged mountain; the first time,
    /// they appear on the map.
    public func place(_ id: UUID, at coordinate: Coordinate) async throws {
        let ready = state.withLock { state -> (String, FakeBackendClient, RehearsalPartner)? in
            guard let resortID = state.stage?.bundle.resortID, let myPhone = state.myPhone,
                  let partner = state.partners[id] else { return nil }
            return (resortID, myPhone, partner)
        }
        guard case let (resortID, myPhone, partner)? = ready, let phone = phones[id] else {
            throw Failure.notReady
        }
        startServerClock()
        // Both at the resort, so the dev person's reports reach this phone.
        _ = try await myPhone.profileUpdate(ProfilePatch().currentResortID(resortID))
        _ = try await phone.profileUpdate(ProfilePatch().currentResortID(resortID))
        state.withLock { state in
            state.placed.insert(id)
            state.hasRehearsed = true
        }
        await partner.stand(at: coordinate)
    }

    /// A dev person stops reporting and leaves the map at once. A friend who
    /// stops reporting would linger until their position expires, so the dev
    /// person is unfriended and befriended again inside the sandbox: the
    /// `friend.removed` that reaches this phone comes after any position they
    /// already sent, and drops the marker the way a real unfriend does. A meet
    /// with them ends.
    public func remove(_ id: UUID) async throws {
        let (partner, me) = state.withLock { state -> (RehearsalPartner?, UUID?) in
            state.placed.remove(id)
            return (state.partners[id], state.myPhone == nil ? nil : state.me)
        }
        await partner?.stand(at: nil)
        guard let me, let phone = phones[id] else { return }
        try await phone.friendRemove(user: me)
        await server.makeFriends(me, id)
    }

    /// A dev person's skill tier, with that tier's pace and usual hardest run.
    /// The app keeps the profile it read for a friend (`MeetPrefetch`, an open
    /// meet), so the dev person is unfriended and befriended again: the next
    /// solve reads the new level, and a meet with them ends.
    public func setLevel(_ level: Ability, for id: UUID) async throws {
        guard let phone = phones[id] else { return }
        let joined = state.withLock { state -> (UUID, RehearsalPartner?)? in
            state.levels[id] = level
            guard let me = state.me, state.myPhone != nil else { return nil }
            return (me, state.partners[id])
        }
        // Before the sandbox is joined, its accounts are made at this level.
        guard let (me, partner) = joined else { return }
        _ = try await phone.profileUpdate(Self.skillLevel(level).patch)
        try await phone.friendRemove(user: me)
        await server.makeFriends(me, id)
        if let partner, let place = place(of: id) { await partner.stand(at: place) }
    }

    // MARK: For SandboxedBackend

    /// Joins the sandbox as the signed-in user: their account, the dev people's
    /// and the friendships are made the first time. Returns the user's sandbox
    /// topic.
    func join(as me: UUID) async -> AsyncStream<ServerEvent>? {
        let known = state.withLock { state -> FakeBackendClient? in
            state.me == me ? state.myPhone : nil
        }
        if let known { return await topic(of: known) }
        // The accounts first: until `myPhone` is set, every call goes to the real
        // backend, so nothing can reach a sandbox without its user.
        await server.addUser(id: me, displayName: "You")
        let levels = state.withLock { $0.levels }
        for person in Self.devPeople {
            await server.addUser(
                id: person.id, displayName: person.name,
                level: Self.skillLevel(levels[person.id] ?? Self.defaultLevel)
            )
            await server.makeFriends(me, person.id)
        }
        let phone = server.client(signedInAs: me)
        var partners: [UUID: RehearsalPartner] = [:]
        for (id, friendPhone) in phones { partners[id] = partner(id, me: me, phone: friendPhone) }
        let (replaced, stage) = state.withLock { state -> ([RehearsalPartner], RehearsalPartner.Stage?) in
            let replaced = Array(state.partners.values)
            state.me = me
            state.myPhone = phone
            state.partners = partners
            state.placed = []
            return (replaced, state.stage)
        }
        for partner in replaced { partner.stop() }
        for partner in partners.values {
            partner.setStage(stage)
            partner.start()
        }
        return await topic(of: phone)
    }

    private func partner(_ id: UUID, me: UUID, phone: FakeBackendClient) -> RehearsalPartner {
        let location = location
        return RehearsalPartner(
            id: id, me: me, phone: phone, solveClock: solveClock, timing: timing, log: log,
            whereAmI: { location.lastCoordinate },
            // Only a phone placed by hand is moved; one on real GPS is the skier's own.
            moveMe: { coordinate in if location.placed != nil { location.place(at: coordinate) } },
            profileOf: { [weak self] user in
                self?.skierProfile(of: user) ?? .preset(Self.defaultLevel, userID: user)
            }
        )
    }

    /// How a skier in a rehearsal skis: a dev person at their level, this
    /// phone's user as their own profile says.
    func skierProfile(of user: UUID) -> SkierProfile {
        state.withLock { state in
            if let own = state.ownProfile, own.id == user { return SkierProfile(own) }
            let level = Self.isDevPerson(user) ? state.levels[user] ?? Self.defaultLevel : .intermediate
            return .preset(level, userID: user)
        }
    }

    /// The signed-in user's own row, whenever the real backend returns it.
    func noteOwnProfile(_ profile: Profile) {
        state.withLock { $0.ownProfile = profile }
    }

    private func topic(of phone: FakeBackendClient) async -> AsyncStream<ServerEvent>? {
        do {
            return try await phone.events()
        } catch {
            log.error(.realtime, "developer sandbox topic unavailable: \(error)")
            return nil
        }
    }

    var myPhone: FakeBackendClient? { state.withLock { $0.myPhone } }

    /// The sandbox may hold a meet: a dev person has been placed since sign-in.
    var mayHoldMeets: Bool { state.withLock { $0.hasRehearsed } }

    /// A meet the sandbox holds, so calls about it go there.
    func holds(meet id: UUID) async -> Bool {
        await server.storedMeet(id) != nil
    }

    /// Keeps the sandbox's clock on real time. It only moves when told to, and a
    /// server whose clock stands still drops every presence report after the
    /// first as "too soon".
    private func startServerClock() {
        let server = server
        let started = state.withLock { state -> Bool in
            guard state.serverClock == nil else { return false }
            state.serverClock = Task {
                while !Task.isCancelled {
                    await server.advance(by: Date().timeIntervalSince(await server.now))
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
            return true
        }
        if started { log.info(.session, "developer sandbox clock started") }
    }
}


/// What developer testing shows about the connection.
public struct RealtimeDiagnostics: Sendable, Hashable {
    /// When the user topic was joined; nil while it is not.
    public var subscribedAt: Date?
    public var lastEventAt: Date?
    public var reconnects = 0
    /// The last `resort_status` read, and whether it returned a row.
    public var lastStatusReadAt: Date?
    public var lastStatusFound = false

    public init() {}
}

/// The real backend with developer testing's sandbox beside it: calls about the
/// dev people and their meets go to the sandbox, everything else to `base`.
/// While the sandbox withholds presence (a teleported phone in live mode), this
/// phone's position is not published; while a dev person is on the mountain, the meet
/// funnel events are not sent. Built only when the app's gate allows developer
/// testing (`specs/07-CLIENT.md` section 8).
public final class SandboxedBackend: BackendClient {
    public let base: any BackendClient
    public let sandbox: DeveloperSandbox
    private let realtime = Mutex(RealtimeDiagnostics())

    public init(base: any BackendClient, sandbox: DeveloperSandbox) {
        self.base = base
        self.sandbox = sandbox
    }

    public var diagnostics: RealtimeDiagnostics { realtime.withLock { $0 } }

    /// The sandbox client when it holds this meet, else nil.
    private func sandboxClient(forMeet id: UUID) async -> (any BackendClient)? {
        guard let phone = sandbox.myPhone, await sandbox.holds(meet: id) else { return nil }
        return phone
    }

    // Calls developer testing never intercepts: straight to the real backend.

    public func reportUser(_ user: UUID, reason: ReportReason, note: String?, context: ReportContext?) async throws {
        try await base.reportUser(user, reason: reason, note: note, context: context)
    }
    public func avatarUpload(jpeg: Data) async throws -> String { try await base.avatarUpload(jpeg: jpeg) }
    public func avatarRemove(keeping: String?) async throws { try await base.avatarRemove(keeping: keeping) }
    public func avatarData(path: String) async throws -> Data { try await base.avatarData(path: path) }
    public func notificationPrefs() async throws -> Set<PushKind> { try await base.notificationPrefs() }
    public func notificationPrefsSet(muted: Set<PushKind>) async throws -> Set<PushKind> {
        try await base.notificationPrefsSet(muted: muted)
    }

    private func noteLive(_ event: ServerEvent) {
        realtime.withLock { diagnostics in
            diagnostics.lastEventAt = Date()
            if event == .reconnected { diagnostics.reconnects += 1 }
        }
    }

    // MARK: Auth

    public func currentSession() async -> AuthSession? { await base.currentSession() }

    public func signInWithApple(idToken: String, nonce: String?, fullName: String?) async throws -> AuthSession {
        try await base.signInWithApple(idToken: idToken, nonce: nonce, fullName: fullName)
    }

    public func signUp(email: String, password: String) async throws -> SignUpOutcome {
        try await base.signUp(email: email, password: password)
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try await base.signIn(email: email, password: password)
    }

    public func resendConfirmation(email: String) async throws {
        try await base.resendConfirmation(email: email)
    }

    public func sendPasswordReset(email: String) async throws {
        try await base.sendPasswordReset(email: email)
    }

    public func openAuthLink(_ url: URL) async throws -> AuthLink { try await base.openAuthLink(url) }

    public func updatePassword(_ password: String) async throws { try await base.updatePassword(password) }

    public func signOut() async throws { try await base.signOut() }

    public func authEvents() -> AsyncStream<AuthEvent> { base.authEvents() }

    // MARK: Realtime

    /// The real topic with the sandbox's beside it. It ends when the real one
    /// does, so the session's reconnect handling is unchanged.
    public func events() async throws -> AsyncStream<ServerEvent> {
        let live = try await base.events()
        realtime.withLock { $0.subscribedAt = Date() }
        var joined: AsyncStream<ServerEvent>?
        if let me = await base.currentSession()?.userID {
            joined = await sandbox.join(as: me)
        }
        let shadow = joined
        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self)
        let side = Task {
            guard let shadow else { return }
            for await event in shadow { continuation.yield(event) }
        }
        let main = Task { [self] in
            for await event in live {
                noteLive(event)
                continuation.yield(event)
            }
            realtime.withLock { $0.subscribedAt = nil }
            side.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            main.cancel()
            side.cancel()
        }
        return stream
    }

    public func resortEvents(resortID: String) async throws -> AsyncStream<ServerEvent> {
        try await base.resortEvents(resortID: resortID)
    }

    // MARK: Social

    public func friendRequest(user: UUID) async throws -> Friendship { try await base.friendRequest(user: user) }

    public func friendRespond(friendshipID: UUID, accept: Bool) async throws -> Friendship {
        try await base.friendRespond(friendshipID: friendshipID, accept: accept)
    }

    public func friendRemove(user: UUID) async throws {
        if DeveloperSandbox.isDevPerson(user) {
            try await sandbox.remove(user)
            return
        }
        try await base.friendRemove(user: user)
    }

    public func blockUser(_ user: UUID) async throws {
        if DeveloperSandbox.isDevPerson(user) {
            try await sandbox.remove(user)
            return
        }
        try await base.blockUser(user)
    }

    public func unblockUser(_ user: UUID) async throws {
        guard !DeveloperSandbox.isDevPerson(user) else { return }
        try await base.unblockUser(user)
    }

    public func findUsers(emailHashes: [String], phoneHashes: [String]) async throws -> [UserMatch] {
        try await base.findUsers(emailHashes: emailHashes, phoneHashes: phoneHashes)
    }

    public func searchUsers(query: String) async throws -> [UserSearchResult] {
        try await base.searchUsers(query: query)
    }

    public func socialSnapshot() async throws -> SocialSnapshot { try await base.socialSnapshot() }

    public func profileUpdate(_ patch: ProfilePatch) async throws -> Profile {
        let profile = try await base.profileUpdate(patch)
        sandbox.noteOwnProfile(profile)
        return profile
    }

    public func displayNameAvailable(_ name: String) async throws -> DisplayNameAvailability {
        try await base.displayNameAvailable(name)
    }

    public func accountDelete() async throws { try await base.accountDelete() }

    // MARK: Presence

    public func presenceUpdate(_ update: PresenceUpdate) async throws {
        // A teleported phone keeps its pretend position to itself.
        guard !sandbox.withholdsPresence else { return }
        try await base.presenceUpdate(update)
    }

    public func presenceClear() async throws { try await base.presenceClear() }

    public func presenceSnapshot(resortID: String) async throws -> [Presence] {
        var rows = try await base.presenceSnapshot(resortID: resortID)
        let placed = sandbox.placedPeople
        if !placed.isEmpty, let phone = sandbox.myPhone {
            do {
                rows += try await phone.presenceSnapshot(resortID: resortID).filter { placed.contains($0.userID) }
            } catch {
                // The real rows stand on their own.
            }
        }
        return rows
    }

    // MARK: Devices and events

    public func deviceTokenRegister(token: String, environment: PushEnvironment, appBuild: String) async throws {
        try await base.deviceTokenRegister(token: token, environment: environment, appBuild: appBuild)
    }

    public func deviceTokenUnregister(token: String) async throws {
        try await base.deviceTokenUnregister(token: token)
    }

    public func clientEvent(kind: String, props: [String: JSONValue]) async throws {
        if sandbox.hasDevPeople, DeveloperSandbox.rehearsalEventKinds.contains(kind) { return }
        try await base.clientEvent(kind: kind, props: props)
    }

    // MARK: Meets

    public func meetPropose(
        meetID: UUID, invitee: UUID, resortID: String, rendezvousID: RendezvousID,
        bundleID: BundleID?, proposerEtaS: Int, proposerEtaSdS: Int, supersedes: UUID?
    ) async throws -> Meet {
        guard DeveloperSandbox.isDevPerson(invitee) else {
            return try await base.meetPropose(
                meetID: meetID, invitee: invitee, resortID: resortID, rendezvousID: rendezvousID,
                bundleID: bundleID, proposerEtaS: proposerEtaS, proposerEtaSdS: proposerEtaSdS,
                supersedes: supersedes
            )
        }
        guard let phone = sandbox.myPhone else { throw BackendError.notFriends }
        return try await phone.meetPropose(
            meetID: meetID, invitee: invitee, resortID: resortID, rendezvousID: rendezvousID,
            bundleID: bundleID, proposerEtaS: proposerEtaS, proposerEtaSdS: proposerEtaSdS,
            supersedes: supersedes
        )
    }

    public func meetRespond(
        meetID: UUID, accept: Bool, inviteeEtaS: Int?, inviteeEtaSdS: Int?,
        declineReason: MeetDeclineReason?
    ) async throws -> Meet {
        let client: any BackendClient = await sandboxClient(forMeet: meetID) ?? base
        return try await client.meetRespond(
            meetID: meetID, accept: accept, inviteeEtaS: inviteeEtaS, inviteeEtaSdS: inviteeEtaSdS,
            declineReason: declineReason
        )
    }

    public func meetProgressUpdate(
        meetID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?, state: MeetProgressState,
        fixAt: Date
    ) async throws {
        let client: any BackendClient = await sandboxClient(forMeet: meetID) ?? base
        try await client.meetProgressUpdate(
            meetID: meetID, etaS: etaS, etaSdS: etaSdS, remainingM: remainingM, state: state, fixAt: fixAt
        )
    }

    public func meetEnd(meetID: UUID, reason: MeetEndRequest) async throws -> Meet {
        let client: any BackendClient = await sandboxClient(forMeet: meetID) ?? base
        return try await client.meetEnd(meetID: meetID, reason: reason)
    }

    /// A rehearsal under way wins: it is the meet on this phone's screen. The
    /// sandbox is asked only once a dev person has been placed, and its
    /// failure never fails the real call (startup and recovery depend on it).
    public func meetCurrent() async throws -> Meet? {
        if sandbox.mayHoldMeets, let phone = sandbox.myPhone {
            do {
                if let rehearsal = try await phone.meetCurrent() { return rehearsal }
            } catch {
                // The real answer stands on its own.
            }
        }
        return try await base.meetCurrent()
    }

    public func meetHistory(limit: Int) async throws -> [Meet] { try await base.meetHistory(limit: limit) }

    // MARK: Descents

    public func descentUpsert(_ descent: DescentUpload) async throws -> DescentUpsertResult {
        try await base.descentUpsert(descent)
    }

    public func descentDelete(descentID: UUID) async throws { try await base.descentDelete(descentID: descentID) }

    // MARK: Reads

    public func meet(id: UUID) async throws -> Meet? {
        let client: any BackendClient = await sandboxClient(forMeet: id) ?? base
        return try await client.meet(id: id)
    }

    public func meetProgress(meetID: UUID) async throws -> [MeetProgress] {
        let client: any BackendClient = await sandboxClient(forMeet: meetID) ?? base
        return try await client.meetProgress(meetID: meetID)
    }

    public func profile(id: UUID) async throws -> Profile? {
        if DeveloperSandbox.isDevPerson(id), let phone = sandbox.myPhone { return try await phone.profile(id: id) }
        let row = try await base.profile(id: id)
        if let row, await base.currentSession()?.userID == row.id { sandbox.noteOwnProfile(row) }
        return row
    }

    public func paceModel(owner: UUID) async throws -> PaceModelRow? {
        if DeveloperSandbox.isDevPerson(owner) { return nil }
        return try await base.paceModel(owner: owner)
    }

    public func descents(limit: Int) async throws -> [DescentSummary] { try await base.descents(limit: limit) }

    public func descentDetail(descentID: UUID) async throws -> DescentDetail? {
        try await base.descentDetail(descentID: descentID)
    }

    public func descentRecords(offset: Int, limit: Int) async throws -> [DescentRecord] {
        try await base.descentRecords(offset: offset, limit: limit)
    }

    public func publishedResorts() async throws -> [PublishedResort] { try await base.publishedResorts() }

    public func resortCatalog() async throws -> [PublishedResort] { try await base.resortCatalog() }

    public func resortStatus(resortID: String) async throws -> ResortStatus? {
        let status = try await base.resortStatus(resortID: resortID)
        realtime.withLock { diagnostics in
            diagnostics.lastStatusReadAt = Date()
            diagnostics.lastStatusFound = status != nil
        }
        return status
    }

    /// The pretend weather, when one is on, in place of the real row.
    public func resortConditions(resortID: String) async throws -> Conditions? {
        sandbox.shown(real: try await base.resortConditions(resortID: resortID), resortID: resortID)
    }

    public func bundleData(resortID: String, bundleID: BundleID) async throws -> Data {
        try await base.bundleData(resortID: resortID, bundleID: bundleID)
    }

    public func appConfig() async throws -> [String: JSONValue] { try await base.appConfig() }
}
