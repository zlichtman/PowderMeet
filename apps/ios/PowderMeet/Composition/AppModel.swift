import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

// The `@Observable` projections of the session actors (`specs/07-CLIENT.md`
// section 2). Views read these and call their intent methods; nothing here is a
// view, and no view talks to a session or a service directly.

/// The one connection notice on screen, if any. `backOnline` shows briefly
/// after either of the others and then clears itself.
nonisolated enum ConnectionNotice: Sendable, Hashable {
    case offline, reconnecting, backOnline
}

/// Sign-in progress and its failure, shown inline on the auth screen.
nonisolated struct AuthProgress: Sendable, Hashable {
    var isSigningIn = false
    var failure: PowderMeetError?
}

// MARK: App

/// The signed-in user's state and every app-level intent.
@Observable
final class AppModel {
    private(set) var state: AppSession.State = .starting
    var auth = AuthProgress()
    /// Email accounts, password reset and the display-name check (`AppModel+Account`).
    var account = AccountState()
    private(set) var social = SocialSnapshot()
    private(set) var isOnline = true
    private(set) var connectionNotice: ConnectionNotice?
    private(set) var toasts: [Toast] = []
    private(set) var banner: InAppBanner?
    private(set) var resort: ResortModel?
    var catalog = CatalogState()
    /// Friends from the address book's email addresses (`AppModel+Social`).
    var discovery = DiscoveryState()
    /// The profile photo being saved (`AppModel+Social`).
    var photo = PhotoState()
    /// Friends → search by name (`AppModel+Social`).
    var peopleSearch = PeopleSearchState()
    /// The report sheet's progress.
    var report = ReportState()
    /// Profile photos, decoded, over the disk store in `Dependencies`.
    let avatarImages: AvatarImages
    /// Resort ids, most recently opened first, on this phone.
    var recentResorts: [String] = []
    /// The pick-one list floating over the map, if any (`Navigation.swift`).
    /// Opened from a panel page, the panel waits under it and shows again
    /// when it closes.
    var floatingPicker: MapSheet?
    /// The floating panel over the bottom of the map: the profile panel (the
    /// profile card and the four section tiles), and the pages pushed on it.
    /// Nothing on the map moves at rest, so opening it asks nothing of the map.
    var isProfilePanelOpen = DebugLaunch.profilePanel || DebugLaunch.panelPath != nil {
        didSet { if !isProfilePanelOpen { panelPath = [] } }
    }
    /// The pages pushed over the profile panel; empty shows the panel itself.
    var panelPath: [PanelRoute] = DebugLaunch.panelPath ?? []
    /// "+ Add friend": Friends opens with its search field taking the keyboard.
    var focusesPeopleSearch = false
    /// Settings → Maps (`AppModel+Maps`).
    var maps = MapsSummary()
    /// Settings → Maps → Fly in: a newly opened mountain is reached by a slow
    /// descending orbit (3.6 s) instead of the short turn (0.8 s). The one
    /// cinematic extra: it moves the map only while it
    /// flies, never at rest. Off by default; a choice for this phone.
    var mapFlyIn = UserDefaults.standard.bool(forKey: AppModel.flyInKey) {
        didSet { UserDefaults.standard.set(mapFlyIn, forKey: AppModel.flyInKey) }
    }
    static let flyInKey = "powdermeet.map.flyIn"
    /// Settings → Notifications: the kinds this account has muted.
    var notificationPrefs = NotificationPrefsState()
    private(set) var locationPermission = LocationPermission.notDetermined
    /// The user allows "Always" (recording and meets with the phone locked).
    private(set) var locationAlways = false
    /// The mode last handed to the location driver (`AppModel+Location`).
    var appliedLocationMode: LocationMode?
    var notificationPermission = NotificationPermission.notDetermined
    /// This phone's last fix, for "nearest resort".
    private(set) var lastFix: Fix?
    /// Run history, lifetime totals and file import.
    let activity: ActivityModel
    /// The skier's meets as the server keeps them (`meet_history`), for the
    /// meet badges; nil until read for this account. Held in memory only:
    /// the server is the record, and a partner's deleted account takes its
    /// meets with it.
    var meetHistory: [Meet]?

    let appVersion: String
    let appBuild: String
    /// What people see: "3.0" for 3.0.0, the full version otherwise. The build
    /// number stays in bug reports, where it helps.
    var displayVersion: String {
        let parts = appVersion.split(separator: ".")
        return parts.count == 3 && parts[2] == "0" ? parts.prefix(2).joined(separator: ".") : appVersion
    }

