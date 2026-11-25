import Foundation
import MountainCore
import Synchronization

/// An in-memory server for package tests, the developer sandbox's rehearsal
/// partners and the staged preview; the app never signs in to it. One
/// `FakeBackend` is the shared database; each phone talks to it through its own
/// `FakeBackendClient`. The friendship and meet RPCs enforce the preconditions of
/// `backend/supabase/migrations/0004_functions.sql` and send the events the
/// triggers in `0005_triggers.sql` send, through the same envelope codec the live
/// client decodes. Each RPC body runs as one actor turn, as a transaction would.
///
/// Not modelled: push notifications, the 8 KB `client_event` size limit, the
/// pace recompute job, the display-name block list and sending email (a test
/// confirms an address with `confirmEmail`).
public actor FakeBackend {
    public struct Call: Hashable, Sendable {
        public var user: UUID?
        public var name: String
    }

    struct Resort {
        var info: PublishedResort
        var published: Bool
        var rendezvousIDs: [RendezvousID] = []
    }

    struct Descent {
        var id: UUID
        var owner: UUID
        var upload: DescentUpload
    }

    struct RateKey: Hashable {
        var user: UUID
        var bucket: String
        var window: Int
    }

    // MARK: State

    /// Server time (`public.clock()`). Tests move it with `advance(by:)`.
    public private(set) var now: Date
    public private(set) var calls: [Call] = []
    public internal(set) var clientEvents: [(user: UUID, kind: String, props: [String: JSONValue])] = []

    private var online = true
    /// `meet_progress_update` completes a meet once both skiers are `arrived`.
    /// Off, the fake is a server from before that, where the phones complete it.
    var completesMeetsOnArrival = true
    private var scriptedFailures: [String: [BackendError]] = [:]
    private var paused: Set<String> = []

    var profiles: [UUID: Profile] = [:]
    var contactHashes: [UUID: (email: String?, phone: String?)] = [:]
    var appleTokens: [String: UUID] = [:]
    /// Email accounts by lower-cased address.
    var emailAccounts: [String: (id: UUID, password: String, confirmed: Bool)] = [:]
    /// The account each outstanding link signs in, by the link's code.
    private var authLinks: [String: (user: UUID, recovery: Bool)] = [:]
    var blocks: [(blocker: UUID, blocked: UUID, at: Date)] = []
    var friendships: [UUID: Friendship] = [:]
    var meets: [UUID: Meet] = [:]
    var progress: [UUID: [UUID: MeetProgress]] = [:]
    var presence: [UUID: Presence] = [:]
    var deviceTokens: [UUID: [String: PushEnvironment]] = [:]
    var mutedPushKinds: [UUID: Set<PushKind>] = [:]
    var resorts: [String: Resort] = [:]
    var bundles: [BundleID: Data] = [:]
    var statuses: [String: ResortStatus] = [:]
    var conditions: [String: Conditions] = [:]
    var paceModels: [UUID: PaceModelRow] = [:]
    var descents: [Descent] = []
    private var rateCounts: [RateKey: Int] = [:]
    var config: [String: JSONValue] = [:]
    /// `user_reports` (0017).
    public internal(set) var reports: [FakeReport] = []
    /// The `avatars` bucket: object path → bytes.
    var avatarObjects: [String: Data] = [:]

    private let subscribers = FakeSubscribers()

    public init(now: Date = Date(timeIntervalSince1970: 1_768_438_800)) {
        self.now = now
    }

    /// A phone. Pass a user to start signed in, as after a keychain restore.
    public nonisolated func client(signedInAs user: UUID? = nil) -> FakeBackendClient {
        FakeBackendClient(backend: self, user: user)
    }

    // MARK: Scripting

    public func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    /// Offline makes every call throw `.offline`. Coming back online tells every
    /// subscriber it reconnected.
    public func setOnline(_ value: Bool) {
        let wasOnline = online
        online = value
        if value, !wasOnline { subscribers.broadcast(.reconnected) }
    }

    /// The next call with this name (the RPC or read name in snake case, such as
    /// `meet_propose` or `bundle_data`) throws instead of running.
    public func failNext(_ call: String, with error: BackendError) {
        scriptedFailures[call, default: []].append(error)
    }

    /// Calls with this name wait until `resume` or until their task is cancelled.
    public func pause(_ call: String) { paused.insert(call) }

    public func resume(_ call: String) { paused.remove(call) }

    /// Plays a server that leaves a meet active when both skiers have arrived.
    public func setCompletesMeetsOnArrival(_ value: Bool) { completesMeetsOnArrival = value }

    public func callCount(_ name: String) -> Int { calls.count { $0.name == name } }

    func enter(_ name: String, user: UUID?) async throws {
        calls.append(Call(user: user, name: name))
        while paused.contains(name) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try Task.checkCancellation()
        guard online else { throw BackendError.offline }
        if var queue = scriptedFailures[name], !queue.isEmpty {
            let error = queue.removeFirst()
            scriptedFailures[name] = queue
            throw error
        }
    }

    // MARK: Service-role actions

    /// Creates an account as the `profiles_from_auth` trigger would. `onboarded`
    /// fills the baseline speeds the app treats as "onboarding done"; a `level`
    /// sets the skill tier, hardest run and speeds onboarding would have saved
    /// (developer testing's dev people).
    @discardableResult
    public func addUser(
        id: UUID = UUID(), displayName: String = "Skier", appleToken: String? = nil,
        onboarded: Bool = true, level: SkillLevel? = nil
    ) -> UUID {
        var profile = Profile(
            id: id, displayName: displayName,
            baselineSpeeds: onboarded ? ["green": 7, "blue": 5, "black": 3] : [:],
            createdAt: now, updatedAt: now
        )
        if let level {
            profile.ability = level.ability
            profile.maxDifficulty = level.maxDifficulty
            profile.baselineSpeeds = level.baselineSpeeds
        }
        profiles[id] = profile
        if let appleToken { appleTokens[appleToken] = id }
        return id
    }

    /// An accepted friendship, as if one asked and the other accepted.
    public func makeFriends(_ a: UUID, _ b: UUID) {
        guard friendshipBetween(a, b) == nil else { return }
        let id = UUID()
        friendships[id] = Friendship(
            id: id, requesterID: a, addresseeID: b, status: .accepted, createdAt: now,
            respondedAt: now
        )
    }

    /// Where the public reads of a resort this fake lists but does not hold
    /// come from. The Debug preview stage points it at the live catalog, so
    /// every published mountain opens; tests leave it nil.
    public struct ResortSource: Sendable {
        public var bundle: @Sendable (_ resortID: String, _ bundleID: BundleID) async throws
            -> (data: Data, rendezvousIDs: [RendezvousID])
        public var status: @Sendable (_ resortID: String) async throws -> ResortStatus?
        public var conditions: @Sendable (_ resortID: String) async throws -> Conditions?

        public init(
            bundle: @escaping @Sendable (_ resortID: String, _ bundleID: BundleID) async throws
                -> (data: Data, rendezvousIDs: [RendezvousID]),
            status: @escaping @Sendable (_ resortID: String) async throws -> ResortStatus?,
            conditions: @escaping @Sendable (_ resortID: String) async throws -> Conditions?
        ) {
            self.bundle = bundle
            self.status = status
            self.conditions = conditions
        }
    }

    var resortSource: ResortSource?

    public func setResortSource(_ source: ResortSource?) { resortSource = source }

    /// Lists a published resort as a catalog row has it, bundle id included,
    /// without its bytes: `ResortSource` serves those on the first read.
    public func listResort(_ info: PublishedResort) {
        resorts[info.id] = Resort(info: info, published: true)
    }

    public func addResort(_ info: PublishedResort, published: Bool = true) {
        var info = info
        info.bundleID = nil
        info.publishedAt = nil
        resorts[info.id] = Resort(info: info, published: published)
    }

    /// `bundle_publish`: stores the bytes, moves the active pointer and invalidates
    /// open meets whose rendezvous the new catalog lacks.
    public func publishBundle(
        resortID: String, bundleID: BundleID, data: Data, rendezvousIDs: [RendezvousID]
    ) {
        guard var resort = resorts[resortID] else { return }
        bundles[bundleID] = data
        resort.info.bundleID = bundleID
        resort.info.publishedAt = now
        resort.info.builtAt = resort.info.builtAt ?? now
        resort.rendezvousIDs = rendezvousIDs
        resorts[resortID] = resort
        for meet in meets.values.sorted(by: { $0.createdAt < $1.createdAt })
        where meet.resortID == resortID && !meet.status.isTerminal
            && !rendezvousIDs.contains(meet.rendezvousID) {
            endMeet(meet.meetID, status: .invalidated, reason: .rendezvousRemoved)
        }
    }

    /// Inserts a `resort_status` row and sends `resort.status` on the resort topic.
    public func publishStatus(_ status: ResortStatus) {
        statuses[status.resortID] = status
        emit(topic: "resort:\(status.resortID)", .resortStatus(status))
    }

    public func setConditions(_ value: Conditions) { conditions[value.resortID] = value }

    public func setPaceModel(_ value: PaceModelRow) { paceModels[value.ownerID] = value }

    public func setConfig(_ key: String, _ value: JSONValue) { config[key] = value }

    /// `expire_meets()`, the cron sweep.
    @discardableResult
    public func expireMeets() -> Int {
        var count = 0
        for meet in meets.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            switch meet.status {
            case .proposed where meet.expiresAt <= now:
                endMeet(meet.meetID, status: .expired, reason: .timeout)
                count += 1
            case .active:
                let eta = Double(max(meet.proposerEtaS ?? 0, meet.inviteeEtaS ?? 0))
                let quietSince = now.addingTimeInterval(-45 * 60)
                let recent = (progress[meet.meetID] ?? [:]).values.contains {
                    ($0.updatedAt ?? .distantPast) > quietSince
                }
                if let responded = meet.respondedAt,
                   now >= responded.addingTimeInterval(eta + 45 * 60), !recent {
                    endMeet(meet.meetID, status: .expired, reason: .timeout)
                    count += 1
                }
            default:
                break
            }
        }
        return count
    }

    // MARK: Inspection

    public func storedMeet(_ id: UUID) -> Meet? { meets[id] }

    public func storedPresence(of user: UUID) -> Presence? { presence[user] }

    public func storedProfile(of user: UUID) -> Profile? { profiles[user] }

    public func deviceTokens(of user: UUID) -> [String] { (deviceTokens[user] ?? [:]).keys.sorted() }

    public nonisolated func subscriberCount(topic: String) -> Int { subscribers.count(topic: topic) }

    public nonisolated var totalSubscriberCount: Int { subscribers.total }

    // MARK: Helpers

    func uid(_ user: UUID?) throws -> UUID {
        guard let user, profiles[user] != nil else { throw BackendError.notAuthenticated }
        return user
    }

    func isBlockedBetween(_ a: UUID, _ b: UUID) -> Bool {
        blocks.contains {
            ($0.blocker == a && $0.blocked == b) || ($0.blocker == b && $0.blocked == a)
        }
    }

    func friendshipBetween(_ a: UUID, _ b: UUID) -> Friendship? {
        friendships.values.first {
            ($0.requesterID == a && $0.addresseeID == b) || ($0.requesterID == b && $0.addresseeID == a)
        }
    }

    func isAcceptedFriend(_ a: UUID, _ b: UUID) -> Bool {
        friendshipBetween(a, b)?.status == .accepted && !isBlockedBetween(a, b)
    }

    private func hasOpenMeet(_ user: UUID) -> Bool {
        meets.values.contains { !$0.status.isTerminal && $0.involves(user) }
    }

    func hasOpenMeetBetween(_ a: UUID, _ b: UUID) -> Bool {
        meets.values.contains { !$0.status.isTerminal && $0.involves(a) && $0.involves(b) }
    }

    func rateLimit(_ user: UUID, _ bucket: String, max: Int, window: TimeInterval) throws {
        let key = RateKey(
            user: user, bucket: bucket, window: Int(now.timeIntervalSince1970 / window)
        )
        rateCounts[key, default: 0] += 1
        if rateCounts[key, default: 0] > max { throw BackendError.rateLimited }
    }

    func brief(_ user: UUID, friendshipID: UUID) -> FriendEvent {
        FriendEvent(
            friendshipID: friendshipID, userID: user, displayName: profiles[user]?.displayName,
            avatarURL: profiles[user]?.avatarURL
        )
    }

    /// `public.emit`: one event through the envelope codec to a topic's subscribers.
    func emit(topic: String, _ event: ServerEvent) {
        do {
            let json = try ServerEventEnvelope(at: now, event: event).encoded()
            subscribers.send(try ServerEventEnvelope.decode(json).event, topic: topic)
        } catch {
            preconditionFailure("FakeBackend could not round-trip \(event.type): \(error)")
        }
    }

    func emit(to user: UUID, _ event: ServerEvent) {
        emit(topic: "user:\(user.uuidString.lowercased())", event)
    }

    /// A status change plus `meets_notify`: `meet.updated` to both participants.
    func endMeet(_ id: UUID, status: MeetStatus, reason: MeetEndReason, by actor: UUID? = nil) {
        guard var meet = meets[id], !meet.status.isTerminal else { return }
        meet.status = status
        meet.endReason = reason
        meet.endedAt = now
        meet.endedBy = actor
        meets[id] = meet
        emit(to: meet.proposerID, .meetUpdated(meet))
        emit(to: meet.inviteeID, .meetUpdated(meet))
    }

    func endMeetsBetween(_ a: UUID, _ b: UUID, reason: MeetEndReason, by actor: UUID? = nil) {
        for meet in meets.values where !meet.status.isTerminal && meet.involves(a) && meet.involves(b) {
            endMeet(meet.meetID, status: .invalidated, reason: reason, by: actor)
        }
    }

    /// Deletes a friendship and sends `friend.removed` to whoever did not do it.
    func deleteFriendship(_ row: Friendship, actor: UUID?) {
        friendships[row.id] = nil
        if actor != row.addresseeID {
            emit(to: row.addresseeID, .friendRemoved(brief(row.requesterID, friendshipID: row.id)))
        }
        if actor != row.requesterID {
            emit(to: row.requesterID, .friendRemoved(brief(row.addresseeID, friendshipID: row.id)))
        }
    }

    func presenceRecipients(of user: UUID, resortID: String?) -> [UUID] {
        friendships.values.compactMap { row -> UUID? in
            guard row.status == .accepted, row.requesterID == user || row.addresseeID == user
            else { return nil }
            let other = row.requesterID == user ? row.addresseeID : row.requesterID
            guard !isBlockedBetween(user, other) else { return nil }
            var sameResort = false
            if let resortID {
                let fresh = presence[other].map {
                    $0.resortID == resortID
                        && ($0.receivedAt ?? .distantPast) > now.addingTimeInterval(-15 * 60)
                } ?? false
                sameResort = profiles[other]?.currentResortID == resortID || fresh
            }
            return sameResort || hasOpenMeetBetween(user, other) ? other : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: Auth

    func signIn(appleToken: String) throws -> UUID {
        guard let user = appleTokens[appleToken], profiles[user] != nil else {
            throw BackendError.signInFailed("unknown identity token")
        }
        return user
    }

    /// Sign-up as Supabase Auth does it with confirmation on: the account and
    /// its placeholder profile exist at once, sign-in waits for the link.
    /// False makes sign-up sign in at once, as a project with email
    /// confirmation off does.
    public private(set) var emailConfirmationRequired = true

    public func setEmailConfirmationRequired(_ value: Bool) { emailConfirmationRequired = value }

    func signUp(email: String, password: String) throws -> (UUID, String?) {
        let confirmationRequired = emailConfirmationRequired
        let key = try emailKey(email)
        guard password.count >= 8 else { throw BackendError.weakPassword }
        guard emailAccounts[key] == nil else { throw BackendError.emailInUse }
        let id = UUID()
        profiles[id] = Profile(
            id: id, displayName: placeholderName(), baselineSpeeds: [:], createdAt: now, updatedAt: now
        )
        emailAccounts[key] = (id, password, !confirmationRequired)
        guard confirmationRequired else {
            confirmAddress(key, of: id)
            return (id, nil)
        }
        let code = UUID().uuidString
        authLinks[code] = (id, false)
        return (id, code)
    }

    func signIn(email: String, password: String) throws -> UUID {
        guard let account = emailAccounts[try emailKey(email)], account.password == password,
              profiles[account.id] != nil
        else { throw BackendError.invalidCredentials }
        guard account.confirmed else { throw BackendError.emailNotConfirmed }
        return account.id
    }

    /// A new link for this address: confirmation (if unconfirmed) or reset.
    /// Unknown addresses get nil and no error, as the server answers.
    func authLink(email: String, recovery: Bool) throws -> String? {
        guard let account = emailAccounts[try emailKey(email)] else { return nil }
        if !recovery && account.confirmed { return nil }
        let code = UUID().uuidString
        authLinks[code] = (account.id, recovery)
        return code
    }

    /// Test hook: the code inside the last email sent to this address.
    public private(set) var lastEmailedCode: [String: String] = [:]

    func noteEmailed(_ email: String, code: String?) {
        if let code { lastEmailedCode[email.lowercased()] = code }
    }

    /// The server's 0022/0023 triggers: a confirmed address, trimmed and
    /// lowercased as `emailKey` keeps it, becomes the account's email hash.
    private func confirmAddress(_ key: String, of user: UUID) {
        contactHashes[user] = (SHA256.hex(Data(key.utf8)), contactHashes[user]?.phone)
    }

    func openLink(code: String) throws -> UUID {
        guard let link = authLinks.removeValue(forKey: code), profiles[link.user] != nil else {
            throw BackendError.linkExpired
        }
        for (key, account) in emailAccounts where account.id == link.user {
            emailAccounts[key]?.confirmed = true
            confirmAddress(key, of: link.user)
        }
        return link.user
    }

    func updatePassword(_ caller: UUID?, password: String) throws {
        let me = try uid(caller)
        guard password.count >= 8 else { throw BackendError.weakPassword }
        for (key, account) in emailAccounts where account.id == me {
            emailAccounts[key]?.password = password
        }
    }

    func email(of user: UUID) -> String? {
        emailAccounts.first { $0.value.id == user }?.key
    }

    private func emailKey(_ email: String) throws -> String {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = key.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            throw BackendError.invalidEmail
        }
        return key
    }

    /// As `display_name_placeholder` picks one.
    private func placeholderName() -> String {
        var n = profiles.count
        while true {
            let name = "Skier \(String(format: "%06d", n % 1_000_000))"
            if !isTaken(name, by: nil) { return name }
            n += 1
        }
    }

    func isTaken(_ name: String, by user: UUID?) -> Bool {
        profiles.values.contains { $0.id != user && $0.displayName.lowercased() == name.lowercased() }
    }

    func displayNameAvailable(_ caller: UUID?, name: String) throws -> DisplayNameAvailability {
        let me = try uid(caller)
        try rateLimit(me, "display_name_available", max: 60, window: 60)
        guard case .success(let normalized) = DisplayName.validate(name) else { return .invalid }
        return isTaken(normalized, by: me) ? .taken : .available
    }

    func subscribe(topic: String) -> AsyncStream<ServerEvent> { subscribers.add(topic: topic) }
}

