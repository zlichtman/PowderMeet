import Foundation
import MountainCore
import Synchronization

public final class FakeBackendClient: BackendClient {
    private let backend: FakeBackend
    private let user: Mutex<UUID?>
    private let authContinuations = Mutex<[UUID: AsyncStream<AuthEvent>.Continuation]>([:])

    init(backend: FakeBackend, user: UUID?) {
        self.backend = backend
        self.user = Mutex(user)
    }

    private var me: UUID? { user.withLock { $0 } }

    /// Test hook: the refresh token was rejected.
    public func expireSession() {
        user.withLock { $0 = nil }
        let targets = authContinuations.withLock { Array($0.values) }
        for target in targets { target.yield(.sessionExpired) }
    }

    // MARK: Auth

    public func currentSession() async -> AuthSession? {
        guard let me else { return nil }
        return await session(for: me)
    }

    private func session(for user: UUID) async -> AuthSession {
        if let email = await backend.email(of: user) {
            return AuthSession(userID: user, email: email, provider: .email)
        }
        return AuthSession(userID: user)
    }

    public func signUp(email: String, password: String) async throws -> SignUpOutcome {
        try await backend.enter("sign_up", user: nil)
        let (id, code) = try await backend.signUp(email: email, password: password)
        guard code == nil else {
            await backend.noteEmailed(email, code: code)
            return .confirmationSent
        }
        user.withLock { $0 = id }
        return .signedIn(await session(for: id))
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try await backend.enter("sign_in_with_password", user: nil)
        let id = try await backend.signIn(email: email, password: password)
        user.withLock { $0 = id }
        return await session(for: id)
    }

    public func resendConfirmation(email: String) async throws {
        try await backend.enter("resend", user: nil)
        await backend.noteEmailed(email, code: try await backend.authLink(email: email, recovery: false))
    }

    public func sendPasswordReset(email: String) async throws {
        try await backend.enter("recover", user: nil)
        await backend.noteEmailed(email, code: try await backend.authLink(email: email, recovery: true))
    }

