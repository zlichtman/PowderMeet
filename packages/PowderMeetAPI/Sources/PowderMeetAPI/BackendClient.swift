import Foundation
import MountainCore

/// Why a backend call failed. The first group is the message codes the RPCs raise
/// with errcode P0001 (`specs/03-PROTOCOL.md` section 5 and `04-SCHEMA.md` section 6).
public enum BackendError: Error, Hashable, Sendable {
    case notAuthenticated
    case invalid
    case notFound
    case rateLimited
    case notFriends
    case blocked
    case resortNotPublished
    case rendezvousUnknown
    case meetBusyProposer
    case meetBusyInvitee
    case meetNotProposed
    case meetExpired
    case meetIDTaken
    case notParticipant
    case invalidReason
    case invalidState
    /// `profile_update`: another user has this display name, ignoring case.
    case nameTaken
    /// `profile_update`: the display name contains a blocked word.
    case nameNotAllowed

    // Email accounts (Supabase Auth), not RPC codes.
    /// Wrong email or password.
    case invalidCredentials
    /// The address has not been confirmed from the sign-up email yet.
    case emailNotConfirmed
    /// Sign-up with an address that already has an account.
    case emailInUse
    case weakPassword
    case invalidEmail
    /// A confirmation or reset link that has expired, was used, or was opened
    /// on a phone that did not ask for it.
    case linkExpired
    /// Email sign-in is turned off on the server.
    case emailSignInDisabled

    case offline
    case timeout
    case server(status: Int, message: String)
    case decoding(String)
    case signInFailed(String)

    /// The typed error for a raised message code, or nil for any other text.
    public init?(code: String) {
        switch code {
        case "not_authenticated": self = .notAuthenticated
        case "invalid": self = .invalid
        case "not_found": self = .notFound
        case "rate_limited": self = .rateLimited
        case "not_friends": self = .notFriends
        case "blocked": self = .blocked
        case "resort_not_published": self = .resortNotPublished
        case "rendezvous_unknown": self = .rendezvousUnknown
        case "meet_busy_proposer": self = .meetBusyProposer
        case "meet_busy_invitee": self = .meetBusyInvitee
        case "meet_not_proposed": self = .meetNotProposed
        case "meet_expired": self = .meetExpired
        case "meet_id_taken": self = .meetIDTaken
        case "not_participant": self = .notParticipant
        case "invalid_reason": self = .invalidReason
        case "invalid_state": self = .invalidState
        case "name_taken": self = .nameTaken
        case "name_not_allowed": self = .nameNotAllowed
        default: return nil
        }
    }

    /// True when the same call may succeed later without any change to its input.
    public var isTransient: Bool {
        switch self {
        case .offline, .timeout, .rateLimited: true
        case .server(let status, _): status >= 500
        default: false
        }
    }
}

/// Everything the app asks of the server. Writes are the RPCs of
/// `backend/supabase/migrations/0004_functions.sql` and later, with the same names in camel
/// case and the same arguments; reads are the tables and views RLS opens to the
/// caller. Every call acts as the signed-in user and throws `BackendError`.
public protocol BackendClient: Sendable {
    // MARK: Auth

    /// The session restored from the keychain, or nil when signed out.
    func currentSession() async -> AuthSession?
    /// Exchanges a native Sign in with Apple identity token for a session.
    /// `fullName` is only available on first authorization; it seeds the profile.
    func signInWithApple(idToken: String, nonce: String?, fullName: String?) async throws -> AuthSession
    /// Creates an email account. With email confirmation on (the hosted
    /// project), nothing is signed in until the link in the email is opened.
    func signUp(email: String, password: String) async throws -> SignUpOutcome
    func signIn(email: String, password: String) async throws -> AuthSession
    /// Sends the sign-up confirmation email again.
    func resendConfirmation(email: String) async throws
    /// Sends a password reset email whose link opens the app
    /// (`AuthLink.recoveryRedirect`). Succeeds for unknown addresses too.
    func sendPasswordReset(email: String) async throws
    /// Signs in from a confirmation or reset link the app was opened with.
    func openAuthLink(_ url: URL) async throws -> AuthLink
    /// Sets a new password for the signed-in user.
    func updatePassword(_ password: String) async throws
    func signOut() async throws
    func authEvents() -> AsyncStream<AuthEvent>

    // MARK: Realtime

    /// Joins the caller's private topic `user:{uuid}` and returns once joined, so
    /// a write made after this call cannot race its own event. The subscription
    /// ends when the stream is terminated or its consumer is cancelled.
    func events() async throws -> AsyncStream<ServerEvent>
    /// Joins the private topic `resort:{resort_id}` (`resort.status`).
    func resortEvents(resortID: String) async throws -> AsyncStream<ServerEvent>

    // MARK: Social

