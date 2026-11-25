import Foundation
import MountainCore
import PowderMeetAPI
import Supabase
import Synchronization
#if canImport(os)
import os
#endif

/// The live `BackendClient`: each method is one RPC, one select or one storage
/// read against the project in `backend/supabase`. Nothing here decides anything;
/// preconditions are the database's, and its message codes come back as
/// `BackendError`.
///
/// This package is the only importer of the Supabase SDK. A real two-phone meet
/// over Realtime has not yet run through it, so the event wire format is proven
/// only against the fake (`docs/ROADMAP.md`, "Check on the mountain, in season").
public final class SupabaseBackend: BackendClient {
    public struct Configuration: Sendable {
        public var url: URL
        /// The publishable (anon) key from `Secrets.xcconfig`.
        public var publishableKey: String
        /// Sent as `x-app-build`; the server stamps presence and client events with it.
        public var appBuild: String
        /// The keychain item the auth session is kept under; nil is the SDK's
        /// default, the signed-in user's. The demo's read-only catalog client
        /// passes its own, so it never sees, refreshes or clears the real
        /// account's session.
        public var storageKey: String?

        public init(url: URL, publishableKey: String, appBuild: String, storageKey: String? = nil) {
            self.url = url
            self.publishableKey = publishableKey
            self.appBuild = appBuild
            self.storageKey = storageKey
        }
    }

    public static let bundleBucket = "resort-bundles"

