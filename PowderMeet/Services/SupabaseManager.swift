//
//  SupabaseManager.swift
//  PowderMeet
//
//  Central Supabase client — auth, profile CRUD, session management.
//

import Foundation
import Observation
import Supabase
import AuthenticationServices

@MainActor @Observable
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    // MARK: - Auth State

    var currentSession: Session?
    var currentUserProfile: UserProfile?
    var currentUserStats: ProfileStats?
    /// Per-edge skill memory: outer key `edge_id`, inner key the stable
    /// dataset/equipment/conditions compound key.
    /// Loaded after profile load + after any import that mutates
    /// `imported_runs`. Solver call sites pass this dict through
    /// `TraversalContext.edgeSpeedHistory` so `traverseTime` can
    /// pick the bucket matching live conditions and short-circuit
    /// the bucketed-difficulty fallback when a confident observation
    /// exists.
    var currentEdgeSpeeds: [String: [String: PerEdgeSpeed]] = [:]

    /// Per-friend edge-speed cache, loaded lazily when MeetView solves
    /// against a specific friend. Same shape as `currentEdgeSpeeds`
    /// (outer key edge_id → inner compound cohort key), one outer dict
    /// per friend uuid. Empty until `loadFriendEdgeSpeeds(for:)` runs;
    /// a friend with no calibration history (or a fetch failure) caches
    /// an empty inner dict so we don't re-hit the network on every solve.
    /// RLS on `profile_edge_speeds` (`profile_edge_speeds_friend_read`)
    /// enforces friends-only access — an unconfirmed pair returns zero
    /// rows by policy, not an error.
    var friendEdgeSpeeds: [UUID: [String: [String: PerEdgeSpeed]]] = [:]

    /// Server-canonical pinned snapshot date per resort id. Loaded
    /// once at cold launch from `resort_snapshot_pins` (public read,
    /// RLS allows anon). Two reserved keys: `"__catalog__"` for the
    /// catalog-wide default override, and any specific `resort_id`
    /// for a per-resort override. See
    /// `resolvedPinnedSnapshotDate(for:)` for resolution order.
    ///
    /// Hydrated from UserDefaults at init so the very-first call after
    /// cold launch returns the last-known server pins; refreshed in
    /// the background by `loadResortSnapshotPins()`. Without server
    /// pins, two app builds with different baked defaults (the IPA
    /// constant in `ResortEntry.defaultPinnedSnapshotDate`) load
    /// different snapshots and diverge from the start.
    var resortSnapshotPins: [String: String] = [:]
    static let resortSnapshotPinsCacheKey = "resort_snapshot_pins_cache_v1"

    /// Single-string fingerprint that changes whenever any solver
    /// input owned by this manager changes — skill level, the speed-
    /// per-difficulty bucket fields, condition-tolerance fields, and
    /// the per-edge rolling-speed cache (own + each friend's). Wire
    /// this into a SwiftUI `.onChange` to retrigger `solveMeeting`
    /// when the user changes their skill slider or imports new
    /// activity data; the static `MeetingPointSolver.solutionCache`
    /// already invalidates on the same axes (its key includes
    /// `profileFingerprint` and `edgeSpeedHistoryFingerprint`), so
    /// the resulting solve is fresh, not a cache hit on stale data.
    var solverInputsKey: String {
        let p = currentUserProfile
        let speedFields: [Double] = [
            p?.speedGreen ?? -1,
            p?.speedBlue ?? -1,
            p?.speedBlack ?? -1,
            p?.speedDoubleBlack ?? -1,
            p?.speedTerrainPark ?? -1
        ]
        let conditionFields: [Double] = [
            p?.conditionMoguls ?? -1,
            p?.conditionUngroomed ?? -1,
            p?.conditionIcy ?? -1,
            p?.conditionGladed ?? -1
        ]
        let speeds = speedFields.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let conds = conditionFields.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let myHistory = PerEdgeSpeed.historyFingerprint(currentEdgeSpeeds)
        let friendHistory = friendEdgeSpeeds.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { id in
                "\(id.uuidString.lowercased())="
                    + PerEdgeSpeed.historyFingerprint(friendEdgeSpeeds[id] ?? [:])
            }
            .joined(separator: ";")
        return "\(p?.skillLevel ?? "-")|ski=\(p?.preferredSkiId?.uuidString ?? "-")|\(speeds)|\(conds)|mine=\(myHistory)|friends=\(friendHistory)"
    }

    var isAuthenticated: Bool { currentSession != nil }
    var isLoading = true
    var authError: String?

    /// Set true when the user arrives via a `powdermeet://reset`
    /// deep link (tapping the email link from `resetPasswordForEmail`).
    /// `RootView` watches this and presents the new-password sheet
    /// over whatever surface is currently on screen. Cleared by the
    /// sheet itself once a new password is saved or the user cancels.
    var pendingPasswordRecovery = false

    /// Monotonically increasing counter bumped on each sign-in / sign-out /
    /// delete. Detached teardown tasks capture the generation at their start
    /// and early-out if it has advanced — prevents two overlapping lifecycles
    /// from stepping on each other's `ChannelRegistry` state when a user
    /// signs out and back in before the prior teardown completes.
    var sessionGeneration: Int = 0

    // MARK: - Init

    /// Supabase URL and anon key from Info.plist, populated via Secrets.xcconfig at build time.
    nonisolated static let projectURL: String = SupabaseManager.readRequiredKey("SupabaseURL")
    nonisolated static let anonKey: String = SupabaseManager.readRequiredKey("SupabaseAnonKey")

    nonisolated private static func readRequiredKey(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else {
            fatalError("\(key) missing from Info.plist. Populate Secrets.xcconfig and clean build.")
        }
        return value
    }

    private init() {
        guard let url = URL(string: Self.projectURL) else {
            // `projectURL` is read at build time from Secrets.xcconfig via
            // `readRequiredKey`, which already fails the build if missing.
            // Reaching this branch means the value is present but not a
            // valid URL string — that's a Secrets.xcconfig typo and there's
            // no recovery path; the SDK can't be constructed without it.
            fatalError("SupabaseURL is not a valid URL: \(Self.projectURL). Check Secrets.xcconfig.")
        }
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: Self.anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    autoRefreshToken: true,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
        // Hydrate resort snapshot pins from disk so the very first
        // resort load after cold launch sees server-canonical pins —
        // not the IPA-baked default that may already be stale relative
        // to other devices. Background refresh in `initialize()`
        // brings them up to date.
        if let data = UserDefaults.standard.data(forKey: Self.resortSnapshotPinsCacheKey),
           let cached = try? JSONDecoder().decode([String: String].self, from: data) {
            resortSnapshotPins = cached
        }
        // Ski physics must remain available when a skier launches into weak or
        // absent mountain connectivity. This is last-known-good public catalog
        // metadata only; it contains no account or activity data. A background
        // authenticated fetch still refreshes it once per app session.
        if let cached = Self.validatedSkiCatalogCache(
            UserDefaults.standard.data(forKey: Self.skisCatalogCacheKey)
        ) {
            skisCatalogCache = cached
            skisCatalogVersion = 1
        }
    }

    // MARK: - Lifecycle

    /// Call once at app launch to restore any persisted session.
    func initialize() async {
        // Refresh server-canonical resort snapshot pins and discover which
        // resorts have an applied canonical manifest. BOTH are consumed only
        // at resort-load time, which happens well after first frame:
        //  - pins already hydrated from UserDefaults in init(), so any
        //    in-flight resort load uses the last-known server pin meanwhile;
        //  - canonical discovery only picks which pipeline a *later* resort
        //    load uses (legacy serves every resort if it errors).
        // Each is a network GET with a 10s timeout, so awaiting them before
        // `isLoading = false` could dominate the splash gate on slow Wi-Fi.
        // Fire-and-forget as unstructured Tasks (they must survive past
        // initialize() returning — an `async let` would be cancelled at
        // scope exit), so the gate opens on the profile fetch alone.
        Task { await loadResortSnapshotPins() }
        Task { await CanonicalGraphFetcher.shared.discoverEnabledResorts() }

        do {
            let session = try await client.auth.session
            if session.isExpired {
                do {
                    let refreshed = try await client.auth.refreshSession()
                    currentSession = refreshed
                } catch {
                    try? await client.auth.signOut()
                    currentSession = nil
                    currentUserProfile = nil
                    currentUserStats = nil
                }
            } else {
                currentSession = session
            }
            if currentSession != nil {
                await loadProfile()
            }
        } catch {
            currentSession = nil
            currentUserStats = nil
        }
        // Open the gate the moment session restore + the single profile
        // fetch are in. Pins + canonical discovery (fired above) continue
        // independently and land before any resort load needs them.
        isLoading = false
    }

    /// Last time `verifySessionStillValid()` actually hit the server.
    /// Foreground events fire often — we coalesce so we don't hammer
    /// `/auth/refresh` every time the user wakes the app.
    @ObservationIgnored private var lastSessionVerifyAt: Date = .distantPast
    private static let sessionVerifyMinInterval: TimeInterval = 30

    /// Force-check that the current session still belongs to a real
    /// user. Called on app foreground so an account deleted via the
    /// Supabase dashboard boots the device immediately instead of
    /// waiting up to 1 hour for the next JWT refresh.
    ///
    /// We attempt a refresh; if Supabase returns one of the
    /// "you don't exist anymore" error messages (refresh-token gone,
    /// sub-claim mismatch, user-not-found), we sign out locally so
    /// the existing `observeAuthChanges` flow swaps the UI back to
    /// the Auth screen. Other errors (network, transient) leave
    /// the session alone — better to keep the user signed in and
    /// retry later than boot them on a flaky cellular connection.
    func verifySessionStillValid(force: Bool = false) async {
        guard currentSession != nil else { return }
        if !force, Date.now.timeIntervalSince(lastSessionVerifyAt) < Self.sessionVerifyMinInterval {
            return
        }
        lastSessionVerifyAt = .now
        // Foreground is also our cue to refresh server-canonical resort
        // snapshot pins — a snapshot bump shouldn't require a full app
        // restart to propagate. Same coalescing window as the session
        // verify (30s) since they fire on the same event.
        Task { await self.loadResortSnapshotPins() }
        do {
            let refreshed = try await client.auth.refreshSession()
            currentSession = refreshed
        } catch {
            if isAuthFailure(error) {
                AppLog.supabase.error("Account deleted server-side — booting locally: \(error.localizedDescription)")
                try? await client.auth.signOut()
                currentSession = nil
                currentUserProfile = nil
                currentUserStats = nil
                sessionGeneration &+= 1
            } else {
                AppLog.supabase.error("verifySessionStillValid transient error: \(error.localizedDescription)")
            }
        }
    }

    /// Long-running listener for auth state changes (sign-in, sign-out, token refresh).
    func observeAuthChanges() async {
        for await (event, session) in client.auth.authStateChanges {
            if event == .signedOut {
                sessionGeneration &+= 1
                self.currentSession = nil
                self.currentUserProfile = nil
                self.currentUserStats = nil
            } else if let session {
                // Only take a non-nil session update. A nil session arriving
                // with an event other than `.signedOut` (rare — usually a
                // token-refresh race) must NOT clobber `currentSession` back
                // to nil while leaving `currentUserProfile` populated —
                // that combination yields a view where `isAuthenticated`
                // disagrees with the populated profile.
                if currentSession?.user.id != session.user.id {
                    sessionGeneration &+= 1
                    currentUserProfile = nil
                    currentUserStats = nil
                }
                self.currentSession = session
                if currentUserProfile == nil {
                    await loadProfile()
                }
            }
            // event != .signedOut && session == nil: ignore (transient).
        }
    }

    // MARK: - Auth Methods

    /// Email + password sign-up. Display name is collected on the form
    /// (mirroring the Apple Sign-In path, which receives the name from
    /// the credential) so the trigger-created profile row lands with
    /// `display_name` already populated and onboarding doesn't need to
    /// re-ask the user something Apple just provided.
    func signUp(email: String, password: String, displayName: String) async throws {
        authError = nil
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            data: ["display_name": .string(trimmedName)]
        )
        currentSession = response.session
        sessionGeneration &+= 1
        await ensureProfileExists()
    }

    func signIn(email: String, password: String) async throws {
        authError = nil
        let session = try await client.auth.signIn(
            email: email,
            password: password
        )
        currentSession = session
        sessionGeneration &+= 1
        await loadProfile()
    }

    func signOut() async throws {
        // Tear down ALL realtime channels before signing out — prevents stale
        // subscriptions from lingering when the user creates a new account.
        await client.realtimeV2.removeAllChannels()
        try await client.auth.signOut()
        currentSession = nil
        currentUserProfile = nil
        currentUserStats = nil
        currentEdgeSpeeds = [:]
        friendEdgeSpeeds = [:]
        // Clear the on-disk friend-location cache. Without this the
        // SwiftData store survives sign-out, so a sign-up into a fresh
        // account would briefly render the previous user's friend dots
        // / friend chips / cached presence rows on cold launch — read
        // as a "ghost friend request" before the new account's social
        // snapshot replaces the in-memory state.
        // Instantiate a fresh FriendLocationStore and call clear() —
        // SwiftData's underlying container is shared on-disk, so a new
        // instance can wipe the same rows the live one was reading.
        // The live store (owned by ContentCoordinator) gets torn down
        // separately via teardown() on view disappear.
        if let store = try? FriendLocationStore() {
            store.clear()
        }
        // Drop the solver's static LRU. Without this, signing back in
        // with a different account on the same device can serve a cached
        // MeetingResult from the previous user (cache key includes the
        // graph fingerprint + profile UUIDs, but the static survives the
        // process — sign-in→sign-in cycles re-use the same cache instance).
        MeetingPointSolver.solutionCache.clear()
        sessionGeneration &+= 1
    }

    /// Custom URL scheme registered in Info.plist (`CFBundleURLSchemes`)
    /// that the password-reset email link routes back to. The path
    /// (`/reset`) is informational — the iOS app accepts any path under
    /// this scheme — but matching what Supabase Auth's "Redirect URLs"
    /// allowlist expects keeps the dashboard config explicit.
    static let passwordRecoveryDeepLink = "powdermeet://reset"

    /// Send a password reset email. `redirectTo` is the deep link the
    /// email's "Reset password" button opens — must also be allowlisted
    /// under Supabase Auth → URL Configuration → Redirect URLs in the
    /// dashboard, otherwise Supabase falls back to its default Site URL
    /// and the email link won't return to the app.
    func resetPassword(email: String) async throws {
        try await client.auth.resetPasswordForEmail(
            email,
            redirectTo: URL(string: Self.passwordRecoveryDeepLink)
        )
    }

    /// Called from `PowderMeetApp.onOpenURL` when the OS hands us a
    /// `powdermeet://…` URL. Supabase encodes the recovery tokens as
    /// URL fragments (`#access_token=…&refresh_token=…&type=recovery`);
    /// `auth.session(from:)` parses them, establishes a transient
    /// authenticated session, and the SDK's `authStateChanges` stream
    /// emits `.passwordRecovery` — but we set our own flag so the UI
    /// doesn't depend on event timing. The user can now call
    /// `updatePassword(_:)` from the new-password sheet to commit.
    func handleDeepLink(_ url: URL) async {
        do {
            try await client.auth.session(from: url)
            pendingPasswordRecovery = true
        } catch {
            AppLog.supabase.error("Deep link session parse failed: \(error.localizedDescription)")
        }
    }

    /// Commit a new password using the transient recovery session set
    /// up by `handleDeepLink`. Calls Supabase's user-update endpoint;
    /// the server validates the recovery token and writes the new
    /// password. On success the recovery flag clears and the user is
    /// now signed in with full session privileges.
    func updatePassword(_ newPassword: String) async throws {
        _ = try await client.auth.update(user: UserAttributes(password: newPassword))
        pendingPasswordRecovery = false
    }

    /// Signs in (or creates an account) using an Apple ID credential.
    /// - Parameters:
    ///   - idToken: The raw JWT identity token from `ASAuthorizationAppleIDCredential.identityToken`.
    ///   - nonce: The plain-text nonce used when making the Apple request (the SHA-256 hash was
    ///            sent to Apple; the raw value is verified by Supabase).
    ///   - fullName: Apple only provides the user's name on the very first sign-in. Store it in
    ///               auth metadata immediately so `ensureProfileExists` can pick it up.
    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws {
        authError = nil
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
        currentSession = session
        sessionGeneration &+= 1

        // Apple only returns the full name on the very first sign-in.
        // Resolve the display name once so we can route it into BOTH the
        // auth user-metadata (for future sign-ins where Apple sends nothing)
        // AND the profiles row (which the handle_new_user trigger created
        // with display_name='' a few ms ago, since Apple's ID token doesn't
        // carry name claims — Supabase's raw_user_meta_data was empty when
        // the trigger fired).
        let resolvedDisplayName: String? = {
            guard let name = fullName else { return nil }
            let parts = [name.givenName, name.familyName].compactMap { $0 }
            let joined = parts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }()

        if let displayName = resolvedDisplayName {
            _ = try? await client.auth.update(
                user: UserAttributes(data: ["display_name": AnyJSON.string(displayName)])
            )
            // Pick up the new metadata locally so OnboardingView's
            // seedDisplayNameIfNeeded() can read it from currentSession.
            if let refreshed = try? await client.auth.session {
                currentSession = refreshed
            }
        }

        await ensureProfileExists()

        // Trigger fired with empty metadata → profiles.display_name is "".
        // If we have a name now, push it to the row directly so the rest
        // of the app (and the user's onboarding seed) sees the real name
        // instead of an empty placeholder.
        if let displayName = resolvedDisplayName,
           let current = currentUserProfile,
           current.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await updateProfile(["display_name": AnyJSON.string(displayName)])
        }
    }

    // MARK: - Profile CRUD

    /// Last non-auth error encountered while loading the profile. Exposed so
    /// `SplashView` / `RootView` can surface a retry affordance instead of
    /// trapping the user on an endless spinner when the profile fetch is
    /// failing for a transient reason (offline, 5xx, RLS hiccup).
    var profileLoadError: String?

    /// Single classifier for "this error means the session/credentials are
    /// bad — sign out" vs a transient network / 5xx blip (keep the session and
    /// let the user retry). Previously two divergent inline lists
    /// (`verifySessionStillValid` and `loadProfile`) tested DIFFERENT
    /// substrings for the same question, drifting against Supabase SDK message
    /// changes. Every substring here is a strong auth-failure signal; none
    /// match generic connectivity errors (timeout / offline / connection lost
    /// / 5xx), so unifying does not increase the flaky-mountain-Wi-Fi
    /// sign-out risk this code deliberately guards against.
    private func isAuthFailure(_ error: Error) -> Bool {
        let m = error.localizedDescription.lowercased()
        return m.contains("401")
            || m.contains("unauthorized")
            || m.contains("invalid jwt")
            || m.contains("jwt expired")
            || m.contains("pgrst301")
            || m.contains("refresh token")
            || m.contains("invalid refresh token")
            || m.contains("user not found")
            || m.contains("user_not_found")
            || m.contains("user from sub claim")
    }

    func loadProfile() async {
        guard let userId = currentSession?.user.id else { return }
        let generation = sessionGeneration
        profileLoadError = nil
        do {
            let profiles: [UserProfile] = try await client.from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            guard currentSession?.user.id == userId,
                  sessionGeneration == generation else { return }
            if let profile = profiles.first {
                self.currentUserProfile = profile
                // Defer the two non-launch-critical fetches off the splash
                // gate: `profile_stats` feeds the Profile tab (tab 2, not the
                // default map tab) and edge-speed history feeds the solver
                // (opened later from MeetView) — neither is on the first
                // frame. Previously these ran serially here, stacking two
                // network round-trips on flaky mountain Wi-Fi before the app
                // could render. Fire-and-forget so the splash flips as soon
                // as the profile row is in; both degrade gracefully if slow.
                Task { await loadProfileStats() }
                Task { await loadEdgeSpeedHistory() }
                // Prefetch the ski catalog so friend rows + on-mountain
                // blob can resolve preferred_ski_id → BrandStyle
                // synchronously when they render.
                Task { try? await fetchSkisCatalog() }
                // First sign-in: prompt for push permission. Idempotent
                // — Notify caches `didRequestAuthorization` so subsequent
                // launches skip straight past. Required for the
                // notify_meet_request_insert → send-push pipeline to
                // actually deliver an APNs banner; without this prompt
                // we never get a device token, server triggers fire
                // but find no targets, no push goes out.
                Task { await Notify.shared.ensureAuthorized() }
            } else {
                // Zero rows: the auth.users row exists but no profile was
                // created. Treat as an orphaned session and sign out — the
                // DB trigger for profile creation failed or the row was
                // deleted out-of-band. This is NOT a transient error.
                AppLog.supabase.debug("loadProfile: no profile row for \(userId) — signing out orphaned session")
                try? await client.auth.signOut()
                currentSession = nil
                currentUserProfile = nil
                currentUserStats = nil
            }
        } catch {
            guard currentSession?.user.id == userId,
                  sessionGeneration == generation else { return }
            // Previously this signed the user out on ANY error — including
            // transient network blips, 5xx responses, and token-refresh
            // races. That was how users got kicked back to the auth screen
            // during flaky mountain Wi-Fi. Now we only sign out for errors
            // that clearly mean the session is bad (401 / PGRST301 RLS
            // rejection / invalid JWT); everything else is reported via
            // `profileLoadError` so the UI can prompt a retry.
            let message = error.localizedDescription
            if isAuthFailure(error) {
                AppLog.supabase.error("loadProfile auth error: \(error) — clearing session")
                try? await client.auth.signOut()
                currentSession = nil
                currentUserProfile = nil
                currentUserStats = nil
            } else {
                AppLog.supabase.error("loadProfile transient error: \(error) — keeping session")
                profileLoadError = message
            }
        }
    }

    /// Ensures a profile row exists for the current user, creating one if the
    /// database trigger hasn't fired yet.
    @discardableResult
    func ensureProfileExists() async -> Bool {
        guard let userId = currentSession?.user.id else { return false }
        let generation = sessionGeneration
        let profiles: [UserProfile]? = try? await client.from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        guard currentSession?.user.id == userId,
              sessionGeneration == generation else { return false }
        if let existing = profiles?.first {
            self.currentUserProfile = existing
            return true
        }
        let displayName = currentSession?.user.userMetadata["display_name"]?.stringValue ?? ""
        let defaultProfile = UserProfile.defaultProfile(id: userId)
        do {
            try await client.from("profiles")
                .insert(UserProfile(
                    id: userId,
                    displayName: displayName.isEmpty ? "Skier" : displayName,
                    avatarUrl: nil,
                    skillLevel: defaultProfile.skillLevel,
                    speedGreen: defaultProfile.speedGreen,
                    speedBlue: defaultProfile.speedBlue,
                    speedBlack: defaultProfile.speedBlack,
                    speedDoubleBlack: defaultProfile.speedDoubleBlack,
                    speedTerrainPark: defaultProfile.speedTerrainPark,
                    conditionMoguls: defaultProfile.conditionMoguls,
                    conditionUngroomed: defaultProfile.conditionUngroomed,
                    conditionIcy: defaultProfile.conditionIcy,
                    conditionGladed: defaultProfile.conditionGladed,
                    // Default true on the schema; pass explicitly so
                    // the Codable encoder includes the column on the
                    // INSERT — without this, the row arrives with the
                    // field absent and Postgres applies the column
                    // default, but the round-trip decode (and any
                    // subsequent UPDATE) can land on inconsistent
                    // intermediate state. Belt-and-suspenders.
                    liveRecordingEnabled: true,
                    onboardingCompleted: false,
                    createdAt: nil,
                    updatedAt: nil
                ))
                .execute()
            guard currentSession?.user.id == userId,
                  sessionGeneration == generation else { return false }
            await loadProfile()
            return currentUserProfile?.id == userId
        } catch {
            AppLog.supabase.error("ensureProfileExists insert error: \(error)")
            return false
        }
    }

    /// Check if a display name is already taken by another user.
    /// Profile-edit flow uses this — excludes the caller's own row.
    func isDisplayNameTaken(_ name: String) async -> Bool {
        guard let userId = currentSession?.user.id else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let matches: [UserProfile] = try await client.from("profiles")
                .select("id")
                .ilike("display_name", pattern: trimmed)
                .neq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            return !matches.isEmpty
        } catch {
            AppLog.supabase.error("Display name check failed: \(error)")
            return false  // Allow on error — server constraint will catch duplicates
        }
    }

    /// Pre-signup display-name check. Calls the
    /// `is_display_name_taken` SECURITY DEFINER RPC so the SignUp
    /// form can warn the user before submitting (no session yet,
    /// so the regular `isDisplayNameTaken` query would no-op).
    /// Returns false on any error so the user isn't blocked by
    /// transient failures — the unique index catches duplicates
    /// at insert time as a backstop.
    func isDisplayNameTakenForSignup(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let taken: Bool = try await client
                .rpc("is_display_name_taken", params: ["p_name": AnyJSON.string(trimmed)])
                .execute()
                .value
            return taken
        } catch {
            AppLog.supabase.error("Pre-signup name check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Set the user's display name in BOTH the profiles row and the
    /// auth user-metadata so the Supabase Dashboard's "Display Name"
    /// column (which reads `raw_user_meta_data.display_name`) and the
    /// app's profile row stay in sync. Use this for every display-
    /// name change — `updateProfile` alone only writes profiles.
    ///
    /// Failure to write metadata is non-fatal — the app reads from
    /// `currentUserProfile`, so a successful profile UPDATE is what
    /// matters for the UI; the metadata sync is for dashboard /
    /// observability surfaces.
    func setDisplayName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let ownerID = currentSession?.user.id else {
            throw ProfileSaveError.signInRequired
        }
        try await updateProfile(["display_name": .string(trimmed)])
        guard currentSession?.user.id == ownerID else {
            throw ProfileSaveError.signInRequired
        }
        // The profile row is authoritative for the app. Mirror metadata in
        // the background so the name editor can close after one network
        // round-trip instead of waiting for the Auth service as well.
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self,
                  self.currentSession?.user.id == ownerID,
                  self.sessionGeneration == generation else { return }
            do {
                _ = try await self.client.auth.update(
                    user: UserAttributes(data: ["display_name": AnyJSON.string(trimmed)])
                )
                guard self.currentSession?.user.id == ownerID,
                      self.sessionGeneration == generation else { return }
                if let refreshed = try? await self.client.auth.session {
                    self.currentSession = refreshed
                }
            } catch {
                AppLog.supabase.error("auth user-metadata display_name sync failed: \(error.localizedDescription)")
            }
        }
    }

    func updateProfile(_ updates: [String: AnyJSON]) async throws {
        guard let userId = currentSession?.user.id else {
            throw ProfileSaveError.signInRequired
        }
        let generation = sessionGeneration
        // Use .select() to get the updated row back in one round-trip
        let response: [UserProfile] = try await client.from("profiles")
            .update(updates)
            .eq("id", value: userId.uuidString)
            .select()
            .execute()
            .value
        guard let updated = response.first else { throw ProfileSaveError.noProfileReturned }
        guard currentSession?.user.id == userId,
              sessionGeneration == generation else { throw ProfileSaveError.signInRequired }
        self.currentUserProfile = updated
    }

    enum ProfileSaveError: LocalizedError {
        case signInRequired
        case noProfileReturned

        var errorDescription: String? {
            switch self {
            case .signInRequired: return "Please sign in again to save your settings."
            case .noProfileReturned: return "Your profile wasn't saved. Please try again."
            }
        }
    }

    /// Convenience wrapper so callers (e.g. `ContentCoordinator`) don't have
    /// to import Supabase just to construct an `AnyJSON.string` / `AnyJSON.null`
    /// for one column. Pass `nil` to clear the current resort.
    func setCurrentResortId(_ id: String?) async throws {
        try await updateProfile([
            "current_resort_id": id.map(AnyJSON.string) ?? .null,
        ])
    }

    /// Persist the user's preferred ski. Pass `nil` to revert to the
    /// PowderMeet house default (NULL `preferred_ski_id`).
    func setPreferredSkiId(_ id: UUID?) async throws {
        try await updateProfile([
            "preferred_ski_id": id.map { AnyJSON.string($0.uuidString) } ?? .null,
        ])
    }

    /// Persist body metrics. Either side can be cleared independently by
    /// passing `nil`. Used by the BODY TYPE sheet — HealthKit-prefilled
    /// values are user-editable before save.
    func setBodyMetrics(heightCm: Double?, weightKg: Double?) async throws {
        try await updateProfile([
            "height_cm": heightCm.map(AnyJSON.double) ?? .null,
            "weight_kg": weightKg.map(AnyJSON.double) ?? .null,
        ])
    }

    // MARK: - Profile Stats

    /// Loads the current user's aggregated stats row (recomputed server-side
    /// after each activity import). Missing row → publishes `.empty(for:)` so
    /// the profile UI can render zeros instead of a spinner.
    func loadProfileStats() async {
        guard let userId = currentSession?.user.id else { return }
        let generation = sessionGeneration
        let stats = await fetchProfileStats(for: userId) ?? .empty(for: userId)
        guard currentSession?.user.id == userId,
              sessionGeneration == generation else { return }
        currentUserStats = stats
    }

    // MARK: - Skis Catalog

    /// Cached ski-catalog rows. Hydrated from the last-known-good disk
    /// snapshot, refreshed from the server once per session, then reused.
    /// The catalog is curated and contains no user data.
    private var skisCatalogCache: [SkiCatalogEntry]?
    private var didRefreshSkisCatalogThisSession = false
    static let skisCatalogCacheKey = "skis_catalog_cache_v1"
    /// Bumps every time the catalog cache populates or invalidates.
    /// Reading this in a view body ahead of `skiCatalogEntry(forSkiId:)`
    /// guarantees the view re-renders when the cache lands, even if
    /// the @Observable framework's tracking through the method call
    /// chain misses the read. Cheap belt-and-suspenders.
    private(set) var skisCatalogVersion: Int = 0

    /// Synchronous BrandStyle lookup against the in-memory catalog.
    /// Falls through to `BrandStyle.powderMeet` when:
    ///   • the catalog hasn\'t loaded yet (cold call before
    ///     `fetchSkisCatalog()` resolves)
    ///   • `skiId` is nil (user picked the house default)
    ///   • the id doesn\'t match a known catalog row
    /// Production-cheap: O(n) over ~70 entries, called once per row
    /// render. No network round-trip.
    func brandStyle(forSkiId skiId: UUID?) -> BrandStyle {
        guard let entry = skiCatalogEntry(forSkiId: skiId) else {
            return .powderMeet
        }
        return BrandStyle.resolve(brand: entry.brand)
    }

    /// Synchronous catalog row lookup. Same caching/fallback semantics as
    /// `brandStyle(forSkiId:)`. Returns the full `SkiCatalogEntry` so
    /// callers can use `category` + `waistWidthMm` for silhouette
    /// proportions in addition to the brand string.
    func skiCatalogEntry(forSkiId skiId: UUID?) -> SkiCatalogEntry? {
        // Touch the version counter so the calling view body
        // registers a dep on it. When `fetchSkisCatalog()` lands and
        // bumps the version, every view that previously called this
        // method re-renders — friend rows that resolved to nil on
        // cold launch get their ski once the catalog hydrates.
        _ = skisCatalogVersion
        guard let skiId else { return nil }
        return skisCatalogCache?.first(where: { $0.id == skiId })
    }

    /// Returns the full ski catalog. First call attempts a server refresh;
    /// later calls return memory. When offline, the last-known-good disk
    /// snapshot keeps routing physics and the picker usable. An error reaches
    /// the caller only when no valid snapshot has ever been saved.
    func fetchSkisCatalog() async throws -> [SkiCatalogEntry] {
        if didRefreshSkisCatalogThisSession, let cached = skisCatalogCache {
            return cached
        }

        let rows: [SkiCatalogEntry]
        do {
            rows = try await client.from("skis_catalog")
                .select()
                .order("brand", ascending: true)
                .order("model", ascending: true)
                .execute()
                .value
        } catch {
            // An offline skier should retain selected-ski ETA behavior and a
            // usable picker from the last successful catalog snapshot.
            if let cached = skisCatalogCache, !cached.isEmpty {
                return cached
            }
            throw error
        }

        // A seeded production catalog should never be empty. Preserve the
        // last-known-good snapshot across a transient rollout/RLS mistake.
        if rows.isEmpty, let cached = skisCatalogCache, !cached.isEmpty {
            return cached
        }
        didRefreshSkisCatalogThisSession = true
        if rows != skisCatalogCache {
            skisCatalogCache = rows
            skisCatalogVersion &+= 1
        }
        if let encoded = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(encoded, forKey: Self.skisCatalogCacheKey)
        }

        // Background-prewarm the topsheet alpha-bbox cache for
        // every catalog row that has bundled artwork. Without this,
        // the first render of a never-seen friend's ski (e.g. on
        // accept-friend-request) blocks the main thread for the
        // alpha scan; with it, every load(_:) call after this Task
        // completes hits a cached UIImage instantly. Detached so it
        // doesn't delay this RPC's caller.
        let assetKeys = rows.compactMap(\.topsheetAssetKey)
        Task.detached(priority: .utility) {
            await TopsheetCache.prewarm(keys: assetKeys)
        }

        return rows
    }

    nonisolated static func validatedSkiCatalogCache(_ data: Data?) -> [SkiCatalogEntry]? {
        guard let data,
              let rows = try? JSONDecoder().decode([SkiCatalogEntry].self, from: data),
              !rows.isEmpty,
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ entry in
                  !entry.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !entry.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && entry.waistWidthMm.map { (50...160).contains($0) } != false
              }) else {
            return nil
        }
        return rows
    }
}

// MARK: - Supabase ISO8601 Decoder

extension JSONDecoder {
    /// Shared decoder for Supabase realtime payloads.
    /// Supabase sends timestamps with fractional seconds (e.g. "2026-03-12T12:30:00.123456+00:00")
    /// which Foundation's built-in .iso8601 does NOT support — use a custom formatter.
    static let supabaseDecoder: JSONDecoder = {
        let d = JSONDecoder()
        // Same dual-format (with / without fractional seconds) dance as the
        // activity-file parsers — route through the shared `ISO8601Parser`
        // rather than re-creating the formatter pair here.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = ISO8601Parser.parse(str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(str)"
            )
        }
        return d
    }()
}
