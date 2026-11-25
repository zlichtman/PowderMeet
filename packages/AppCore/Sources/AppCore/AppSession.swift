import Foundation
import MountainCore
import PMLogging
import PowderMeetAPI

/// The signed-in user on this phone (`specs/07-CLIENT.md` section 1). It owns the
/// one private realtime subscription, the social snapshot and at most one
/// `ResortSession`.
///
/// `run()` lasts as long as the app. Everything that exists only while signed in
/// is an effect task started at sign-in; sign-out cancels and awaits those tasks,
/// so a signed-out session has nothing running and nothing left to go stale.
public actor AppSession {
    public enum SignOutReason: Sendable, Hashable {
        case noSession, userRequested, sessionExpired, accountDeleted
    }

    public enum State: Sendable, Hashable {
        case starting
        case ready(Profile)
        case needsOnboarding
        case signedOut(SignOutReason)
        case failed(PowderMeetError)
    }

    /// The connection to the server, as the user should hear about it: one
    /// value, so the app shows one notice. `reconnecting` lasts from the network
    /// coming back until the server has answered again. `unconfirmed` is a
    /// network that is up with a server that did not answer properly: there is
    /// nothing useful to tell the user, so no notice is shown for it (not
    /// "reconnecting" for ever, and not "back online", which would be untrue).
    public enum Link: Sendable, Hashable {
        case online, offline, reconnecting, unconfirmed
    }

    /// What sign-in loads before the session is usable.
    public struct Startup: Sendable {
        public var profile: Profile
        public var social: SocialSnapshot
        public var registeredToken: String?
        public var meet: Meet?
    }

    public enum FriendIntent: Sendable, Hashable {
        case request(UUID)
        case respond(friendshipID: UUID, accept: Bool)
        case remove(UUID)
        case block(UUID)
        case unblock(UUID)
    }

    public enum Event: Sendable {
        case signedIn(AuthSession)
        /// A confirmation or reset link signed this phone in, possibly as
        /// someone other than the current user.
        case linkOpened(AuthSession)
        case profileLoaded(Startup)
        case startupFailed(PowderMeetError)
        /// Saves the onboarding answers; the profile then counts as complete.
        case onboardingDone(ProfilePatch)
        case profileEdited(ProfilePatch)
        case resortSelected(String)
        case resortCleared
        case serverEvent(ServerEvent)
        case reachability(Bool)
        case friend(FriendIntent)
        /// A snapshot read for this user: a link that replaced the account can
        /// follow one read for the account before.
        case socialLoaded(SocialSnapshot, for: UUID)
        /// Read the social snapshot again (a friend card opened, a request sent by code).
        case socialRefreshRequested
        /// The result of `meet_current()` after a reconnect or foreground.
        case recovered(Meet?)
        /// `meet_current()` failed in a way that asking again will not fix.
        case recoverGaveUp
        /// The app came to the foreground.
        case foregrounded
        /// The app left the foreground: the resort stops work that only
        /// matters on screen (prefetching) and publishes less often.
        case backgrounded
        case retry
        case signOutRequested
        case deleteAccountRequested
        case tokenExpired
        /// APNs gave this phone a token after startup: permission granted
        /// later, a slow first answer, or a token iOS replaced.
        case deviceTokenChanged(DeviceToken)
        case deviceTokenRegistered(String)
    }

    public private(set) var state: State = .starting
    public private(set) var social = SocialSnapshot()
    public private(set) var resortSession: ResortSession?
    public private(set) var isOnline = true
    public private(set) var link = Link.online

    private let deps: Dependencies
    private var auth: AuthSession?
    private var profile: Profile?
    private var registeredToken: String?
    /// The session is showing a cached profile and the server has not confirmed
    /// it yet (the startup load is running, or failed for lack of a network).
    private var awaitingStartup = false
    private var appActive = true
    /// The server half of a user-requested sign-out, while it runs.
    private var signingOut: Task<Void, Never>?

    private var bag: TaskBag
    private let changes = Multicast<State>()
    private let socialChanges = Multicast<SocialSnapshot>()
    private let resortChanges = Multicast<ResortSession?>()
    private let linkChanges = Multicast<Link>()
    private let mailbox: AsyncStream<Event>
    private let inbox: AsyncStream<Event>.Continuation

    public init(dependencies: Dependencies) {
        deps = dependencies
        bag = TaskBag(census: dependencies.census)
        (mailbox, inbox) = AsyncStream.makeStream(of: Event.self)
    }

    public nonisolated func send(_ event: Event) {
        inbox.yield(event)
    }

    public func states() -> AsyncStream<State> { changes.stream(initial: state) }

    public func socialUpdates() -> AsyncStream<SocialSnapshot> { socialChanges.stream(initial: social) }

    /// The current resort session (or nil), then every replacement.
    public func resortSessions() -> AsyncStream<ResortSession?> {
        resortChanges.stream(initial: resortSession)
    }

    public func links() -> AsyncStream<Link> { linkChanges.stream(initial: link) }

    /// The signed-in user, or nil.
    public var userID: UUID? { auth?.userID }

    /// The profile as saved so far, also while onboarding is unfinished, when
    /// `State` carries none: onboarding's photo step shows the photo from it.
    public var profileOnFile: Profile? { profile }

    /// The signed-in account (email and how it signs in), or nil.
    public var account: AuthSession? { auth }

    // MARK: Intents that return a value

    /// Exchanges the Apple identity token for a session and starts it.
    public nonisolated func signInWithApple(
        idToken: String, nonce: String?, fullName: String?
    ) async throws(PowderMeetError) {
        await signOutSettled()
        do {
            let session = try await deps.backend.signInWithApple(
                idToken: idToken, nonce: nonce, fullName: fullName
            )
            send(.signedIn(session))
        } catch {
            deps.log.error(.session, "sign in failed: \(error)")
            if case BackendError.signInFailed = error { throw .auth(.appleSignInFailed) }
            throw PowderMeetError(error)
        }
    }

    // MARK: Email accounts

    /// Email and password sign-in. An unconfirmed address throws
    /// `.auth(.emailNotConfirmed)`.
    public nonisolated func signIn(email: String, password: String) async throws(PowderMeetError) {
        await signOutSettled()
        do {
            send(.signedIn(try await deps.backend.signIn(email: Self.trimmed(email), password: password)))
        } catch {
            deps.log.error(.session, "email sign in failed: \(error)")
            throw PowderMeetError(error)
        }
    }

    /// Creates an email account. `.confirmationSent` until the address is
    /// confirmed; a server with confirmation off signs in at once.
    public nonisolated func signUp(email: String, password: String) async throws(PowderMeetError) -> SignUpOutcome {
        await signOutSettled()
        do {
            let outcome = try await deps.backend.signUp(email: Self.trimmed(email), password: password)
            if case .signedIn(let session) = outcome { send(.signedIn(session)) }
            return outcome
        } catch {
            deps.log.error(.session, "sign up failed: \(error)")
            throw Self.emailError(error)
        }
    }

    public nonisolated func resendConfirmation(email: String) async throws(PowderMeetError) {
        do {
            try await deps.backend.resendConfirmation(email: Self.trimmed(email))
        } catch {
            throw Self.emailError(error)
        }
    }

    public nonisolated func sendPasswordReset(email: String) async throws(PowderMeetError) {
        do {
            try await deps.backend.sendPasswordReset(email: Self.trimmed(email))
        } catch {
            throw Self.emailError(error)
        }
    }

    /// Signs in from a confirmation or reset link. Returns true for a reset
    /// link, after which the user must set a new password.
    public nonisolated func openAuthLink(_ url: URL) async throws(PowderMeetError) -> Bool {
        await signOutSettled()
        do {
            let link = try await deps.backend.openAuthLink(url)
            send(.linkOpened(link.session))
            return link.isPasswordRecovery
        } catch {
            deps.log.error(.session, "auth link not opened: \(error)")
            throw PowderMeetError(error)
        }
    }

    public nonisolated func updatePassword(_ password: String) async throws(PowderMeetError) {
        do {
            try await deps.backend.updatePassword(password)
        } catch {
            throw PowderMeetError(error)
        }
    }

    /// The live check behind the display-name field.
    public nonisolated func displayNameAvailable(_ name: String) async throws(PowderMeetError) -> DisplayNameAvailability {
        do {
            return try await deps.backend.displayNameAvailable(name)
        } catch {
            throw PowderMeetError(error)
        }
    }

    /// Saves the onboarding answers and reports a refusal to the caller, so
    /// onboarding can return to the step at fault (a taken name, say).
    public func completeOnboarding(_ patch: ProfilePatch) async throws(PowderMeetError) {
        guard let user = auth?.userID, profile != nil else { return }
        let saved: Profile
        do {
            saved = try await deps.backend.profileUpdate(patch)
        } catch {
            throw PowderMeetError(error)
        }
        try stillSignedIn(as: user)
        applySaved(saved)
    }

    /// These intents run beside the run loop, so a sign-out can land during
    /// their await; what they bring back then belongs to nobody on this phone.
    private func stillSignedIn(as user: UUID) throws(PowderMeetError) {
        guard auth?.userID == user, profile != nil else { throw .auth(.signedOut) }
    }

    private nonisolated static func trimmed(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The email-sending calls answer a rate limit with "too many emails".
    private nonisolated static func emailError(_ error: any Error) -> PowderMeetError {
        if case BackendError.rateLimited = error { return .auth(.tooManyEmails) }
        return PowderMeetError(error)
    }

    /// Contact discovery. Hashes are computed on the phone; a rate limit is
    /// `.social(.tooManyTries)`.
    public nonisolated func findUsers(
        emailHashes: [String], phoneHashes: [String]
    ) async throws(PowderMeetError) -> [UserMatch] {
        do {
            return try await deps.backend.findUsers(emailHashes: emailHashes, phoneHashes: phoneHashes)
        } catch {
            throw Self.socialError(error)
        }
    }

    /// Finding people by name. A query too short to match anyone answers
    /// empty without a call; a rate limit is `.social(.tooManyTries)`.
    public nonisolated func searchUsers(_ query: String) async throws(PowderMeetError) -> [UserSearchResult] {
        guard UserSearch.query(query) != nil else { return [] }
        do {
            return try await deps.backend.searchUsers(query: query)
        } catch {
            throw Self.socialError(error)
        }
    }

    // MARK: Profile photo and reports

    /// Makes a prepared JPEG (square, 512 px, no metadata) the profile photo:
    /// uploads it under a new path, saves the path, then removes the old
    /// photo. An upload whose save fails is removed again, so no orphan stays.
    /// Returns the new path.
    @discardableResult
    public func setAvatar(jpeg: Data) async throws(PowderMeetError) -> String {
        guard let user = auth?.userID, profile != nil else { throw .auth(.signedOut) }
        let backend = deps.backend
        let path: String
        do {
            path = try await backend.avatarUpload(jpeg: jpeg)
        } catch {
            throw Self.photoError(error)
        }
        try stillSignedIn(as: user)
        await deps.avatars.keep(jpeg, for: path)
        let saved: Profile
        do {
            saved = try await backend.profileUpdate(ProfilePatch().avatarURL(path))
        } catch {
            guard let landed = await profileIfSaved(path, user: user) else { throw PowderMeetError(error) }
            saved = landed
        }
        try stillSignedIn(as: user)
        let replaced = profile?.avatarURL
        applySaved(saved)
        // A replaced photo leaves nothing behind, on the phone either.
        if let replaced, replaced != path { await deps.avatars.remove(path: replaced) }
        await removeAvatarObjects(keeping: path)
        return path
    }

    /// After a failed save of `path`, the server's own row: the save may have
    /// landed with only its answer lost. Returns the row when it names `path`;
    /// when it does not, the upload goes and the photo the row names stays.
    private func profileIfSaved(_ path: String, user: UUID) async -> Profile? {
        let row: Profile?
        do {
            row = try await deps.backend.profile(id: user)
        } catch {
            // Nothing is removed on a guess: the server's sweep takes
            // whichever file ends up unused.
            deps.log.notice(.session, "photo save not confirmed: \(error)")
            return nil
        }
        if let row, row.avatarURL == path { return row }
        await deps.avatars.remove(path: path)
        await removeAvatarObjects(keeping: row?.avatarURL)
        return nil
    }

    /// Clears the profile photo and removes its file.
    public func removeAvatar() async throws(PowderMeetError) {
        guard let user = auth?.userID, profile != nil else { throw .auth(.signedOut) }
        let saved: Profile
        do {
            saved = try await deps.backend.profileUpdate(ProfilePatch().avatarURL(nil))
        } catch {
            throw PowderMeetError(error)
        }
        try stillSignedIn(as: user)
        let removed = profile?.avatarURL
        applySaved(saved)
        if let removed { await deps.avatars.remove(path: removed) }
        await removeAvatarObjects(keeping: nil)
    }

    /// Storage removal is housekeeping: a failure leaves a file nobody links
    /// to, and is not the user's to fix.
    private func removeAvatarObjects(keeping: String?) async {
        do {
            try await deps.backend.avatarRemove(keeping: keeping)
        } catch {
            deps.log.notice(.session, "old avatar files not removed: \(error)")
        }
    }

    /// The bucket refuses a file over 2 MB or of another type as `invalid`.
    private nonisolated static func photoError(_ error: any Error) -> PowderMeetError {
        if case BackendError.invalid = error { return .social(.photoUnreadable) }
        return PowderMeetError(error)
    }

    /// Files a report (App Store guideline 1.2). Blocking is a separate choice.
    public nonisolated func reportUser(
        _ user: UUID, reason: ReportReason, note: String?, context: ReportContext
    ) async throws(PowderMeetError) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            try await deps.backend.reportUser(
                user, reason: reason, note: trimmed.isEmpty ? nil : String(trimmed.prefix(reportNoteLimit)),
                context: context
            )
        } catch {
            throw Self.socialError(error)
        }
    }

    private nonisolated static func socialError(_ error: any Error) -> PowderMeetError {
        if case BackendError.rateLimited = error { return .social(.tooManyTries) }
        return PowderMeetError(error)
    }

    // MARK: Run loop

    /// Restores a stored session if there is one, then handles events until the
    /// task is cancelled.
    public func run() async {
        if let session = await deps.backend.currentSession() {
            await handle(.signedIn(session))
        } else {
            set(.signedOut(.noSession))
        }
        for await event in mailbox {
            await handle(event)
            if Task.isCancelled { break }
        }
        await stopEffects()
    }

    private func handle(_ event: Event) async {
        switch event {
        case .signedIn(let session):
            guard auth == nil else { return }
            auth = session
            // A returning user goes straight in on the profile saved last time;
            // the load below replaces it, or ends the session if the server no
            // longer accepts this user (`specs/07-CLIENT.md` section 4).
            if let cached = deps.launch.snapshot(for: session.userID)?.profile,
               !cached.baselineSpeeds.isEmpty {
                profile = cached
                awaitingStartup = true
                set(.ready(cached))
                deps.log.info(.session, "launched from the cached profile")
            } else {
                set(.starting)
            }
            startSessionEffects(session)

        case .linkOpened(let session):
            if let current = auth, current.userID == session.userID {
                auth = session
                return
            }
            // Another account's link: the SDK already holds its tokens, so the
            // old session ends here without a server sign-out, which would
            // end the new one.
            if auth != nil { await endSession(.userRequested, signOutOnServer: false) }
            await handle(.signedIn(session))

        case .profileLoaded(let startup):
            // Another account's link can follow a load that was already queued
            // for the account it replaced.
            guard let me = auth?.userID, startup.profile.id == me else { return }
            // A resort opened on the cached profile routes on the server's from now on.
            if let cached = profile, cached != startup.profile {
                resortSession?.send(.profileChanged(startup.profile))
            }
            profile = startup.profile
            awaitingStartup = false
            if isOnline { setLink(.online) }
            saveLaunchSnapshot()
            // A token that arrived from APNs while the load ran is already registered.
            registeredToken = startup.registeredToken ?? registeredToken
            setSocial(startup.social)
            // A new account has no speeds until onboarding saves them.
            set(startup.profile.baselineSpeeds.isEmpty ? .needsOnboarding : .ready(startup.profile))
            if let meet = startup.meet { await openResort(meet.resortID, pending: meet) }

        case .startupFailed(let error):
            guard auth != nil else { return }
            deps.log.error(.session, "startup failed: \(error)")
            if case .auth = error {
                await endSession(.sessionExpired)
            } else if awaitingStartup {
                // Running on the cached profile without a network: stay usable
                // and load again when the connection or the app comes back.
                bag.cancel("realtime")
                // The attempt is over; a notice that never ends helps nobody.
                if link == .reconnecting { setLink(.unconfirmed) }
            } else {
                // Keep the credentials; `retry` starts again.
                await stopEffects()
                set(.failed(error))
            }

        case .retry:
            guard case .failed = state, let auth else { return }
            set(.starting)
            startSessionEffects(auth)

        case .onboardingDone(let patch), .profileEdited(let patch):
            guard auth != nil, profile != nil else { return }
            do {
                applySaved(try await deps.backend.profileUpdate(patch))
            } catch {
                if !Task.isCancelled { await deps.toasts.post(PowderMeetError(error)) }
            }

        case .resortSelected(let resortID):
            guard case .ready = state else { return }
            await openResort(resortID, pending: nil)

        case .resortCleared:
            guard auth != nil, resortSession != nil else { return }
            await closeResort()
            noteCurrentResort(nil)
            saveLaunchSnapshot()
            // Off the mountain on screen: friends stop seeing this phone now,
            // not when the 15 minute TTL runs out. Started only once the
            // resort's tasks have ended, so no update in flight re-creates the row.
            let backend = deps.backend, log = deps.log
            bag.start("presence-clear") {
                do {
                    try await backend.presenceClear()
                } catch {
                    if !Task.isCancelled { log.notice(.session, "presence not cleared: \(error)") }
                }
            }

        case .serverEvent(let event):
            await route(event)

        case .reachability(let online):
            let cameBack = online && !isOnline
            isOnline = online
            if !online {
                // Nothing can answer now; the next attempt starts when the network returns.
                bag.cancel("recover")
                setLink(.offline)
            } else if cameBack, let auth, profile != nil {
                setLink(.reconnecting)
                await deps.outbox.wake()
                if awaitingStartup { await restartStartup(auth) } else { recover() }
            } else if cameBack {
                setLink(.online)
            }

        case .backgrounded:
            appActive = false
            resortSession?.send(.appActive(false))

        case .foregrounded:
            appActive = true
            resortSession?.send(.appActive(true))
            guard let auth, profile != nil else { return }
            if awaitingStartup {
                // The launch's own first foreground arrives while its startup
                // load is still running; only a failed load starts again.
                if !bag.has("realtime") { await restartStartup(auth) }
            } else {
                recover()
            }

        case .friend(let intent):
            guard auth != nil else { return }
            do {
                let backend = deps.backend
                switch intent {
                case .request(let user): _ = try await backend.friendRequest(user: user)
                case .respond(let id, let accept):
                    _ = try await backend.friendRespond(friendshipID: id, accept: accept)
                case .remove(let user):
                    try await backend.friendRemove(user: user)
                    resortSession?.send(.personRemoved(user))
                case .block(let user):
                    try await backend.blockUser(user)
                    resortSession?.send(.personRemoved(user))
                case .unblock(let user): try await backend.unblockUser(user)
                }
                refreshSocial()
            } catch {
                if !Task.isCancelled { await deps.toasts.post(PowderMeetError(error)) }
            }

        case .socialLoaded(let snapshot, let user):
            guard auth?.userID == user else { return }
            setSocial(snapshot)

        case .socialRefreshRequested:
            guard auth != nil, profile != nil else { return }
            refreshSocial()

        case .recovered(let meet):
            guard let me = auth?.userID, profile != nil else { return }
            if let meet, !meet.involves(me) { return }
            if isOnline { setLink(.online) }
            if let meet {
                await openResort(meet.resortID, pending: meet)
            } else {
                resortSession?.send(.noCurrentMeet)
            }

        case .recoverGaveUp:
            if link == .reconnecting { setLink(.unconfirmed) }

        case .signOutRequested:
            guard auth != nil else { return }
            await endSession(.userRequested)

        case .deleteAccountRequested:
            guard auth != nil else { return }
            do {
                // `account_delete` unlinks the photo; the file itself is the
                // client's to remove while it still owns the folder.
                await removeAvatarObjects(keeping: nil)
                try await deps.backend.accountDelete()
                await endSession(.accountDeleted)
            } catch {
                guard !Task.isCancelled else { return }
                await deps.toasts.post(PowderMeetError(error))
                // The account stays, and its photo file has gone: the profile
                // must not name it, or friends see a broken photo.
                if profile?.avatarURL != nil {
                    do {
                        applySaved(try await deps.backend.profileUpdate(ProfilePatch().avatarURL(nil)))
                    } catch {
                        deps.log.notice(.session, "photo not unlinked after a failed delete: \(error)")
                    }
                }
            }

        case .tokenExpired:
            guard auth != nil else { return }
            await endSession(.sessionExpired)

        case .deviceTokenChanged(let device):
            guard auth != nil, device.token != registeredToken else { return }
            registerDeviceToken(device)

        case .deviceTokenRegistered(let token):
            guard auth != nil else { return }
            // Sign-out unregisters the token pushes now go to.
            registeredToken = token
        }
    }

    private func applySaved(_ updated: Profile) {
        profile = updated
        resortSession?.send(.profileChanged(updated))
        saveLaunchSnapshot()
        set(updated.baselineSpeeds.isEmpty ? .needsOnboarding : .ready(updated))
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        changes.send(new)
    }

    private func setLink(_ new: Link) {
        guard new != link else { return }
        link = new
        linkChanges.send(new)
    }

    private func setSocial(_ snapshot: SocialSnapshot) {
        guard snapshot != social else { return }
        social = snapshot
        socialChanges.send(snapshot)
        guard auth != nil else { return }
        let people = snapshot.friends + snapshot.pendingIn + snapshot.pendingOut + snapshot.blocks
        var paths = Set(people.compactMap(\.avatarURL))
        if let own = profile?.avatarURL { paths.insert(own) }
        let avatars = deps.avatars, kept = paths
        bag.start("avatar-retain") { await avatars.retain(paths: kept) }
    }

    /// Events are hints: meets go to the resort that owns them, friend events
    /// trigger a re-read of the snapshot.
    private func route(_ event: ServerEvent) async {
        guard let me = auth?.userID, profile != nil else { return }
        switch event {
        case .meetProposed(let meet), .meetUpdated(let meet):
            guard meet.involves(me) else { return }
            if !meet.status.isTerminal, resortSession?.resortID != meet.resortID {
                // The meet's resort becomes the selected one: the invitee needs
                // its bundle to route (protocol section 4, "Respond").
                await openResort(meet.resortID, pending: meet)
            } else {
                resortSession?.send(.serverEvent(event))
            }
        case .meetProgress, .presence, .resortStatus:
            resortSession?.send(.serverEvent(event))
        case .friendRemoved(let friend):
            // The server tells only the other side, so `.friend(.remove/.block)`
            // sends the same for the user's own action.
            resortSession?.send(.personRemoved(friend.userID))
            refreshSocial()
        case .friendRequested, .friendAccepted:
            refreshSocial()
        case .reconnected:
            recover()
        case .unknown(let type):
            deps.log.info(.realtime, "ignored event \(type)")
        }
    }

    // MARK: Resort

    private func openResort(_ resortID: String, pending: Meet?) async {
        guard let profile else { return }
        if let current = resortSession, current.resortID == resortID {
            if let pending { current.send(.incomingMeet(pending)) }
            return
        }
        await closeResort()
        // A clear still on its way must not land after the new resort's first
        // update. Cancelled rather than awaited, so opening never waits on the
        // network; if the server ran it anyway, the next publish restores the row.
        if let clearing = bag.cancel("presence-clear") { await clearing.value }
        let session = ResortSession(
            resortID: resortID, profile: profile, pendingMeet: pending, dependencies: deps
        )
        resortSession = session
        resortChanges.send(session)
        if !appActive { session.send(.appActive(false)) }
        bag.start("resort") { await session.run() }
        noteCurrentResort(resortID)
        saveLaunchSnapshot()
    }

    /// Writes what the next launch starts from: this user's profile and the
    /// resort on screen. Only a complete profile is worth starting from.
    private func saveLaunchSnapshot() {
        guard var profile, !profile.baselineSpeeds.isEmpty else { return }
        profile.currentResortID = resortSession?.resortID
        deps.launch.save(LaunchSnapshot(profile: profile, savedAt: deps.clock.now))
    }

    /// Cancels the resort's task tree and waits until it has ended. A meet
    /// under way there is ended too, so the partner is not left waiting; that
    /// call is not awaited, so opening another resort never waits on the network.
    private func closeResort() async {
        guard let closing = resortSession else { return }
        let meet = await closing.meetSession
        if let task = bag.cancel("resort") { await task.value }
        resortSession = nil
        resortChanges.send(nil)
        if let meet { bag.start("meet-leave") { await meet.leave() } }
    }

    /// `profiles.current_resort_id` decides who receives this user's friends'
    /// positions (DECISION 7), so the server is told which resort is on screen.
    /// Without it the map shows no friends, so a failure that may pass is tried
    /// again until it goes through or another resort replaces this one.
    private func noteCurrentResort(_ resortID: String?) {
        let backend = deps.backend, log = deps.log, clock = deps.clock
        bag.start("current-resort") {
            var waitS = Self.recoverRetryS
            while true {
                do {
                    _ = try await backend.profileUpdate(ProfilePatch().currentResortID(resortID))
                    return
                } catch {
                    if Task.isCancelled { return }
                    log.notice(.session, "current resort not saved: \(error)")
                    guard (error as? BackendError)?.isTransient == true else { return }
                }
                do {
                    try await clock.sleep(for: waitS)
                } catch {
                    return
                }
                waitS = min(waitS * 2, Self.recoverRetryMaxS)
            }
        }
    }

    // MARK: Session effects

    private func startSessionEffects(_ session: AuthSession) {
        startStartup(session)
        let deps = deps, inbox = inbox
        bag.start("reachability") {
            for await online in deps.reachability.changes() {
                inbox.yield(.reachability(online))
            }
        }
        bag.start("auth") {
            for await event in deps.backend.authEvents() {
                if case .sessionExpired = event { inbox.yield(.tokenExpired) }
            }
        }
        bag.start("outbox") {
            await deps.outbox.run(backend: deps.backend, user: session.userID)
        }
        bag.start("push") {
            for await device in deps.push.tokenChanges() {
                inbox.yield(.deviceTokenChanged(device))
            }
        }
    }

    private func registerDeviceToken(_ device: DeviceToken) {
        let deps = deps, inbox = inbox
        bag.start("push-register") {
            do {
                try await deps.backend.deviceTokenRegister(
                    token: device.token, environment: device.environment, appBuild: deps.appBuild
                )
                inbox.yield(.deviceTokenRegistered(device.token))
            } catch {
                if !Task.isCancelled { deps.log.error(.session, "device token not registered: \(error)") }
            }
        }
    }

    /// The realtime subscription and the startup load, as one effect.
    private func startStartup(_ session: AuthSession) {
        let deps = deps, inbox = inbox
        // Subscribe first, so nothing the load below reads can change unseen, and
        // the socket is joined before the first presence_update.
        bag.start("realtime") {
            do {
                let events = try await deps.backend.events()
                let startup = try await Self.loadStartup(session, deps: deps)
                inbox.yield(.profileLoaded(startup))
                for await event in events {
                    inbox.yield(.serverEvent(event))
                }
            } catch {
                if !Task.isCancelled { inbox.yield(.startupFailed(PowderMeetError(error))) }
            }
        }
    }

    /// Tries the startup load again after it failed under a cached profile.
    /// The attempt still running, if any, ends first: its realtime channel has
    /// to leave before the new attempt joins the same topic.
    private func restartStartup(_ session: AuthSession) async {
        resortSession?.send(.reconnected)
        if let previous = bag.cancel("realtime") { await previous.value }
        startStartup(session)
    }

    private static func loadStartup(_ session: AuthSession, deps: Dependencies) async throws -> Startup {
        guard let profile = try await deps.backend.profile(id: session.userID) else {
            throw PowderMeetError.auth(.sessionExpired)
        }
        let social = try await deps.backend.socialSnapshot()
        var registered: String?
        if let device = await deps.push.deviceToken() {
            do {
                try await deps.backend.deviceTokenRegister(
                    token: device.token, environment: device.environment, appBuild: deps.appBuild
                )
                registered = device.token
            } catch {
                try Task.checkCancellation()
                deps.log.error(.session, "device token not registered: \(error)")
            }
        }
        let meet = try await deps.backend.meetCurrent()
        return Startup(profile: profile, social: social, registeredToken: registered, meet: meet)
    }

    private func refreshSocial() {
        guard let user = auth?.userID else { return }
        let backend = deps.backend, log = deps.log, inbox = inbox
        bag.start("social") {
            do {
                inbox.yield(.socialLoaded(try await backend.socialSnapshot(), for: user))
            } catch {
                if !Task.isCancelled { log.notice(.session, "social snapshot not refreshed: \(error)") }
            }
        }
    }

    /// "Recover" in the protocol: ask the server what meet this user is in.
    /// After the network has come back the question is asked until it is
    /// answered (the path can be up before the server is reachable), so the
    /// "reconnecting" notice always ends; otherwise it is asked once.
    private func recover() {
        let backend = deps.backend, log = deps.log, inbox = inbox, clock = deps.clock
        let untilAnswered = link == .reconnecting
        resortSession?.send(.reconnected)
        refreshSocial()
        bag.start("recover") {
            var waitS = Self.recoverRetryS
            while true {
                do {
                    inbox.yield(.recovered(try await backend.meetCurrent()))
                    return
                } catch {
                    if Task.isCancelled { return }
                    log.notice(.session, "meet_current failed: \(error)")
                    // A rejected session is the auth stream's to report, not a reason to retry.
                    guard untilAnswered, (error as? BackendError)?.isTransient == true else {
                        inbox.yield(.recoverGaveUp)
                        return
                    }
                }
                do {
                    try await clock.sleep(for: waitS)
                } catch {
                    return
                }
                waitS = min(waitS * 2, Self.recoverRetryMaxS)
            }
        }
    }

    static let recoverRetryS: TimeInterval = 3
    static let recoverRetryMaxS: TimeInterval = 30

    /// Cancels every effect, including the resort and its meet, and waits for
    /// them. The realtime subscription ends with its consumer task.
    private func stopEffects() async {
        resortSession = nil
        resortChanges.send(nil)
        for task in bag.cancelAll() { await task.value }
    }

    private func endSession(_ reason: SignOutReason, signOutOnServer: Bool = true) async {
        let meet = await resortSession?.meetSession
        await stopEffects()
        // After the drain loop has stopped. A sign-out keeps the queue, whose
        // runs go up when this account signs back in; a deleted account's never can.
        if reason == .accountDeleted, let user = auth?.userID {
            await deps.outbox.discard(user: user)
        }
        let callsServer = reason != .sessionExpired && signOutOnServer
        // `account_delete` already removed the rows and ended any meet.
        if callsServer, reason == .accountDeleted { await Self.signOutOnServer(deps) }
        let leaving = registeredToken
        auth = nil
        profile = nil
        awaitingStartup = false
        registeredToken = nil
        setLink(isOnline ? .online : .offline)
        deps.launch.clear()
        await deps.avatars.clear()
        setSocial(SocialSnapshot())
        set(.signedOut(reason))
        deps.log.info(.session, "signed out: \(reason)")
        guard callsServer, reason == .userRequested else { return }
        // The sign-in screen is already up; the server is told after, with the
        // tokens the backend still holds. Nothing here can fail the sign-out.
        // Still inside this event, so the next one waits, and a sign-in tapped
        // meanwhile waits in `signOutSettled` so this sign-out cannot end it.
        let deps = deps
        let teardown = Task {
            await Self.unregisterDevice(leaving, deps)
            await meet?.leave()
            // Friends see them leave now (`presence_clear` also clears the
            // friend-readable `current_resort_id`).
            await Self.clearPresence(deps)
            await Self.signOutOnServer(deps)
        }
        signingOut = teardown
        await teardown.value
        signingOut = nil
    }

    /// Returns once a user-requested sign-out has finished with the server.
    private func signOutSettled() async {
        await signingOut?.value
    }

    /// Stops pushes to this phone. A session that never finished loading has
    /// registered nothing this time, but an earlier one may have: the phone's
    /// own token is sent.
    private static func unregisterDevice(_ registered: String?, _ deps: Dependencies) async {
        var token = registered
        if token == nil { token = await deps.push.deviceToken()?.token }
        guard let token else { return }
        do {
            try await deps.backend.deviceTokenUnregister(token: token)
        } catch {
            deps.log.error(.session, "device token not unregistered: \(error)")
        }
    }

    private static func signOutOnServer(_ deps: Dependencies) async {
        do {
            try await deps.backend.signOut()
        } catch {
            // The local session is gone either way; the server token expires.
            deps.log.error(.session, "sign out call failed: \(error)")
        }
    }

    // MARK: Presence

    /// Deletes this user's presence row (`presence_clear`). A failure is only
    /// logged: the row still expires after 15 minutes on the server.
    private static func clearPresence(_ deps: Dependencies) async {
        do {
            try await deps.backend.presenceClear()
        } catch {
            deps.log.notice(.session, "presence not cleared: \(error)")
        }
    }

    /// The app is being terminated: a best-effort clear so friends do not see
    /// a phone that is gone for the next quarter of an hour. Called directly by
    /// the app (not through the mailbox, which may be busy), which gives it a
    /// moment of background time.
    public func prepareForTermination() async {
        guard auth != nil, resortSession != nil else { return }
        await Self.clearPresence(deps)
    }
}
