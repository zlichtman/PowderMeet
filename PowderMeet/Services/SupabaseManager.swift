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
    /// Per-edge skill memory: outer key `edge_id`, inner key
    /// `conditions_fp` (Phase 2.1 — bucketed weather + surface).
    /// Loaded after profile load + after any import that mutates
    /// `imported_runs`. Solver call sites pass this dict through
    /// `TraversalContext.edgeSpeedHistory` so `traverseTime` can
    /// pick the bucket matching live conditions and short-circuit
    /// the bucketed-difficulty fallback when a confident observation
    /// exists.
    var currentEdgeSpeeds: [String: [String: PerEdgeSpeed]] = [:]

    /// Per-friend edge-speed cache, loaded lazily when MeetView solves
    /// against a specific friend. Same shape as `currentEdgeSpeeds`
    /// (outer key edge_id → inner key conditions_fp), one outer dict
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
    private static let resortSnapshotPinsCacheKey = "resort_snapshot_pins_cache_v1"

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
        // Sum observation counts across all (edge_id, conditions_fp)
        // entries — captures both "new edges added" and "more samples
        // on existing edges" without serialising the whole dict on
        // every render.
        let myObs = currentEdgeSpeeds.values
            .flatMap { $0.values }
            .reduce(0) { $0 + $1.observationCount }
        let friendObs = friendEdgeSpeeds.values
            .flatMap { $0.values.flatMap { $0.values } }
            .reduce(0) { $0 + $1.observationCount }
        return "\(p?.skillLevel ?? "-")|\(speeds)|\(conds)|\(currentEdgeSpeeds.count):\(myObs)|\(friendEdgeSpeeds.count):\(friendObs)"
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
    }

    // MARK: - Lifecycle

    /// Call once at app launch to restore any persisted session.
    func initialize() async {
        // Refresh server-canonical resort snapshot pins. Public read
        // RLS allows this to run even before auth, so we kick it off
        // in parallel with session restore. UserDefaults already
        // hydrated `resortSnapshotPins` in init() so any in-flight
        // resort load uses the last-known server pin until this
        // returns with a fresher set.
        async let pinRefresh: () = loadResortSnapshotPins()

        // Discover which resorts have an applied canonical manifest.
        // Populates `CanonicalGraphFetcher.shared.enabledResortIds`
        // from `current_resort_canonical_manifest` (anon read via RLS).
        // As you run `canonical_ingest apply` for new resorts, the
        // next app launch picks them up automatically — no client
        // code change. Failure is silent: legacy pipeline serves
        // every resort if the discovery call errors.
        async let canonicalDiscovery: () = CanonicalGraphFetcher.shared.discoverEnabledResorts()

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
        // Make sure the parallel tasks run to completion. The
        // async-lets above kick them off in parallel with session
        // restore; awaiting here guarantees we don't drop them when
        // `initialize()` returns.
        await pinRefresh
        await canonicalDiscovery
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
            let msg = error.localizedDescription.lowercased()
            let userGone = msg.contains("refresh token")
                || msg.contains("user from sub claim")
                || msg.contains("user not found")
                || msg.contains("invalid refresh token")
                || msg.contains("user_not_found")
            if userGone {
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

    func loadProfile() async {
        guard let userId = currentSession?.user.id else { return }
        profileLoadError = nil
        do {
            let profiles: [UserProfile] = try await client.from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            if let profile = profiles.first {
                self.currentUserProfile = profile
                await loadProfileStats()
                await loadEdgeSpeedHistory()
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
            // Previously this signed the user out on ANY error — including
            // transient network blips, 5xx responses, and token-refresh
            // races. That was how users got kicked back to the auth screen
            // during flaky mountain Wi-Fi. Now we only sign out for errors
            // that clearly mean the session is bad (401 / PGRST301 RLS
            // rejection / invalid JWT); everything else is reported via
            // `profileLoadError` so the UI can prompt a retry.
            let message = error.localizedDescription
            let lower = message.lowercased()
            let isAuthError = lower.contains("401")
                || lower.contains("unauthorized")
                || lower.contains("invalid jwt")
                || lower.contains("jwt expired")
                || lower.contains("pgrst301")
            if isAuthError {
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
        let profiles: [UserProfile]? = try? await client.from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
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
            await loadProfile()
            return true
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
        try await updateProfile(["display_name": .string(trimmed)])
        // Mirror to auth user-metadata. Best-effort.
        do {
            _ = try await client.auth.update(
                user: UserAttributes(data: ["display_name": AnyJSON.string(trimmed)])
            )
            // Pick up the fresh session so currentSession reflects
            // the new metadata immediately (any view that reads from
            // user_metadata.display_name — e.g., debug panels — sees
            // the change without waiting for the next refresh).
            if let refreshed = try? await client.auth.session {
                currentSession = refreshed
            }
        } catch {
            AppLog.supabase.error("auth user-metadata display_name sync failed: \(error.localizedDescription)")
        }
    }

    func updateProfile(_ updates: [String: AnyJSON]) async throws {
        guard let userId = currentSession?.user.id else { return }
        // Use .select() to get the updated row back in one round-trip
        let response: [UserProfile] = try await client.from("profiles")
            .update(updates)
            .eq("id", value: userId.uuidString)
            .select()
            .execute()
            .value
        if let updated = response.first {
            self.currentUserProfile = updated
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
        currentUserStats = await fetchProfileStats(for: userId) ?? .empty(for: userId)
    }

    // MARK: - Skis Catalog

    /// Cached ski-catalog rows. Populated lazily on first fetch and
    /// reused for the lifetime of the session — the catalog is a
    /// curated, slowly-growing list, not user-mutable, so a session-
    /// scoped cache is cheap and avoids re-hitting the network on every
    /// MY SKIS sheet open.
    private var skisCatalogCache: [SkiCatalogEntry]?
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

    /// Returns the full ski catalog. First call hits Supabase; later
    /// calls return the cached list. Errors surface to the caller —
    /// the picker can render an empty list + retry button when the
    /// network is unavailable.
    func fetchSkisCatalog() async throws -> [SkiCatalogEntry] {
        if let cached = skisCatalogCache { return cached }
        let rows: [SkiCatalogEntry] = try await client.from("skis_catalog")
            .select()
            .order("brand", ascending: true)
            .order("model", ascending: true)
            .execute()
            .value
        skisCatalogCache = rows
        skisCatalogVersion &+= 1

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

    // MARK: - Device Tokens (APNs)

    /// Upsert the iOS device token for the signed-in user. Called from
    /// `Notify.captureDeviceToken` once iOS hands us a token. Idempotent
    /// — the (profile_id, token) primary key absorbs repeats; only
    /// `updated_at` ticks. RLS enforces `auth.uid() = profile_id`.
    ///
    /// Stamps `environment` so the `send-push` edge function can pick
    /// the matching APNs auth key per recipient. Apple split modern
    /// APNs auth keys to be env-scoped (one key authenticates only to
    /// its environment's APNs server), and the same Supabase project
    /// serves both dev and TestFlight builds, so a per-token field is
    /// the only way to deliver to both populations from a single
    /// edge function.
    ///
    /// - DEBUG builds (Xcode → device, simulator iOS 16.4+) register
    ///   under `'sandbox'` and the edge function uses
    ///   `APNS_AUTH_KEY_SANDBOX` to deliver via
    ///   `api.sandbox.push.apple.com`.
    /// - Release builds (TestFlight + App Store) register under
    ///   `'production'` and the edge function uses
    ///   `APNS_AUTH_KEY_PRODUCTION` to deliver via
    ///   `api.push.apple.com`.
    func upsertDeviceToken(_ token: String, platform: String = "ios") async {
        guard let userId = currentSession?.user.id else { return }
        struct DeviceTokenRow: Encodable {
            let profile_id: String
            let token: String
            let platform: String
            let environment: String
            let updated_at: String
        }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let row = DeviceTokenRow(
            profile_id: userId.uuidString,
            token: token,
            platform: platform,
            environment: environment,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try await client.from("device_tokens")
                .upsert(row, onConflict: "profile_id,token")
                .execute()
        } catch {
            AppLog.supabase.error("device_tokens upsert failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Resort Snapshot Pins

    /// Decoder shape for `resort_snapshot_pins` rows.
    private struct ResortSnapshotPinRow: Decodable {
        let resortId: String
        let snapshotDate: String
        enum CodingKeys: String, CodingKey {
            case resortId = "resort_id"
            case snapshotDate = "snapshot_date"
        }
    }

    /// Refresh server-canonical pinned snapshot dates. Run at cold
    /// launch (from `initialize()`) and re-run on foreground via
    /// `verifySessionStillValid` so a snapshot bump propagates without
    /// requiring an app restart. Failures keep the previous in-memory
    /// dict — graceful degradation when offline (cache hydrated from
    /// UserDefaults still applies).
    func loadResortSnapshotPins() async {
        do {
            let rows: [ResortSnapshotPinRow] = try await client.from("resort_snapshot_pins")
                .select("resort_id,snapshot_date")
                .execute()
                .value
            var dict: [String: String] = [:]
            for row in rows {
                dict[row.resortId] = row.snapshotDate
            }
            resortSnapshotPins = dict
            // Persist to UserDefaults so the next cold launch already
            // has them before the network round-trip completes.
            if let encoded = try? JSONEncoder().encode(dict) {
                UserDefaults.standard.set(encoded, forKey: Self.resortSnapshotPinsCacheKey)
            }
        } catch {
            AppLog.supabase.error("loadResortSnapshotPins failed: \(error.localizedDescription)")
        }
    }

    /// Resolve the pinned snapshot date that should be used for a
    /// resort load. Order:
    ///   1. Per-resort server pin (`resortSnapshotPins[entry.id]`)
    ///   2. Catalog-wide server pin (`resortSnapshotPins["__catalog__"]`)
    ///   3. Per-resort baked override (`entry.pinnedSnapshotDate`)
    ///   4. Catalog-wide baked default (`ResortEntry.defaultPinnedSnapshotDate`)
    ///
    /// Always non-nil — the baked default is guaranteed.
    func resolvedPinnedSnapshotDate(for entry: ResortEntry) -> String {
        if let serverPin = resortSnapshotPins[entry.id] { return serverPin }
        if let catalogPin = resortSnapshotPins["__catalog__"] { return catalogPin }
        return entry.effectivePinnedSnapshotDate
    }

    // MARK: - Per-Edge Skill Memory

    /// Loads `profile_edge_speeds` for the current user into a dict
    /// keyed by `edge_id`. Called by `loadProfile`, after activity
    /// imports, and after backup restore. Failures are logged and the
    /// dict stays at its prior value — graceful degradation: solver
    /// falls back to bucketed difficulty when the dict is empty.
    func loadEdgeSpeedHistory() async {
        guard let userId = currentSession?.user.id else { return }
        do {
            let rows: [PerEdgeSpeed] = try await client.from("profile_edge_speeds")
                .select()
                .eq("profile_id", value: userId.uuidString)
                .execute()
                .value
            // Group by edge_id → conditions_fp. Multiple buckets per
            // edge are expected once `LiveRunRecorder` populates real
            // weather fingerprints; pre-Phase-2.1 rows all land in the
            // single 'default' bucket and `TraversalContext.observation(for:)`
            // selects it by fallback.
            var dict: [String: [String: PerEdgeSpeed]] = [:]
            for row in rows {
                dict[row.edgeId, default: [:]][row.conditionsFp] = row
            }
            currentEdgeSpeeds = dict
        } catch {
            AppLog.supabase.error("loadEdgeSpeedHistory failed: \(error.localizedDescription)")
        }
    }

    /// Loads a friend's `profile_edge_speeds` rows into the
    /// `friendEdgeSpeeds` cache so MeetSolver can give the friend
    /// per-edge calibration in the solve. Visibility is gated by the
    /// `profile_edge_speeds_friend_read` RLS policy (`status =
    /// 'accepted'` in `friendships`); a non-friend lookup returns zero
    /// rows by policy, not an error. Cached entry sticks for the
    /// session — refresh on demand by calling
    /// `clearFriendEdgeSpeeds(profileId:)` first when you know the
    /// friend just imported. Returns the loaded dict (or empty on
    /// miss / failure) so callers don't have to re-read the cache.
    @discardableResult
    func loadFriendEdgeSpeeds(for profileId: UUID) async -> [String: [String: PerEdgeSpeed]] {
        if let cached = friendEdgeSpeeds[profileId] { return cached }
        do {
            let rows: [PerEdgeSpeed] = try await client.from("profile_edge_speeds")
                .select()
                .eq("profile_id", value: profileId.uuidString)
                .execute()
                .value
            var dict: [String: [String: PerEdgeSpeed]] = [:]
            for row in rows {
                dict[row.edgeId, default: [:]][row.conditionsFp] = row
            }
            friendEdgeSpeeds[profileId] = dict
            return dict
        } catch {
            AppLog.supabase.error("loadFriendEdgeSpeeds(\(profileId)) failed: \(error.localizedDescription)")
            // Cache empty on failure so a flaky network doesn't hammer
            // the API on every solve. The solver degrades to bucket
            // physics for this friend until the cache is cleared.
            friendEdgeSpeeds[profileId] = [:]
            return [:]
        }
    }

    /// Drop a single friend's cached edge-speed dict (e.g. when the
    /// caller knows the friend just imported / cleared their data and
    /// wants a fresh fetch on the next solve). With no argument,
    /// drops the whole cache — used on session teardown.
    func clearFriendEdgeSpeeds(profileId: UUID? = nil) {
        if let id = profileId {
            friendEdgeSpeeds.removeValue(forKey: id)
        } else {
            friendEdgeSpeeds = [:]
        }
    }

    /// Fires the server-side aggregator that rebuilds
    /// `profile_edge_speeds` from current `imported_runs`. Idempotent —
    /// safe to call after every import, every delete, every restore.
    /// Reloads `currentEdgeSpeeds` on success.
    ///
    /// Returns `true` on success, `false` on RPC failure or missing
    /// session — callers in the import path (`ActivityImporter`,
    /// `LiveRunRecorder`) use the return value to surface a banner
    /// tail to the user instead of failing silently. The solver's
    /// per-edge memory is what actually consumes this output, so a
    /// silent failure was previously invisible to the user even
    /// though their freshly-imported run was being ignored.
    @discardableResult
    func recomputeProfileEdgeSpeeds() async -> Bool {
        guard let userId = currentSession?.user.id else { return false }
        do {
            try await client
                .rpc("recompute_profile_edge_speeds", params: ["uid": AnyJSON.string(userId.uuidString)])
                .execute()
            await loadEdgeSpeedHistory()
            return true
        } catch {
            AppLog.supabase.error("recompute_profile_edge_speeds failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetches stats for any profile (used by friend cards). Returns nil only
    /// on transport failure — a missing row is reported as `.empty(for:)`.
    func fetchProfileStats(for profileId: UUID) async -> ProfileStats? {
        do {
            let rows: [ProfileStats] = try await client.from("profile_stats")
                .select()
                .eq("profile_id", value: profileId.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first ?? .empty(for: profileId)
        } catch {
            AppLog.supabase.error("fetchProfileStats(\(profileId)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sends profile update to Supabase and returns the updated profile.
    /// Does NOT update local state — the caller is responsible for that.
    func sendFullProfileUpdate(_ profile: UserProfile) async throws -> UserProfile {
        let response: [UserProfile] = try await client.from("profiles")
            .update(profile.updatePayload)
            .eq("id", value: profile.id.uuidString)
            .select()
            .execute()
            .value
        return response.first ?? profile
    }

    // MARK: - Imported Runs Management

    /// Deletes every `imported_runs` row for the current user, then
    /// recomputes `profile_stats` so the lifetime totals reflect the
    /// wipe. RLS limits the DELETE to the caller's own rows, so even
    /// if a future bug calls this with a wrong user id, the server
    /// rejects writes outside the caller's scope.
    ///
    /// Used by the Profile → RESET STATS flow so "reset" actually
    /// resets — previously it only reset the `profiles` row's preset
    /// fields and left `imported_runs` (and therefore the
    /// `profile_stats` aggregate) unchanged. Users saw the days /
    /// vertical / top-speed card stay populated after a "reset",
    /// which read as a bug.
    func clearImportedRuns() async throws {
        guard let userId = currentSession?.user.id else { return }
        try await client.from("imported_runs")
            .delete()
            .eq("profile_id", value: userId.uuidString)
            .execute()
        // Post-DELETE sanity check — RLS or a transient auth blip can
        // make the DELETE return success with zero rows touched, leaving
        // ghost runs visible in LOGS after PURGE. Surface the residue
        // through AppLog so the regression isn't silent. (Cheap — single
        // id query limited to 1; only fires on the reset path.)
        struct IdRow: Decodable { let id: String }
        do {
            let residue: [IdRow] = try await client
                .from("imported_runs")
                .select("id")
                .eq("profile_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            if !residue.isEmpty {
                AppLog.importer.error("clearImportedRuns: residue after DELETE for profile \(userId.uuidString) — first stuck id \(residue[0].id). Likely RLS or stale session.")
            }
        } catch {
            AppLog.importer.error("clearImportedRuns: residue check failed: \(error.localizedDescription)")
        }
        // Recompute is server-side and idempotent — produces an empty
        // / zeroed `profile_stats` row when there are no imported_runs.
        try await client
            .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(userId.uuidString)])
            .execute()
        await loadProfileStats()
        // Drop the per-edge skill memory too — without this the
        // server table holds stale rows AND the in-memory
        // `currentEdgeSpeeds` keeps weighting solves with speeds
        // derived from runs that no longer exist. The RPC is
        // idempotent and recomputes from the (now empty)
        // imported_runs so the table ends up empty; the helper
        // also reloads `currentEdgeSpeeds` so the cache matches.
        _ = await recomputeProfileEdgeSpeeds()
    }

    /// Hard reset for the current user's run/skill data. Wipes
    /// `imported_runs`, recomputes (now-empty) `profile_stats`, clears
    /// `profile_edge_speeds`, and rolls the preset back to
    /// `intermediate` so the solver has a sane fallback.
    ///
    /// Preserved on purpose: the auth row, profile identity (id /
    /// display_name / avatar / current_resort_id), friendships, meet
    /// requests, and the on-device `FriendLocationStore` cache. PURGE
    /// is for "I want to start over with a clean activity slate," not
    /// "I want to nuke the account."
    func purgeUserData() async throws {
        guard let userId = currentSession?.user.id else { return }

        // 1. Wipe runs + recompute stats.
        try await clearImportedRuns()

        // 2. Drop edge-speed history. The RPC recomputes from
        //    imported_runs, which is now empty, so the table will
        //    end up empty for this user.
        _ = await recomputeProfileEdgeSpeeds()

        // 3. Roll preset back to intermediate.
        if var updated = currentUserProfile {
            updated.applyPreset("intermediate")
            let saved = try await sendFullProfileUpdate(updated)
            currentUserProfile = saved
        } else {
            // No cached profile: write the bare preset fields directly.
            let intermediateSpeeds: [String: AnyJSON] = [
                "skill_level": .string("intermediate"),
                "speed_green": .double(5.0),
                "speed_blue": .double(8.0),
                "speed_black": .double(3.0),
                "condition_moguls": .double(0.5),
                "condition_ungroomed": .double(0.6),
                "condition_icy": .double(0.5),
                "condition_gladed": .double(0.4)
            ]
            try await updateProfile(intermediateSpeeds)
            _ = userId  // suppress unused-warning when no cached profile path runs
        }
    }

    /// Fetches every `imported_runs` row for the current user, newest
    /// first. Used by the imported-runs viewer so the user can audit
    /// what was uploaded and delete selectively. RLS scopes the read to
    /// `auth.uid() = profile_id`.
    func fetchImportedRuns() async throws -> [ImportedRunRecord] {
        guard let userId = currentSession?.user.id else { return [] }
        let rows: [ImportedRunRecord] = try await client.from("imported_runs")
            .select()
            .eq("profile_id", value: userId.uuidString)
            .order("run_at", ascending: false)
            .execute()
            .value
        return rows
    }

    /// Re-resolves trail names for previously-imported runs at the given
    /// resort using the now-loaded graph. Targets rows where `trail_name`
    /// is null OR empty AND `resort_id` matches — these imported before
    /// the resort's graph was available, OR the strict matcher came up
    /// empty. Idempotent — rows that already have a trail name skip.
    func remapUnnamedRuns(resortId: String, graph: MountainGraph) async {
        guard let userId = currentSession?.user.id else { return }
        struct UnnamedRow: Decodable {
            let id: UUID
            let edge_id: String?
            let difficulty: String?
            let run_at: Date
        }
        let unnamed: [UnnamedRow]
        do {
            unnamed = try await client.from("imported_runs")
                .select("id,edge_id,difficulty,run_at")
                .eq("profile_id", value: userId.uuidString)
                .eq("resort_id", value: resortId)
                .or("trail_name.is.null,trail_name.eq.")
                .execute()
                .value
        } catch {
            AppLog.supabase.error("remapUnnamedRuns fetch failed: \(error.localizedDescription)")
            return
        }
        guard !unnamed.isEmpty else { return }

        let naming = MountainNaming(graph)
        struct UpdatePayload: Encodable { let trail_name: String }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        var updates = 0
        for row in unnamed {
            // Two paths:
            //   1. edge_id present → resolve through MountainNaming
            //      against the now-loaded graph. Most accurate, used
            //      for runs that strict-matched at import time.
            //   2. edge_id absent → synthesize a difficulty + time
            //      label so legacy rows imported before tier-3
            //      matching landed never display as a literal
            //      "Imported Run." Earlier remap logic skipped these
            //      entirely, leaving the long tail of pre-fix rows
            //      stuck on the viewer's last-resort fallback.
            let label: String
            if let edgeId = row.edge_id, let edge = graph.edge(byID: edgeId) {
                label = naming.edgeLabel(edge, style: .canonical)
            } else {
                let stamp = timeFormatter.string(from: row.run_at)
                if let diff = row.difficulty,
                   let raw = RunDifficulty(rawValue: diff) {
                    label = "\(raw.displayName) Run · \(stamp)"
                } else {
                    label = "Run · \(stamp)"
                }
            }
            do {
                try await client.from("imported_runs")
                    .update(UpdatePayload(trail_name: label))
                    .eq("id", value: row.id.uuidString)
                    .execute()
                updates += 1
            } catch {
                continue
            }
        }
        if updates > 0 {
            AppLog.supabase.debug("remapUnnamedRuns(\(resortId)): updated \(updates) row(s)")
        }
    }

    /// Restores imported_runs rows from a PowderMeet backup file. Each
    /// row is keyed to the importing user's profile_id and upserted on
    /// `(profile_id, dedup_hash)` — duplicates are silently skipped so
    /// re-importing the same backup is idempotent. After the upsert
    /// completes, `recompute_profile_stats` is called so the aggregate
    /// stats reflect the freshly-restored rows. Returns the number of
    /// rows actually inserted (i.e., new minus duplicates).
    @discardableResult
    func restoreImportedRuns(_ runs: [ImportedRunBackup]) async throws -> Int {
        guard !runs.isEmpty, let userId = currentSession?.user.id else { return 0 }
        let profileId = userId.uuidString

        // Encodable row mirrors ActivityImporter's ImportedRunRow but
        // accepts the backup's already-computed values. Defined inline
        // because nothing outside this method writes this shape.
        struct RestoreRow: Encodable {
            let profile_id: String
            let resort_id: String?
            let edge_id: String?
            let difficulty: String?
            let speed_ms: Double
            let peak_speed_ms: Double?
            let duration_s: Double
            let vertical_m: Double
            let distance_m: Double
            let max_grade_deg: Double
            let run_at: Date
            let dedup_hash: String
            let source: String?
            let source_file_hash: String?
            let trail_name: String?
        }

        let rows: [RestoreRow] = runs.map { run in
            RestoreRow(
                profile_id: profileId,
                resort_id: run.resortId,
                edge_id: run.edgeId,
                difficulty: run.difficulty,
                speed_ms: run.speedMs,
                peak_speed_ms: run.peakSpeedMs,
                duration_s: run.durationS,
                vertical_m: run.verticalM,
                distance_m: run.distanceM,
                max_grade_deg: run.maxGradeDeg,
                run_at: run.runAt,
                dedup_hash: run.dedupHash,
                source: run.source,
                source_file_hash: run.sourceFileHash,
                trail_name: run.trailName
            )
        }

        try await client.from("imported_runs")
            .upsert(rows, onConflict: "profile_id,dedup_hash", ignoreDuplicates: true)
            .execute()
        try await client
            .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(profileId)])
            .execute()
        await loadProfileStats()
        await recomputeProfileEdgeSpeeds()
        // recomputeProfileEdgeSpeeds already reloads currentEdgeSpeeds,
        // but be explicit here too — restore is the rare path where a
        // stale dict would silently return wrong predictions until cold
        // launch. Tiny cost; prevents the gap surfaced by the Phase 2
        // verification audit.
        await loadEdgeSpeedHistory()
        return rows.count
    }

    /// Restore-mode counterpart to `restoreImportedRuns`. Used by the
    /// `.powdermeet` backup import flow when the user expects the
    /// archived runs to *replace* whatever's currently in the table
    /// (the "this is my backup, put me back where I was" semantic).
    ///
    /// Differences vs `restoreImportedRuns`:
    ///
    ///   1. **Wipes the user's existing `imported_runs` first.** Backups
    ///      represent the world as of an instant; merging would either
    ///      double up or silently dedupe (which is what the user just
    ///      reported as "import does nothing").
    ///   2. **Force-tags `source = "powdermeet"`** so the restored runs
    ///      surface the red POWDERMEET pill in the log, distinguishing
    ///      them from their original origin (Slopes / Strava / HealthKit).
    ///   3. **Regenerates `dedup_hash`** with a `powdermeet|` prefix so
    ///      re-importing the same backup is still idempotent against
    ///      itself, but never collides with non-backup rows.
    ///
    /// Returns the number of rows actually written. Recomputes stats +
    /// edge speeds before returning so the UI is consistent on
    /// completion.
    @discardableResult
    func replaceImportedRunsFromBackup(_ runs: [ImportedRunBackup]) async throws -> Int {
        guard let userId = currentSession?.user.id else { return 0 }
        let profileId = userId.uuidString

        // 1. Wipe existing imported_runs — RLS scopes the delete to the
        //    caller. Empty backup → still wipes, which is intentional:
        //    importing a profile-only backup explicitly says "use these
        //    preferences and nothing else."
        try await client.from("imported_runs")
            .delete()
            .eq("profile_id", value: profileId)
            .execute()

        struct RestoreRow: Encodable {
            let profile_id: String
            let resort_id: String?
            let edge_id: String?
            let difficulty: String?
            let speed_ms: Double
            let peak_speed_ms: Double?
            let duration_s: Double
            let vertical_m: Double
            let distance_m: Double
            let max_grade_deg: Double
            let run_at: Date
            let dedup_hash: String
            let source: String?
            let source_file_hash: String?
            let trail_name: String?
        }

        // Preserve the ORIGINAL dedup_hash for each row. Earlier the
        // hash got rewritten to `powdermeet|<minute>|<resort>|<edge>`,
        // which collapsed multi-source backups: a Slopes row and a
        // HealthKit row that captured the same physical descent had
        // distinct `<source>|...` hashes in the source DB but rebuilt
        // to the SAME `powdermeet|...` hash here, blowing up the
        // INSERT on `(profile_id, dedup_hash)`. The DELETE above
        // already cleared the slate, so we don't need to namespace —
        // and de-duping by hash in-memory is a belt-and-suspenders
        // guard against any backup that already carried duplicate
        // hashes from a stale source DB.
        var seenHashes: Set<String> = []
        let rows: [RestoreRow] = runs.compactMap { run in
            guard seenHashes.insert(run.dedupHash).inserted else { return nil }
            return RestoreRow(
                profile_id: profileId,
                resort_id: run.resortId,
                edge_id: run.edgeId,
                difficulty: run.difficulty,
                speed_ms: run.speedMs,
                peak_speed_ms: run.peakSpeedMs,
                duration_s: run.durationS,
                vertical_m: run.verticalM,
                distance_m: run.distanceM,
                max_grade_deg: run.maxGradeDeg,
                run_at: run.runAt,
                dedup_hash: run.dedupHash,
                source: ImportSource.powdermeet.rawValue,
                source_file_hash: run.sourceFileHash,
                trail_name: run.trailName
            )
        }

        if !rows.isEmpty {
            // upsert with ignoreDuplicates so a partial-state DB (e.g.
            // a row that survived the DELETE because of replication
            // lag) doesn't fail the whole batch.
            try await client.from("imported_runs")
                .upsert(rows, onConflict: "profile_id,dedup_hash", ignoreDuplicates: true)
                .execute()
        }

        try await client
            .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(profileId)])
            .execute()
        await loadProfileStats()
        await recomputeProfileEdgeSpeeds()
        await loadEdgeSpeedHistory()
        return rows.count
    }

    /// Deletes one or more `imported_runs` rows by id, then recomputes
    /// `profile_stats` so the lifetime card reflects the deletion.
    /// RLS limits the DELETE to the caller's own rows.
    func deleteImportedRuns(ids: [UUID]) async throws {
        guard !ids.isEmpty, let userId = currentSession?.user.id else { return }
        let idStrings = ids.map { $0.uuidString }
        try await client.from("imported_runs")
            .delete()
            .in("id", values: idStrings)
            .execute()
        try await client
            .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(userId.uuidString)])
            .execute()
        await loadProfileStats()
        await recomputeProfileEdgeSpeeds()
    }

    // MARK: - Delete Account

    /// Calls the `delete_user_account` Postgres function (SECURITY DEFINER)
    /// which deletes friendships, profile, and auth.users row server-side,
    /// then cleans up avatar storage and signs out locally.
    func deleteAccount() async throws {
        guard let userId = currentSession?.user.id else { return }

        // Delete avatar from storage (can't do this from SQL)
        let avatarPath = "\(userId.uuidString.lowercased())/avatar.jpg"
        _ = try? await client.storage.from("avatars").remove(paths: [avatarPath])

        // Tear down ALL realtime channels before deleting — prevents stale
        // subscriptions from lingering when the user creates a new account.
        await client.realtimeV2.removeAllChannels()

        // Server-side: delete friendships, profile, and auth user (bypasses RLS)
        try await client.rpc("delete_user_account").execute()

        // Local cleanup — also clear the auth client session so any cached
        // JWT/refresh token is dropped. Without this the local `client.auth`
        // still thinks the (now-deleted) user is signed in until the next
        // cold launch; best-effort since the user was already deleted server-side.
        try? await client.auth.signOut()
        currentSession = nil
        currentUserProfile = nil
        currentUserStats = nil
        currentEdgeSpeeds = [:]
        friendEdgeSpeeds = [:]
        // Clear the on-disk friend-location SwiftData cache. Without
        // this, signing up a fresh account would surface the deleted
        // account's cached friend rows for a beat — the "ghost friend
        // request" the user noticed disappear on its own.
        // Instantiate a fresh FriendLocationStore and call clear() —
        // SwiftData's underlying container is shared on-disk, so a new
        // instance can wipe the same rows the live one was reading.
        // The live store (owned by ContentCoordinator) gets torn down
        // separately via teardown() on view disappear.
        if let store = try? FriendLocationStore() {
            store.clear()
        }
        // Drop the solver's static LRU — same reason as signOut.
        MeetingPointSolver.solutionCache.clear()
        sessionGeneration &+= 1
    }

    // MARK: - Avatar Upload

    /// Uploads avatar image to storage and returns the public URL.
    /// Does NOT update the profile row — the caller is responsible for that.
    ///
    /// Uses direct Storage REST instead of `client.storage.upload(...)`
    /// because the SDK's internal storage-client occasionally fails to
    /// pick up a freshly-installed JWT during onboarding. The avatars
    /// bucket RLS policy is:
    ///
    ///   bucket_id = 'avatars'
    ///   AND auth.uid() IS NOT NULL
    ///   AND (storage.foldername(name))[1] = auth.uid()::text
    ///
    /// When the SDK's auth header lags, `auth.uid()` resolves NULL on
    /// the request thread and the policy rejects the row. By hitting
    /// the REST endpoint ourselves with an explicit `Authorization:
    /// Bearer <jwt>` header sourced from `client.auth.session`, we
    /// guarantee the JWT is present on the request that produces the
    /// policy check.
    func uploadAvatar(imageData: Data) async throws -> String {
        // Force-fetch the SDK's current session — this refreshes if
        // expired and ensures we have a usable access token.
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            throw NSError(domain: "SupabaseManager", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated. Try signing out and back in."])
        }
        let userId = session.user.id
        let userIdLower = userId.uuidString.lowercased()
        let path = "\(userIdLower)/avatar.jpg"

        AppLog.supabase.debug("upload path=\(path) bytes=\(imageData.count)")

        // POST /storage/v1/object/avatars/<userId>/avatar.jpg
        // x-upsert: true overwrites the previous avatar without a 409.
        guard let url = URL(string: "\(Self.projectURL)/storage/v1/object/avatars/\(path)") else {
            throw NSError(domain: "SupabaseManager", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Bad storage URL"])
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: imageData)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "SupabaseManager", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's error body so RLS / quota / 4xx
            // failures read clearly.
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            AppLog.supabase.error("upload failed HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "SupabaseManager", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Storage upload \(http.statusCode): \(body.prefix(200))"])
        }

        // Public URL — bucket is public, so direct construction is
        // fine. No `?t=<epoch>` cache-buster: the timestamp varied
        // every upload, so any device that received the new URL via
        // postgres_changes saw an `AvatarCache` miss and flashed a
        // placeholder mid-fetch. With x-upsert the bucket object is
        // overwritten atomically; consumers see the updated bytes
        // on natural cache eviction or app foreground.
        let publicURL = "\(Self.projectURL)/storage/v1/object/public/avatars/\(path)"
        return publicURL
    }
}

// MARK: - Supabase ISO8601 Decoder

extension JSONDecoder {
    /// Shared decoder for Supabase realtime payloads.
    /// Supabase sends timestamps with fractional seconds (e.g. "2026-03-12T12:30:00.123456+00:00")
    /// which Foundation's built-in .iso8601 does NOT support — use a custom formatter.
    static let supabaseDecoder: JSONDecoder = {
        let d = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = formatter.date(from: str) { return date }
            if let date = fallback.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(str)"
            )
        }
        return d
    }()
}