    let session: AppSession
    let deps: Dependencies
    let locationAccess: LocationAccess
    let push: PushService?
    let offlineMaps: MapOfflineRegions?
    private var pumps: [Task<Void, Never>] = []
    var work: [String: Task<Void, Never>] = [:]
    /// The sign-in whose last resort has been reopened.
    private var restoredResortFor: UUID?
    /// When the process started, and whether this launch's timing line is written.
    private let launchedAt: Date
    private let connections: @Sendable () -> AsyncStream<Connection>
    /// What the map download policy reads: the network and the resort whose
    /// map has settled (`AppModel+Maps`).
    var connection = Connection.unmetered
    var settledResortID: String?
    /// Which maps stay on this phone, saved on it.
    var mapShelf = AppModel.loadMapShelf()
    /// Downloads the user started, by resort.
    var mapJobs: [String: Task<Void, Never>] = [:]
    /// The resort the background pass is working on.
    var mapSyncResortID: String?
    /// Resorts whose imagery was brought up to date since launch.
    var imageryChecked: Set<String> = []
    private var readyAfterMS: Int?
    private var loggedLaunch = false
    #if DEBUG
    private var importedDebugFiles = false
    #endif
    /// The app is not on screen (`LocationDemand.inBackground`).
    private(set) var isInBackground = false
    /// Opening the resort the phone is in (`ResortArrival`) waits for a fix:
    /// armed at launch and on each return to the foreground.
    var arrivalPending = true
    /// The user chose or closed a resort in this session; arrival never
    /// overrides that.
    var pickedResortThisSession = false
    /// The resorts whose boxes the phone is in, when there are several: the
    /// picker shows only these until it closes.
    var arrivalChoices: [String]?
    /// Developer testing that moves the phone (teleport, dev people) or a
    /// scripted Debug launch: arrival stays out of its way. Set by the
    /// composition root.
    var arrivalSuppressed: () -> Bool = { DebugLaunch.previewData }

    init(
        session: AppSession, dependencies: Dependencies, locationAccess: LocationAccess,
        push: PushService?, offlineMaps: MapOfflineRegions?, appVersion: String,
        launchedAt: Date, connections: @escaping @Sendable () -> AsyncStream<Connection>
    ) {
        self.launchedAt = launchedAt
        self.connections = connections
        self.session = session
        deps = dependencies
        self.locationAccess = locationAccess
        self.push = push
        self.offlineMaps = offlineMaps
        self.appVersion = appVersion
        appBuild = dependencies.appBuild
        activity = ActivityModel(dependencies: dependencies)
        avatarImages = AvatarImages(store: dependencies.avatars, backend: dependencies.backend)
    }

    // MARK: Derived

    var profile: Profile? {
        if case .ready(let profile) = state { return profile }
        #if DEBUG
        // `-previewData YES`: a made-up profile so the panel pages can be
        // screenshot signed out. Nothing is saved: every edit goes to a session
        // that is not signed in.
        if DebugLaunch.previewData { return DebugLaunch.previewProfile }
        #endif
        return nil
    }

    /// Friend requests waiting for an answer: the badge on the profile button
    /// and on the Friends tile (the requests head the Friends page). Meet
    /// requests take the context sheet instead.
    var friendRequestCount: Int { social.pendingIn.count }

    var recentResortsKey: String { "resorts.recent" }

    // MARK: Lifecycle