    private let client: SupabaseClient
    private let session: URLSession
    /// Realtime leaves still in flight, by topic (see `subscribe(topic:)`).
    private let leaves = Mutex<[String: Task<Void, Never>]>([:])

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.session = session
        client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey,
            options: SupabaseClientOptions(
                db: .init(encoder: WireCoding.encoder(), decoder: WireCoding.decoder()),
                auth: .init(storageKey: configuration.storageKey),
                global: .init(headers: ["x-app-build": configuration.appBuild], session: session)
            )
        )
    }

    // MARK: Auth

    public func currentSession() async -> AuthSession? {
        client.auth.currentSession.map { Self.authSession($0.user) }
    }

    static func authSession(_ user: User) -> AuthSession {
        let provider: AuthSession.Provider = if case .string("email")? = user.appMetadata["provider"] {
            .email
        } else {
            .apple
        }
        return AuthSession(userID: user.id, email: user.email, provider: provider)
    }

    public func signInWithApple(idToken: String, nonce: String?, fullName: String?) async throws -> AuthSession {
        let signedIn: Session
        do {
            signedIn = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
        } catch {
            let mapped = Self.backendError(error)
            if let mapped = mapped as? BackendError, mapped.isTransient { throw mapped }
            if mapped is CancellationError { throw mapped }
            throw BackendError.signInFailed(String(describing: error))
        }
        // Apple gives the name once, outside the token. It is not written
        // here: the profile keeps its placeholder until onboarding saves the
        // name the user confirms, which the app pre-fills with this one.
        return Self.authSession(signedIn.user)
    }

    // MARK: Email accounts

    public func signUp(email: String, password: String) async throws -> SignUpOutcome {
        let response = try await authCall {
            try await self.client.auth.signUp(
                email: email, password: password, redirectTo: AuthLink.confirmRedirect
            )
        }
        switch response {
        case .session(let session):
            return .signedIn(Self.authSession(session.user))
        case .user(let user):
            // With confirmation on, an address that already has an account
            // answers with a stand-in user that has no identities, and no error.
            if user.identities?.isEmpty == true { throw BackendError.emailInUse }
            return .confirmationSent
        }
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let session = try await authCall {
            try await self.client.auth.signIn(email: email, password: password)
        }
        return Self.authSession(session.user)
    }

    public func resendConfirmation(email: String) async throws {
        try await authCall {
            try await self.client.auth.resend(
                email: email, type: .signup, emailRedirectTo: AuthLink.confirmRedirect
            )
        }
    }

    public func sendPasswordReset(email: String) async throws {
        try await authCall {
            try await self.client.auth.resetPasswordForEmail(email, redirectTo: AuthLink.recoveryRedirect)
        }
    }

    /// PKCE (the SDK's default): the link carries `?code=`, exchanged with the
    /// verifier this phone stored when it asked for the email. The reset
    /// redirect carries `type=recovery` so the app knows which link it was.
    public func openAuthLink(_ url: URL) async throws -> AuthLink {
        let session = try await authCall { try await self.client.auth.session(from: url) }
        return AuthLink(session: Self.authSession(session.user), isPasswordRecovery: AuthLink.isRecovery(url))
    }

    public func updatePassword(_ password: String) async throws {
        _ = try await authCall { try await self.client.auth.update(user: UserAttributes(password: password)) }
    }

    /// One Supabase Auth call, its refusals in plain terms.
    private func authCall<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw Self.authError(error)
        }
    }

    static func authError(_ error: any Error) -> any Error {
        guard let error = error as? AuthError else { return backendError(error) }
        switch error {
        case .weakPassword:
            return BackendError.weakPassword
        case .pkceGrantCodeExchange, .implicitGrantRedirect:
            return BackendError.linkExpired
        case .api(_, let code, _, let response):
            switch code {
            case .invalidCredentials: return BackendError.invalidCredentials
            case .emailNotConfirmed: return BackendError.emailNotConfirmed
            case .emailExists, .userAlreadyExists: return BackendError.emailInUse
            case .weakPassword, .samePassword: return BackendError.weakPassword
            case .validationFailed, ErrorCode("email_address_invalid"): return BackendError.invalidEmail
            case .overEmailSendRateLimit, .overRequestRateLimit: return BackendError.rateLimited
            case .otpExpired, .flowStateExpired, .flowStateNotFound, .badCodeVerifier: return BackendError.linkExpired
            // The built-in mailer only sends to the project team's addresses
            // until custom SMTP is set up.
            case .emailProviderDisabled, .signupDisabled, .providerDisabled,
                 ErrorCode("email_address_not_authorized"):
                return BackendError.emailSignInDisabled
            default:
                if response.statusCode == 429 { return BackendError.rateLimited }
                return backendError(error)
            }
        default:
            return backendError(error)
        }
    }

    public func signOut() async throws {
        try await call { try await self.client.auth.signOut(scope: .local) }
    }

    public func authEvents() -> AsyncStream<AuthEvent> {
        let changes = client.auth.authStateChanges
        let (stream, continuation) = AsyncStream.makeStream(of: AuthEvent.self)
        let pump = Task {
            for await change in changes where change.event == .signedOut {
                continuation.yield(.sessionExpired)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    // MARK: Realtime

    public func events() async throws -> AsyncStream<ServerEvent> {
        guard let user = client.auth.currentSession?.user.id else { throw BackendError.notAuthenticated }
        return try await subscribe(topic: "user:\(user.uuidString.lowercased())")
    }

    public func resortEvents(resortID: String) async throws -> AsyncStream<ServerEvent> {
        try await subscribe(topic: "resort:\(resortID)")
    }

    /// One private channel. Clients never send on it: every message is a
    /// `realtime.send` from a database trigger. The returned stream outlives
    /// socket drops (the SDK rejoins) and reports each rejoin as `.reconnected`.
    private func subscribe(topic: String) async throws -> AsyncStream<ServerEvent> {
        // The SDK hands out one channel per topic. While the previous
        // subscription to this topic is still leaving, it would hand back the
        // channel being removed and refuse its join (seen at launch, when the
        // app's first foreground restarts the startup load).
        while let pending = leaves.withLock({ $0[topic] }) {
            await pending.value
            leaves.withLock { if $0[topic] == pending { $0[topic] = nil } }
        }
        try Task.checkCancellation()
        let client = client
        let channel = client.channel(topic) { $0.isPrivate = true }
        let broadcasts = channel.broadcastStream(event: "*")
        let statuses = channel.statusChange
        do {
            try await call { try await channel.subscribeWithError() }
        } catch {
            leave(topic, channel)
            throw error
        }

        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self)
        let pump = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var lastResync: ContinuousClock.Instant?
                    for await message in broadcasts {
                        do {
                            if let event = try Self.event(from: message) { continuation.yield(event) }
                        } catch {
                            Self.logUnreadable(message, error)
                            // A skipped meet.updated could leave the phone showing,
                            // and sharing for, a meet that ended. A healthy channel
                            // never reconnects, so ask for the re-read a rejoin
                            // would, at most once per interval.
                            let now = ContinuousClock.now
                            if lastResync.map({ now - $0 >= Self.unreadableResyncInterval }) ?? true {
                                lastResync = now
                                continuation.yield(.reconnected)
                            }
                        }
                    }
                }
                group.addTask {
                    var dropped = false
                    for await status in statuses {
                        if status == .subscribed {
                            if dropped { continuation.yield(.reconnected) }
                            dropped = false
                        } else {
                            dropped = true
                        }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { [self] _ in
            pump.cancel()
            // Leaving the topic is the last act of this subscription.
            leave(topic, channel)
        }
        return stream
    }

    /// Removes the channel from the SDK, after any earlier leave of the same
    /// topic; the next `subscribe(topic:)` waits for it.
    private func leave(_ topic: String, _ channel: RealtimeChannelV2) {
        let client = client
        leaves.withLock { pending in
            let previous = pending[topic]
            pending[topic] = Task {
                await previous?.value
                await client.removeChannel(channel)
            }
        }
    }

    /// A broadcast frame is `{event, type, payload}`; the payload is the envelope
    /// `public.emit` built. Nil for a frame with no payload; throws for one this
    /// build cannot read, so the subscription can ask for a re-read.
    static func event(from message: JSONObject) throws -> ServerEvent? {
        guard let payload = message["payload"] else { return nil }
        return try ServerEventEnvelope.decode(try JSONEncoder().encode(payload)).event
    }

    static let unreadableResyncInterval: Duration = .seconds(30)

    #if canImport(os)
    /// The `realtime` category of `specs/07-CLIENT.md` section 5, under the
    /// app's subsystem. This package does not depend on PMLogging, so the
    /// entry reaches the system log but not the flight recorder.
    private static let realtimeLog = Logger(subsystem: "com.powdermeet.app", category: "realtime")
    #endif

    /// The frame's event name is public; why it failed may quote a value, so it is not.
    private static func logUnreadable(_ message: JSONObject, _ error: any Error) {
        #if canImport(os)
        let type = message["event"]?.stringValue ?? "?"
        realtimeLog.error("unreadable \(type, privacy: .public) frame: \(String(describing: error), privacy: .private)")
        #endif
    }

    // MARK: Social

    public func friendRequest(user: UUID) async throws -> Friendship {
        try await rpc("friend_request", ["p_user": .uuid(user)])
    }

    public func friendRespond(friendshipID: UUID, accept: Bool) async throws -> Friendship {
        try await rpc("friend_respond", ["p_friendship_id": .uuid(friendshipID), "p_accept": .bool(accept)])
    }

    public func friendRemove(user: UUID) async throws {
        try await rpcVoid("friend_remove", ["p_user": .uuid(user)])
    }

    public func blockUser(_ user: UUID) async throws {
        try await rpcVoid("block_user", ["p_user": .uuid(user)])
    }

    public func unblockUser(_ user: UUID) async throws {
        try await rpcVoid("unblock_user", ["p_user": .uuid(user)])
    }

    public func findUsers(emailHashes: [String], phoneHashes: [String]) async throws -> [UserMatch] {
        try await rpc("find_users", [
            "p_email_hashes": .array(emailHashes.map(JSONValue.string)),
            "p_phone_hashes": .array(phoneHashes.map(JSONValue.string)),
        ])
    }

    public func searchUsers(query: String) async throws -> [UserSearchResult] {
        try await rpc("search_users", ["p_query": .string(query)])
    }

    public func socialSnapshot() async throws -> SocialSnapshot {
        try await rpc("social_snapshot", [:])
    }

    public func profileUpdate(_ patch: ProfilePatch) async throws -> Profile {
        try await rpc("profile_update", ["p_patch": .object(patch.values)])
    }

    public func displayNameAvailable(_ name: String) async throws -> DisplayNameAvailability {
        let code: String = try await rpc("display_name_available", ["p_name": .string(name)])
        return DisplayNameAvailability(rawValue: code) ?? .invalid
    }

    public func accountDelete() async throws {
        try await rpcVoid("account_delete", [:])
    }

    // MARK: Reports and avatars (0016, 0017)

    public func reportUser(_ user: UUID, reason: ReportReason, note: String?, context: ReportContext?) async throws {
        try await rpcVoid("report_user", [
            "p_user": .uuid(user), "p_reason": .string(reason.rawValue),
            "p_note": note.map(JSONValue.string) ?? .null,
            "p_context": context.map { .string($0.rawValue) } ?? .null,
        ])
    }

    public static let avatarBucket = "avatars"

    /// A new object per upload, so the path names the bytes and a cached copy
    /// is never stale; it is cached for a year for the same reason.
    public func avatarUpload(jpeg: Data) async throws -> String {
        guard let me = client.auth.currentSession?.user.id else { throw BackendError.notAuthenticated }
        let path = AvatarPath.new(for: me)
        try await call {
            _ = try await self.client.storage.from(Self.avatarBucket).upload(
                path, data: jpeg,
                options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: false)
            )
        }
        return path
    }

    public func avatarRemove(keeping: String?) async throws {
        guard let me = client.auth.currentSession?.user.id else { throw BackendError.notAuthenticated }
        let folder = AvatarPath.folder(of: me)
        try await call {
            let bucket = self.client.storage.from(Self.avatarBucket)
            let paths = try await bucket.list(path: folder).map { "\(folder)/\($0.name)" }
                .filter { $0 != keeping }
            if !paths.isEmpty { _ = try await bucket.remove(paths: paths) }
        }
    }

    /// The bucket is public, so this is a plain GET that a CDN can cache.
    public func avatarData(path: String) async throws -> Data {
        try await call {
            let url = try self.client.storage.from(Self.avatarBucket).getPublicURL(path: path)
            let (data, response) = try await self.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 404 || status == 400 { throw BackendError.notFound }
                throw BackendError.server(status: status, message: "avatar download")
            }
            return data
        }
    }

    // MARK: Presence

    public func presenceUpdate(_ update: PresenceUpdate) async throws {
        // Every argument is sent, null included: the function has no defaults.
        try await rpcVoid("presence_update", [
            "p_resort_id": update.resortID.map(JSONValue.string) ?? .null,
            "p_lon": .number(update.lon),
            "p_lat": .number(update.lat),
            "p_accuracy_m": update.accuracyM.map(JSONValue.number) ?? .null,
            "p_speed_ms": update.speedMS.map(JSONValue.number) ?? .null,
            "p_heading_deg": update.headingDeg.map(JSONValue.number) ?? .null,
            "p_captured_at": .date(update.capturedAt),
        ])
    }

    public func presenceSnapshot(resortID: String) async throws -> [PowderMeetAPI.Presence] {
        try await rpc("presence_snapshot", ["p_resort_id": .string(resortID)])
    }

    public func presenceClear() async throws {
        try await rpcVoid("presence_clear", [:])
    }

    // MARK: Devices and events

    public func deviceTokenRegister(token: String, environment: PushEnvironment, appBuild: String) async throws {
        try await rpcVoid("device_token_register", [
            "p_token": .string(token), "p_environment": .string(environment.rawValue),
            "p_app_build": .string(appBuild),
        ])
    }

    public func deviceTokenUnregister(token: String) async throws {
        try await rpcVoid("device_token_unregister", ["p_token": .string(token)])
    }

    public func notificationPrefs() async throws -> Set<PushKind> {
        let kinds: [String] = try await rpc("notification_prefs", [:])
        return Set(kinds.compactMap(PushKind.init(rawValue:)))
    }

    public func notificationPrefsSet(muted: Set<PushKind>) async throws -> Set<PushKind> {
        let kinds: [String] = try await rpc("notification_prefs_set", [
            "p_muted": .array(muted.map(\.rawValue).sorted().map(JSONValue.string)),
        ])
        return Set(kinds.compactMap(PushKind.init(rawValue:)))
    }

    public func clientEvent(kind: String, props: [String: JSONValue]) async throws {
        try await rpcVoid("client_event", ["p_kind": .string(kind), "p_props": .object(props)])
    }

    // MARK: Meets

    public func meetPropose(
        meetID: UUID, invitee: UUID, resortID: String, rendezvousID: RendezvousID,
        bundleID: BundleID?, proposerEtaS: Int, proposerEtaSdS: Int, supersedes: UUID?
    ) async throws -> Meet {
        try await rpc("meet_propose", [
            "p_meet_id": .uuid(meetID), "p_invitee": .uuid(invitee), "p_resort_id": .string(resortID),
            "p_rendezvous_id": .string(rendezvousID.rawValue),
            "p_bundle_id": bundleID.map { .string($0.rawValue) } ?? .null,
            "p_proposer_eta_s": .int(proposerEtaS), "p_proposer_eta_sd_s": .int(proposerEtaSdS),
            "p_supersedes": supersedes.map(JSONValue.uuid) ?? .null,
        ])
    }

    public func meetRespond(
        meetID: UUID, accept: Bool, inviteeEtaS: Int?, inviteeEtaSdS: Int?,
        declineReason: MeetDeclineReason?
    ) async throws -> Meet {
        try await rpc("meet_respond", [
            "p_meet_id": .uuid(meetID), "p_accept": .bool(accept),
            "p_invitee_eta_s": inviteeEtaS.map(JSONValue.int) ?? .null,
            "p_invitee_eta_sd_s": inviteeEtaSdS.map(JSONValue.int) ?? .null,
            "p_decline_reason": declineReason.map { .string($0.rawValue) } ?? .null,
        ])
    }

    public func meetProgressUpdate(
        meetID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?, state: MeetProgressState,
        fixAt: Date
    ) async throws {
        try await rpcVoid("meet_progress_update", [
            "p_meet_id": .uuid(meetID),
            "p_eta_s": etaS.map(JSONValue.int) ?? .null,
            "p_eta_sd_s": etaSdS.map(JSONValue.int) ?? .null,
            "p_remaining_m": remainingM.map(JSONValue.int) ?? .null,
            "p_state": .string(state.rawValue), "p_fix_at": .date(fixAt),
        ])
    }

    public func meetEnd(meetID: UUID, reason: MeetEndRequest) async throws -> Meet {
        try await rpc("meet_end", ["p_meet_id": .uuid(meetID), "p_reason": .string(reason.rawValue)])
    }

    public func meetCurrent() async throws -> Meet? {
        // A function returning a composite type answers "no row" either as JSON
        // null or as an object whose fields are all null, depending on PostgREST.
        let value: JSONValue = try await rpc("meet_current", [:])
        guard case .object(let fields) = value, let id = fields["meet_id"], id != .null else { return nil }
        return try Self.decode(Meet.self, from: try WireCoding.encoder().encode(value))
    }

    public func meetHistory(limit: Int) async throws -> [Meet] {
        try await rpc("meet_history", ["p_limit": .int(limit)])
    }

    // MARK: Descents

    public func descentUpsert(_ descent: DescentUpload) async throws -> DescentUpsertResult {
        // `track` is bytes; JSON carries it as base64, which is what the function decodes.
        let body = try Self.decode(JSONValue.self, from: try WireCoding.encoder().encode(descent))
        let rows: [DescentUpsertResult] = try await rpc("descent_upsert", ["p_descent": body])
        guard let row = rows.first else { throw BackendError.decoding("descent_upsert returned no row") }
        return row
    }

    public func descentDelete(descentID: UUID) async throws {
        try await rpcVoid("descent_delete", ["p_descent_id": .uuid(descentID)])
    }

    // MARK: Reads

    public func meet(id: UUID) async throws -> Meet? {
        let rows: [Meet] = try await select {
            $0.from("meets").select().eq("meet_id", value: id).limit(1)
        }
        return rows.first
    }

    public func meetProgress(meetID: UUID) async throws -> [MeetProgress] {
        try await select { $0.from("meet_progress").select().eq("meet_id", value: meetID) }
    }

    public func profile(id: UUID) async throws -> Profile? {
        let rows: [Profile] = try await select {
            $0.from("profiles").select(Profile.columns).eq("id", value: id).limit(1)
        }
        guard var profile = rows.first else { return nil }
        // Height and weight have no column grant; the owner's come from their
        // own RPC and nobody else's can be asked for.
        if client.auth.currentSession?.user.id == id {
            let body: ProfilePrivate = try await rpc("profile_private", [:])
            profile.heightCM = body.heightCM
            profile.weightKG = body.weightKG
        }
        return profile
    }

    public func paceModel(owner: UUID) async throws -> PaceModelRow? {
        let rows: [PaceModelRow] = try await select {
            $0.from("pace_models_friend_read").select().eq("owner_id", value: owner).limit(1)
        }
        return rows.first
    }

    public func descents(limit: Int) async throws -> [DescentSummary] {
        try await select {
            $0.from("descents").select(DescentSummary.columns)
                .order("started_at", ascending: false).limit(limit)
        }
    }

    public func descentDetail(descentID: UUID) async throws -> DescentDetail? {
        struct TrackRow: Decodable { var track: String? }
        // The match is what the screen is for; the track only draws the
        // small map, so its failure costs the drawing and nothing else.
        let matches: [DescentUpload.Match] = try await select {
            $0.from("descent_matches").select("bundle_id,matcher_version,matched,coverage,confidence")
                .eq("descent_id", value: descentID).order("created_at", ascending: false).limit(1)
        }
        let track: Data?
        do {
            let tracks: [TrackRow] = try await select {
                $0.from("descents").select("track").eq("descent_id", value: descentID).limit(1)
            }
            guard let row = tracks.first else { return nil }
            track = row.track.flatMap(Self.bytea)
        } catch {
            guard !matches.isEmpty else { throw error }
            track = nil
        }
        return DescentDetail(descentID: descentID, track: track, match: matches.first)
    }

    public func descentRecords(offset: Int, limit: Int) async throws -> [DescentRecord] {
        struct TrackRow: Decodable { var track: String? }
        guard limit > 0 else { return [] }
        let data = try await call {
            try await self.client.from("descents").select(DescentSummary.columns + ",track")
                .order("started_at", ascending: false).order("descent_id")
                .range(from: max(offset, 0), to: max(offset, 0) + limit - 1)
                .execute().data
        }
        let summaries = try Self.decode([DescentSummary].self, from: data)
        let tracks = try Self.decode([TrackRow].self, from: data)
        // A row that cannot be read fails the page: dropping it would end the
        // export early and lose every run after it.
        guard summaries.count == tracks.count else { throw BackendError.decoding("descent records") }
        return try zip(summaries, tracks).map { summary, row in
            guard let track = row.track.flatMap(Self.bytea) else {
                throw BackendError.decoding("descent \(summary.descentID) track")
            }
            return DescentRecord(summary: summary, track: track)
        }
    }

    /// PostgREST sends `bytea` as a backslash, `x` and hex digits.
    static func bytea(_ text: String) -> Data? {
        guard text.hasPrefix("\\x") else { return Data(base64Encoded: text) }
        let hex = Array(text.utf8.dropFirst(2))
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        var index = 0
        while index < hex.count {
            guard let high = value(hex[index]), let low = value(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    public func publishedResorts() async throws -> [PublishedResort] {
        try await select { $0.from("published_resorts").select().order("name") }
    }

    /// `resort_catalog` arrives with migration 0012. Against a database that
    /// does not have it yet the picker falls back to the published resorts,
    /// which is everything selectable anyway.
    public func resortCatalog() async throws -> [PublishedResort] {
        do {
            return try await select { $0.from("resort_catalog").select().order("name") }
        } catch BackendError.notFound {
            return try await publishedResorts()
        }
    }

    public func resortStatus(resortID: String) async throws -> ResortStatus? {
        let rows: [ResortStatus] = try await select {
            $0.from("resort_status_current").select().eq("resort_id", value: resortID).limit(1)
        }
        return rows.first
    }

    public func resortConditions(resortID: String) async throws -> Conditions? {
        let rows: [Conditions] = try await select {
            $0.from("resort_conditions_current").select().eq("resort_id", value: resortID).limit(1)
        }
        return rows.first
    }

    /// `resort-bundles` is public-read, so this is a plain GET of
    /// `<resort_id>/<bundle_id>.json.gz` that a CDN can cache. The name is the
    /// SHA-256 of the bytes; the caller checks it.
    public func bundleData(resortID: String, bundleID: BundleID) async throws -> Data {
        try await call {
            let url = try self.client.storage.from(Self.bundleBucket)
                .getPublicURL(path: "\(resortID)/\(bundleID.rawValue).json.gz")
            let (data, response) = try await self.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 404 || status == 400 { throw BackendError.notFound }
                throw BackendError.server(status: status, message: "bundle download")
            }
            return data
        }
    }

    public func appConfig() async throws -> [String: JSONValue] {
        struct Row: Decodable {
            var key: String
            var value: JSONValue
        }
        let rows: [Row] = try await select { $0.from("app_config").select() }
        return Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Plumbing

    private func rpc<Value: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> Value {
        try await call {
            let response = try await self.client.rpc(name, params: params).execute()
            return try Self.decode(Value.self, from: response.data)
        }
    }

    private func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {
        try await call {
            _ = try await self.client.rpc(name, params: params).execute()
        }
    }

    private func select<Value: Decodable>(
        _ query: @Sendable (SupabaseClient) -> PostgrestTransformBuilder
    ) async throws -> Value {
        try await call {
            try Self.decode(Value.self, from: try await query(self.client).execute().data)
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try WireCoding.decoder().decode(type, from: data)
        } catch {
            throw BackendError.decoding(String(describing: error))
        }
    }

    /// Runs one request and turns whatever it throws into `BackendError`
    /// (or `CancellationError`, which passes through).
    private func call<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw Self.backendError(error)
        }
    }

    /// PGRST000-003: no connection, the pool timed out or the schema cache is
    /// reloading. SQLSTATE 57014 a statement timeout, 57P0x a restart, class
    /// 53 out of resources, class 08 a lost connection, 40001 and 40P01 a
    /// serialization failure or deadlock.
    static func isTransientPostgrestCode(_ code: String) -> Bool {
        if ["PGRST000", "PGRST001", "PGRST002", "PGRST003", "57014", "40001", "40P01"].contains(code) {
            return true
        }
        return code.count == 5 && (code.hasPrefix("57P") || code.hasPrefix("53") || code.hasPrefix("08"))
    }

    static func backendError(_ error: any Error) -> any Error {
        switch error {
        case let error as BackendError:
            return error
        case is CancellationError:
            return error
        case let error as PostgrestError:
            // RPCs raise with errcode P0001 and a message code as the message.
            if let typed = BackendError(code: error.message) { return typed }
            // The relation or function is not in the schema (cache): an older database.
            if error.code == "PGRST205" || error.code == "PGRST202" || error.code == "42P01" {
                return BackendError.notFound
            }
            if error.code == "PGRST301" || error.code == "PGRST302" || error.message.contains("JWT") {
                return BackendError.notAuthenticated
            }
            // PostgREST answers these with a 5xx the SDK does not pass on: the
            // pool, the schema cache or the database is busy for a moment, so
            // the request is worth sending again.
            if let code = error.code, Self.isTransientPostgrestCode(code) {
                return BackendError.server(status: 503, message: "\(code): \(error.message)")
            }
            // SQLSTATE classes 22 and 23: the row itself is bad (a value out of
            // range, a constraint), so sending it again cannot pass. 422 tells
            // the outbox to set it aside; any other code may be the server's
            // fault and is retried.
            let rowIsBad = error.code.map { $0.count == 5 && ($0.hasPrefix("22") || $0.hasPrefix("23")) } ?? false
            return BackendError.server(
                status: rowIsBad ? 422 : 400, message: "\(error.code ?? "?"): \(error.message)"
            )
        case let error as URLError:
            switch error.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return BackendError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return BackendError.offline
            default:
                return BackendError.server(status: 0, message: error.localizedDescription)
            }
        case let error as AuthError:
            switch error {
            case .sessionMissing, .refreshDiscarded:
                return BackendError.notAuthenticated
            case .api(let message, let code, _, let response):
                // A refresh token the server no longer accepts answers 400, not
                // 401: without this the app would sit on "couldn't load" with
                // RETRY for ever instead of returning to sign-in.
                let ended: Set<ErrorCode> = [
                    .sessionNotFound, .sessionExpired, .refreshTokenNotFound,
                    .refreshTokenAlreadyUsed, .userNotFound, .userBanned, .badJWT, .noAuthorization,
                ]
                return response.statusCode == 401 || response.statusCode == 403 || ended.contains(code)
                    ? BackendError.notAuthenticated
                    : BackendError.server(status: response.statusCode, message: message)
            default:
                return BackendError.server(status: 0, message: error.message)
            }
        case let error as HTTPError:
            switch error.response.statusCode {
            case 401: return BackendError.notAuthenticated
            case 404: return BackendError.notFound
            default: return BackendError.server(status: error.response.statusCode, message: "http")
            }
        case let error as StorageError:
            return error.statusCode == "404"
                ? BackendError.notFound
                : BackendError.server(status: Int(error.statusCode ?? "") ?? 0, message: error.message)
        case is DecodingError:
            return BackendError.decoding(String(describing: error))
        default:
            return BackendError.server(status: 0, message: String(describing: error))
        }
    }
}

private extension JSONValue {
    /// Postgres prints and accepts uuids in lower case.
    static func uuid(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }
    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    static func date(_ value: Date) -> JSONValue { .string(WireCoding.string(from: value)) }
}