/// What onboarding saves for a skill tier, as the profile's `ability`,
/// `max_difficulty` and `baseline_speeds` columns. Plain values: the tiers'
/// numbers live in MeetSolver, which this package does not import.
public struct SkillLevel: Hashable, Sendable {
    public var ability: String
    public var maxDifficulty: String
    public var baselineSpeeds: [String: Double]

    public init(ability: String, maxDifficulty: String, baselineSpeeds: [String: Double]) {
        self.ability = ability
        self.maxDifficulty = maxDifficulty
        self.baselineSpeeds = baselineSpeeds
    }

    /// The same columns as a `profile_update` patch.
    public var patch: ProfilePatch {
        ProfilePatch().ability(ability).maxDifficulty(maxDifficulty).baselineSpeeds(baselineSpeeds)
    }
}

/// A `user_reports` row as the fake stores it.
public struct FakeReport: Hashable, Sendable {
    public var reporterID: UUID?
    public var reportedID: UUID?
    public var reportedName: String
    public var reportedAvatarURL: String?
    public var reason: ReportReason
    public var note: String?
    public var context: ReportContext?
    public var at: Date
}

/// Realtime fan-out. Outside the actor so a terminated stream can remove itself
/// without a task hop.
final class FakeSubscribers: Sendable {
    private let state = Mutex<[String: [UUID: AsyncStream<ServerEvent>.Continuation]]>([:])

    func add(topic: String) -> AsyncStream<ServerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self)
        state.withLock { $0[topic, default: [:]][id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { topics in
                topics[topic]?[id] = nil
                if topics[topic]?.isEmpty == true { topics[topic] = nil }
            }
        }
        return stream
    }

    func send(_ event: ServerEvent, topic: String) {
        let targets = state.withLock { Array(($0[topic] ?? [:]).values) }
        for target in targets { target.yield(event) }
    }

    func broadcast(_ event: ServerEvent) {
        let targets = state.withLock { $0.values.flatMap(\.values) }
        for target in targets { target.yield(event) }
    }

    func count(topic: String) -> Int { state.withLock { $0[topic]?.count ?? 0 } }

    var total: Int { state.withLock { $0.values.reduce(0) { $0 + $1.count } } }
}

/// One phone's connection to a `FakeBackend`.