    /// Starts following the sessions. Called once by the composition root.
    func start() {
        guard pumps.isEmpty else { return }
        keepDownloadedMaps()
        let session = session, deps = deps
        pumps.append(Task { [weak self] in
            for await state in await session.states() {
                self?.apply(state)
            }
        })
        pumps.append(Task { [weak self] in
            for await social in await session.socialUpdates() {
                self?.social = social
                self?.shareNames()
            }
        })
        pumps.append(Task { [weak self] in
            for await resortSession in await session.resortSessions() {
                self?.follow(resortSession)
            }
        })
        pumps.append(Task { [weak self] in
            for await toasts in await deps.toasts.updates() {
                self?.toasts = toasts
            }
        })
        pumps.append(Task { [weak self] in
            for await online in deps.reachability.changes() {
                self?.isOnline = online
            }
        })
        pumps.append(Task { [weak self] in
            for await link in await session.links() {
                self?.apply(link)
            }
        })
        recentResorts = UserDefaults.standard.stringArray(forKey: recentResortsKey) ?? []
        pumps.append(Task { [weak self] in
            for await fix in deps.location.fixes() {
                self?.lastFix = fix
                self?.resort?.userFix = fix
                self?.considerArrival()
            }
        })
        let connections = connections
        pumps.append(Task { [weak self] in
            for await connection in connections() {
                self?.connection = connection
                self?.syncMaps()
            }
        })
        let permissions = locationAccess.permissions
        pumps.append(Task { [weak self] in
            for await permission in permissions() {
                self?.locationPermission = permission
            }
        })
        let always = locationAccess.alwaysAllowed
        pumps.append(Task { [weak self] in
            for await allowed in always() {
                self?.locationAlways = allowed
            }
        })
        if let push {
            pumps.append(Task { [weak self] in
                for await banner in push.banners() {
                    self?.banner = banner
                }
            })
            pumps.append(Task { [weak self] in
                for await kind in push.taps() {
                    self?.openedFromNotification(kind: kind)
                }
            })
        }
        refreshNotificationPermission()
        activity.onHistoryLoaded = { [weak self] history in
            self?.recalibrate(from: history)
            self?.announceNewBadges()
        }
        trackLocationDemand()
    }