    /// The link's code is its `code` query item, as in the PKCE flow.
    public func openAuthLink(_ url: URL) async throws -> AuthLink {
        try await backend.enter("open_auth_link", user: nil)
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw BackendError.linkExpired }
        let id = try await backend.openLink(code: code)
        user.withLock { $0 = id }
        return AuthLink(session: await session(for: id), isPasswordRecovery: AuthLink.isRecovery(url))
    }

    public func updatePassword(_ password: String) async throws {
        try await backend.enter("update_user", user: me)
        try await backend.updatePassword(me, password: password)
    }

    public func signInWithApple(idToken: String, nonce: String?, fullName: String?) async throws -> AuthSession {
        try await backend.enter("sign_in_with_apple", user: nil)
        let id = try await backend.signIn(appleToken: idToken)
        user.withLock { $0 = id }
        return AuthSession(userID: id)
    }

    public func signOut() async throws {
        try await backend.enter("sign_out", user: me)
        user.withLock { $0 = nil }
    }

    public func authEvents() -> AsyncStream<AuthEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AuthEvent.self)
        authContinuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.authContinuations.withLock { $0[id] = nil }
        }
        return stream
    }

    // MARK: Realtime

    public func events() async throws -> AsyncStream<ServerEvent> {
        try await backend.enter("subscribe_user", user: me)
        guard let me else { throw BackendError.notAuthenticated }
        return await backend.subscribe(topic: "user:\(me.uuidString.lowercased())")
    }

    public func resortEvents(resortID: String) async throws -> AsyncStream<ServerEvent> {
        try await backend.enter("subscribe_resort", user: me)
        guard me != nil else { throw BackendError.notAuthenticated }
        return await backend.subscribe(topic: "resort:\(resortID)")
    }

    // MARK: Social

    public func friendRequest(user: UUID) async throws -> Friendship {
        try await backend.enter("friend_request", user: me)
        return try await backend.friendRequest(me, user: user)
    }

    public func friendRespond(friendshipID: UUID, accept: Bool) async throws -> Friendship {
        try await backend.enter("friend_respond", user: me)
        return try await backend.friendRespond(me, friendshipID: friendshipID, accept: accept)
    }

    public func friendRemove(user: UUID) async throws {
        try await backend.enter("friend_remove", user: me)
        try await backend.friendRemove(me, user: user)
    }

    public func blockUser(_ user: UUID) async throws {
        try await backend.enter("block_user", user: me)
        try await backend.blockUser(me, user: user)
    }

    public func unblockUser(_ user: UUID) async throws {
        try await backend.enter("unblock_user", user: me)
        try await backend.unblockUser(me, user: user)
    }

    public func findUsers(emailHashes: [String], phoneHashes: [String]) async throws -> [UserMatch] {
        try await backend.enter("find_users", user: me)
        return try await backend.findUsers(me, emailHashes: emailHashes, phoneHashes: phoneHashes)
    }

    public func searchUsers(query: String) async throws -> [UserSearchResult] {
        try await backend.enter("search_users", user: me)
        return try await backend.searchUsers(me, query: query)
    }

    public func socialSnapshot() async throws -> SocialSnapshot {
        try await backend.enter("social_snapshot", user: me)
        return try await backend.socialSnapshot(me)
    }

    public func profileUpdate(_ patch: ProfilePatch) async throws -> Profile {
        try await backend.enter("profile_update", user: me)
        return try await backend.profileUpdate(me, patch: patch)
    }

    public func displayNameAvailable(_ name: String) async throws -> DisplayNameAvailability {
        try await backend.enter("display_name_available", user: me)
        return try await backend.displayNameAvailable(me, name: name)
    }

    public func accountDelete() async throws {
        try await backend.enter("account_delete", user: me)
        try await backend.accountDelete(me)
    }

    // MARK: Reports and avatars

    public func reportUser(_ user: UUID, reason: ReportReason, note: String?, context: ReportContext?) async throws {
        try await backend.enter("report_user", user: me)
        try await backend.reportUser(me, user: user, reason: reason, note: note, context: context)
    }

    public func avatarUpload(jpeg: Data) async throws -> String {
        try await backend.enter("avatar_upload", user: me)
        return try await backend.avatarUpload(me, jpeg: jpeg)
    }

    public func avatarRemove(keeping: String?) async throws {
        try await backend.enter("avatar_remove", user: me)
        try await backend.avatarRemove(me, keeping: keeping)
    }

    public func avatarData(path: String) async throws -> Data {
        try await backend.enter("avatar_data", user: me)
        return try await backend.avatarData(path: path)
    }

    // MARK: Presence

    public func presenceUpdate(_ update: PresenceUpdate) async throws {
        try await backend.enter("presence_update", user: me)
        try await backend.presenceUpdate(me, update: update)
    }

    public func presenceSnapshot(resortID: String) async throws -> [Presence] {
        try await backend.enter("presence_snapshot", user: me)
        return try await backend.presenceSnapshot(me, resortID: resortID)
    }

    public func presenceClear() async throws {
        try await backend.enter("presence_clear", user: me)
        try await backend.presenceClear(me)
    }

    // MARK: Devices and events

    public func deviceTokenRegister(token: String, environment: PushEnvironment, appBuild: String) async throws {
        try await backend.enter("device_token_register", user: me)
        try await backend.deviceTokenRegister(me, token: token, environment: environment)
    }

    public func deviceTokenUnregister(token: String) async throws {
        try await backend.enter("device_token_unregister", user: me)
        try await backend.deviceTokenUnregister(me, token: token)
    }

    public func notificationPrefs() async throws -> Set<PushKind> {
        try await backend.enter("notification_prefs", user: me)
        return try await backend.notificationPrefs(me)
    }

    public func notificationPrefsSet(muted: Set<PushKind>) async throws -> Set<PushKind> {
        try await backend.enter("notification_prefs_set", user: me)
        return try await backend.notificationPrefsSet(me, muted: muted)
    }

    public func clientEvent(kind: String, props: [String: JSONValue]) async throws {
        try await backend.enter("client_event", user: me)
        try await backend.clientEvent(me, kind: kind, props: props)
    }

    // MARK: Meets

    public func meetPropose(
        meetID: UUID, invitee: UUID, resortID: String, rendezvousID: RendezvousID,
        bundleID: BundleID?, proposerEtaS: Int, proposerEtaSdS: Int, supersedes: UUID?
    ) async throws -> Meet {
        try await backend.enter("meet_propose", user: me)
        return try await backend.meetPropose(
            me, meetID: meetID, invitee: invitee, resortID: resortID, rendezvousID: rendezvousID,
            bundleID: bundleID, etaS: proposerEtaS, etaSdS: proposerEtaSdS, supersedes: supersedes
        )
    }

    public func meetRespond(
        meetID: UUID, accept: Bool, inviteeEtaS: Int?, inviteeEtaSdS: Int?,
        declineReason: MeetDeclineReason?
    ) async throws -> Meet {
        try await backend.enter("meet_respond", user: me)
        return try await backend.meetRespond(
            me, meetID: meetID, accept: accept, etaS: inviteeEtaS, etaSdS: inviteeEtaSdS,
            declineReason: declineReason
        )
    }

    public func meetProgressUpdate(
        meetID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?, state: MeetProgressState,
        fixAt: Date
    ) async throws {
        try await backend.enter("meet_progress_update", user: me)
        try await backend.meetProgressUpdate(
            me, meetID: meetID, etaS: etaS, etaSdS: etaSdS, remainingM: remainingM, state: state,
            fixAt: fixAt
        )
    }

    public func meetEnd(meetID: UUID, reason: MeetEndRequest) async throws -> Meet {
        try await backend.enter("meet_end", user: me)
        return try await backend.meetEnd(me, meetID: meetID, reason: reason)
    }

    public func meetCurrent() async throws -> Meet? {
        try await backend.enter("meet_current", user: me)
        return try await backend.meetCurrent(me)
    }

    public func meetHistory(limit: Int) async throws -> [Meet] {
        try await backend.enter("meet_history", user: me)
        return try await backend.meetHistory(me, limit: limit)
    }

    // MARK: Descents

    public func descentUpsert(_ descent: DescentUpload) async throws -> DescentUpsertResult {
        try await backend.enter("descent_upsert", user: me)
        return try await backend.descentUpsert(me, upload: descent)
    }

    public func descentDelete(descentID: UUID) async throws {
        try await backend.enter("descent_delete", user: me)
        try await backend.descentDelete(me, descentID: descentID)
    }

    // MARK: Reads

    public func meet(id: UUID) async throws -> Meet? {
        try await backend.enter("meet", user: me)
        return await backend.readMeet(me, id: id)
    }

    public func meetProgress(meetID: UUID) async throws -> [MeetProgress] {
        try await backend.enter("meet_progress", user: me)
        return await backend.readMeetProgress(me, meetID: meetID)
    }

    public func profile(id: UUID) async throws -> Profile? {
        try await backend.enter("profile", user: me)
        return await backend.readProfile(me, id: id)
    }

    public func paceModel(owner: UUID) async throws -> PaceModelRow? {
        try await backend.enter("pace_model", user: me)
        return await backend.readPaceModel(me, owner: owner)
    }

    public func descents(limit: Int) async throws -> [DescentSummary] {
        try await backend.enter("descents", user: me)
        return await backend.readDescents(me, limit: limit)
    }

    public func descentDetail(descentID: UUID) async throws -> DescentDetail? {
        try await backend.enter("descent_detail", user: me)
        return await backend.readDescentDetail(me, descentID: descentID)
    }

    public func descentRecords(offset: Int, limit: Int) async throws -> [DescentRecord] {
        try await backend.enter("descent_records", user: me)
        return await backend.readDescentRecords(me, offset: offset, limit: limit)
    }

    public func publishedResorts() async throws -> [PublishedResort] {
        try await backend.enter("published_resorts", user: me)
        return await backend.readPublishedResorts()
    }

    public func resortCatalog() async throws -> [PublishedResort] {
        try await backend.enter("resort_catalog", user: me)
        return await backend.readResortCatalog()
    }

    public func resortStatus(resortID: String) async throws -> ResortStatus? {
        try await backend.enter("resort_status", user: me)
        return try await backend.serveStatus(resortID: resortID)
    }

    public func resortConditions(resortID: String) async throws -> Conditions? {
        try await backend.enter("resort_conditions", user: me)
        return try await backend.serveConditions(resortID: resortID)
    }

    public func bundleData(resortID: String, bundleID: BundleID) async throws -> Data {
        try await backend.enter("bundle_data", user: me)
        return try await backend.serveBundle(resortID: resortID, bundleID)
    }

    public func appConfig() async throws -> [String: JSONValue] {
        try await backend.enter("app_config", user: me)
        return await backend.readConfig()
    }
}