    func friendRequest(user: UUID) async throws -> Friendship
    /// Accepting returns the accepted row; declining deletes it and returns the
    /// row as it was.
    func friendRespond(friendshipID: UUID, accept: Bool) async throws -> Friendship
    func friendRemove(user: UUID) async throws
    func blockUser(_ user: UUID) async throws
    func unblockUser(_ user: UUID) async throws
    /// Hashes are SHA-256 of the normalized contact, at most 50 of each.
    func findUsers(emailHashes: [String], phoneHashes: [String]) async throws -> [UserMatch]
    /// People whose display name contains `query` (0019): prefix matches
    /// first, at most 20, never the caller, anyone with a block either way, or
    /// an account still on its placeholder name. A query under 2 characters
    /// returns nothing. Rate-limited 60/min.
    func searchUsers(query: String) async throws -> [UserSearchResult]
    func socialSnapshot() async throws -> SocialSnapshot
    func profileUpdate(_ patch: ProfilePatch) async throws -> Profile
    /// Whether the caller could save this display name now.
    func displayNameAvailable(_ name: String) async throws -> DisplayNameAvailability
    func accountDelete() async throws

    // MARK: Reports and avatars (migrations 0016 and 0017)

    /// Files a report. Nobody can read reports back through the API.
    func reportUser(_ user: UUID, reason: ReportReason, note: String?, context: ReportContext?) async throws
    /// Stores a JPEG at a new path under the caller's folder of the `avatars`
    /// bucket and returns the path. It shows nowhere until `profileUpdate`
    /// saves it as `avatar_url`.
    func avatarUpload(jpeg: Data) async throws -> String
    /// Removes the caller's avatar objects, except `keeping`.
    func avatarRemove(keeping: String?) async throws
    /// The bytes of an avatar object, from its path (the bucket is public).
    func avatarData(path: String) async throws -> Data

    // MARK: Presence

    /// Dropped without error when the stored fix is under 2 s old or not older
    /// than this one.
    func presenceUpdate(_ update: PresenceUpdate) async throws
    func presenceSnapshot(resortID: String) async throws -> [Presence]
    /// Deletes the caller's presence row (`presence_clear`, 0020): sign-out,
    /// leaving a resort, the app being terminated.
    func presenceClear() async throws

    // MARK: Devices and events

    func deviceTokenRegister(token: String, environment: PushEnvironment, appBuild: String) async throws
    func deviceTokenUnregister(token: String) async throws
    /// The kinds the caller has muted; empty when every notification is on.
    func notificationPrefs() async throws -> Set<PushKind>
    /// Replaces the caller's muted kinds and returns them as stored.
    func notificationPrefsSet(muted: Set<PushKind>) async throws -> Set<PushKind>
    func clientEvent(kind: String, props: [String: JSONValue]) async throws

    // MARK: Meets

    func meetPropose(
        meetID: UUID, invitee: UUID, resortID: String, rendezvousID: RendezvousID,
        bundleID: BundleID?, proposerEtaS: Int, proposerEtaSdS: Int, supersedes: UUID?
    ) async throws -> Meet
    func meetRespond(
        meetID: UUID, accept: Bool, inviteeEtaS: Int?, inviteeEtaSdS: Int?,
        declineReason: MeetDeclineReason?
    ) async throws -> Meet
    func meetProgressUpdate(
        meetID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?, state: MeetProgressState,
        fixAt: Date
    ) async throws
    func meetEnd(meetID: UUID, reason: MeetEndRequest) async throws -> Meet
    /// The caller's non-terminal meet, or nil.
    func meetCurrent() async throws -> Meet?
    func meetHistory(limit: Int) async throws -> [Meet]

    // MARK: Descents

    func descentUpsert(_ descent: DescentUpload) async throws -> DescentUpsertResult
    func descentDelete(descentID: UUID) async throws

    // MARK: Reads

    /// One `meets` row the caller takes part in, terminal or not.
    func meet(id: UUID) async throws -> Meet?
    /// The partner's and the caller's `meet_progress` rows.
    func meetProgress(meetID: UUID) async throws -> [MeetProgress]
    /// The caller's own row or an accepted friend's; nil when RLS hides it.
    func profile(id: UUID) async throws -> Profile?
    /// The caller's or an accepted friend's learned pace, when one exists.
    func paceModel(owner: UUID) async throws -> PaceModelRow?
    func descents(limit: Int) async throws -> [DescentSummary]
    /// One of the caller's descents with its stored track and latest match, for
    /// the run detail screen. Nil when it is not the caller's or is gone.
    func descentDetail(descentID: UUID) async throws -> DescentDetail?
    /// The caller's descents with their stored tracks, newest first, one page
    /// (`offset`, at most `limit` rows), for the backup export.
    func descentRecords(offset: Int, limit: Int) async throws -> [DescentRecord]
    func publishedResorts() async throws -> [PublishedResort]
    /// Every resort in the catalog, for the picker. One with no published map
    /// has a nil `bundleID` and cannot be selected.
    func resortCatalog() async throws -> [PublishedResort]
    /// The latest `resort_status` row, or nil when none has been written.
    func resortStatus(resortID: String) async throws -> ResortStatus?
    func resortConditions(resortID: String) async throws -> Conditions?
    /// The stored (gzipped) bytes of `<resort_id>/<bundle_id>.json.gz`. The caller
    /// verifies them with `BundleLoader.load(data:expectedID:)`.
    func bundleData(resortID: String, bundleID: BundleID) async throws -> Data
    /// `app_config` as key → value (`min_app_build`).
    func appConfig() async throws -> [String: JSONValue]
}