    /// One notice for the connection, replaced in place: offline, then
    /// reconnecting, then a short "back online" that clears itself.
    private func apply(_ link: AppSession.Link) {
        work["connection-clear"]?.cancel()
        switch link {
        case .offline:
            connectionNotice = .offline
        case .reconnecting:
            connectionNotice = .reconnecting
        case .unconfirmed:
            connectionNotice = nil
        case .online:
            guard connectionNotice == .offline || connectionNotice == .reconnecting else {
                connectionNotice = nil
                return
            }
            connectionNotice = .backOnline
            // The catalog may have failed, or come from disk, with no
            // connection; it is cheap to ask again.
            if catalog.failure != nil || catalog.isSaved { loadCatalog() }
            if meetHistory == nil, profile != nil { loadMeetHistory() }
            run("connection-clear") { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2.5))
                } catch {
                    return
                }
                self?.connectionNotice = nil
            }
        }
    }

    private func apply(_ new: AppSession.State) {
        state = new
        switch new {
        case .ready(let profile):
            auth = AuthProgress()
            refreshAccountIdentity()
            restoreContactMatches(for: profile.id)
            activity.signedIn(profile.id)
            // A saved edit (Gear's hardest run, say) re-plans a solo route.
            resort?.profileChanged(SkierProfile(profile))
            #if DEBUG
            if !importedDebugFiles, !DebugLaunch.importPaths.isEmpty {
                importedDebugFiles = true
                let files = DebugLaunch.importPaths.map { URL(fileURLWithPath: $0) }
                let delay = DebugLaunch.importDelay
                // `-debugImportDelay N`: the empty Activity first, then the import.
                Task { [weak self] in
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                    self?.activity.enqueue(files)
                }
            }
            #endif
            if readyAfterMS == nil {
                readyAfterMS = msSinceLaunch
                openDebugSheet()
            }
            if catalog.resorts.isEmpty, !catalog.isLoading { loadCatalog() }
            // Once per account: `.ready` comes again with every saved profile
            // edit, and a meet ending reads them again on its own.
            if meetHistory == nil { loadMeetHistory() }
            armArrival()
            // The app opens straight to the map: reopen the resort that was on
            // screen last time. `AppSession` restores a resort only for a meet.
            if restoredResortFor != profile.id {
                restoredResortFor = profile.id
                if resort == nil, let last = profile.currentResortID {
                    session.send(.resortSelected(last))
                } else if resort == nil, !DebugLaunch.previewData {
                    // No mountain to come back to: the list opens by itself,
                    // as the screen behind it has nothing to press.
                    openFloating(.resortPicker)
                }
            }
        case .signedOut(let reason):
            // A sign-up waiting for its link stays on screen; the rest was
            // about the account that just left. A reset link for another
            // account ends this session on its way in, and still owes its
            // new password.
            let owesPassword = reason == .userRequested && account.needsNewPassword
            account = AccountState(
                awaitingConfirmation: account.awaitingConfirmation, unconfirmedEmail: account.unconfirmedEmail,
                needsNewPassword: owesPassword
            )
            restoredResortFor = nil
            pickedResortThisSession = false
            arrivalChoices = nil
            work["meet-history"]?.cancel()
            meetHistory = nil
            activity.signedOut(reason)
            if !DebugLaunch.previewData {
                floatingPicker = nil
                isProfilePanelOpen = false
            }
            notificationPrefs = NotificationPrefsState()
            photo = PhotoState()
            work["people-search"]?.cancel()
            peopleSearch = PeopleSearchState()
            forgetContactMatches()
            report = ReportState()
            avatarImages.clear()
            // The next account on this phone starts on Classic, the PowderMeet
            // icon and the device's units.
            if reason == .accountDeleted {
                ThemeManager.shared.resetToDefault()
                // Not part of the look reset: the deleted account's own ski colour.
                ThemeManager.shared.noteSkiAccent(nil)
                forgetMapsAndRecentResorts()
            }
        case .needsOnboarding:
            auth = AuthProgress()
            refreshAccountIdentity()
            refreshOnboardingProfile()
        case .starting, .failed:
            break
        }
    }

    private func follow(_ resortSession: ResortSession?) {
        resort?.stop()
        guard let resortSession else {
            resort = nil
            return
        }
        let model = ResortModel(session: resortSession, log: deps.log, solveClock: deps.solveClock)
        model.userFix = lastFix
        model.onMapFirstLoad = { [weak self, weak model] timing in
            guard let self, let model else { return }
            self.mapFinishedFirstLoad(timing, of: model)
        }
        // A meet request comes first: the profile panel folds away so the
        // context sheet shows it. A section page stays (it may hold a half-typed
        // report), with a banner over it that leads back here.
        model.onMeetIncoming = { [weak self] in
            guard let self else { return }
            if panelPath.isEmpty { isProfilePanelOpen = false }
        }
        // A friend tapped while another meet is under way: their card.
        model.onFriendCard = { [weak self] friend in self?.openPanel([.friendCard(friend)]) }
        // A meet reached may earn a meet badge.
        model.onMeetEnded = { [weak self] in self?.loadMeetHistory() }
        settledResortID = nil
        resort = model
        if ThemeManager.shared.runOverlay == .skied { syncSkiedRuns() }
        noteRecentResort(resortSession.resortID)
        shareNames()
        model.start()
    }

    private var msSinceLaunch: Int { Int(Date().timeIntervalSince(launchedAt) * 1_000) }

    /// A map has drawn its first view and come to rest: write the launch-speed
    /// regression line (once per process) and let the map downloads start.
    private func mapFinishedFirstLoad(_ timing: MapLoadTiming, of model: ResortModel) {
        if !loggedLaunch {
            loggedLaunch = true
            deps.log.info(.map, "launch to map: \(msSinceLaunch) ms from process start "
                + "(signed in at \(readyAfterMS ?? -1) ms; map: \(timing.summary))")
        }
        guard model === resort else { return }
        settledResortID = model.resortID
        syncMaps()
    }

    /// One named piece of work at a time; starting it again replaces the last.
    func run(_ name: String, _ operation: @escaping @MainActor () async -> Void) {
        work[name]?.cancel()
        work[name] = Task { await operation() }
    }

    // MARK: Auth intents

    /// Called with the credential Sign in with Apple returned.
    func signInWithApple(idToken: String, nonce: String?, fullName: String?) {
        guard !auth.isSigningIn else { return }
        auth = AuthProgress(isSigningIn: true)
        // Offered in onboarding's name step; never saved without the user.
        if let fullName { account.suggestedName = DisplayName.normalize(fullName) }
        run("sign-in") { [weak self, session] in
            do {
                try await session.signInWithApple(idToken: idToken, nonce: nonce, fullName: fullName)
                // `isSigningIn` clears when the session reaches `.ready`.
            } catch {
                self?.auth = AuthProgress(failure: PowderMeetError(error))
            }
        }
    }

    /// Sign in with Apple did not return a credential (not a cancellation).
    func appleSignInFailed() {
        auth = AuthProgress(failure: .auth(.appleSignInFailed))
    }

    func retryStartup() { session.send(.retry) }
    func signOut() { session.send(.signOutRequested) }
    func deleteAccount() { session.send(.deleteAccountRequested) }

    // MARK: Messages

    func dismissToast(_ id: UUID) {
        let toasts = deps.toasts
        Task { await toasts.dismiss(id) }
    }

    func dismissBanner() { banner = nil }

    /// Does what a toast's recovery offers. `openSettings` is the caller's: it
    /// needs `openURL` from the environment.
    func perform(_ recovery: Recovery) {
        switch recovery {
        case .retry:
            if case .failed = state { session.send(.retry) }
            resort?.retry()
            if catalog.failure != nil { loadCatalog() }
        case .pickResort:
            openFloating(.resortPicker)
        case .signIn, .openSettings, .none:
            break
        }
    }

    // MARK: Scene

    /// The app came to the foreground: the session re-reads what it may have
    /// missed, and the next fix may open the resort the phone is now in.
    func sceneBecameActive() {
        session.send(.foregrounded)
        refreshNotificationPermission()
        if isInBackground {
            isInBackground = false
            arrivalPending = true
            armArrival()
            syncMaps()
        }
    }

    /// The app left the screen: location loosens during a meet, the resort
    /// stops prefetching, and the maps on the phone use the background grace
    /// to come up to date.
    func sceneEnteredBackground() {
        isInBackground = true
        session.send(.backgrounded)
        syncMaps()
    }

    /// A notification was tapped. A meet push shows the map with the meet in
    /// the context sheet; a friend push opens Friends, the only place friend
    /// requests are shown; an activity notification (imported runs, the day's
    /// recording) opens Activity.
    private func openedFromNotification(kind: String?) {
        session.send(.foregrounded)
        if kind?.hasPrefix("activity.") == true {
            openProfilePage(.activity)
        } else if kind?.hasPrefix("friend.") == true {
            openProfilePage(.friends)
        } else {
            showMap()
        }
    }

    /// One of the profile panel's sections in the floating panel, from
    /// anywhere; `route` is pushed on it.
    func openProfilePage(_ page: ProfilePage, route: PanelRoute? = nil) {
        openPanel([.section(page)] + (route.map { [$0] } ?? []))
    }

    /// The floating panel at `path` (empty: the profile panel itself).
    func openPanel(_ path: [PanelRoute]) {
        floatingPicker = nil
        isProfilePanelOpen = true
        panelPath = path
    }

    /// "+ Add friend": Friends, searching.
    func openAddFriend() {
        focusesPeopleSearch = true
        openProfilePage(.friends)
    }

    /// One page deeper in the panel.
    func pushPanel(_ route: PanelRoute) {
        guard panelPath.last != route else { return }
        panelPath.append(route)
    }

    /// Back to the level above: the page under this one, or the profile panel.
    func panelBack() {
        guard !panelPath.isEmpty else { return closePanel() }
        panelPath.removeLast()
    }

    /// Back off a page if it is the one on top: a page closing itself after
    /// its work is done (a report sent, a friend removed).
    func leavePanelPage(_ route: PanelRoute) {
        if panelPath.last == route { panelBack() }
    }

    /// Folds the whole panel, whatever page it is on.
    func closePanel() {
        isProfilePanelOpen = false
    }

    /// The profile button: the panel opens at the profile panel, or folds.
    func toggleProfilePanel() {
        if isProfilePanelOpen {
            closePanel()
        } else {
            openPanel([])
        }
    }

    /// Debug launch arguments: the floating list to open, once the map is up.
    private func openDebugSheet() {
        guard let picker = DebugLaunch.picker else { return }
        run("debug-sheet") { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.openFloating(picker)
        }
    }

    /// A pick-one list over the map. Opened from the panel (theme, icon, the
    /// skis on the profile card or Gear), the panel waits under it and shows
    /// again, on the same page, when the list closes; the resort picker folds
    /// the panel.
    func openFloating(_ picker: MapSheet) {
        if picker == .resortPicker { isProfilePanelOpen = false }
        floatingPicker = picker
    }

    /// Closes a floating list, back to the panel page it was opened from, if any.
    func closeFloating() {
        // Closing the "You're at" list without a choice is an answer too: it
        // is not asked again this session.
        if arrivalChoices != nil { pickedResortThisSession = true }
        floatingPicker = nil
        arrivalChoices = nil
    }

    /// The map with nothing over it but the context sheet.
    func showMap() {
        isProfilePanelOpen = false
        floatingPicker = nil
        arrivalChoices = nil
    }
}
