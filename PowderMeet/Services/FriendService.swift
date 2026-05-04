//
//  FriendService.swift
//  PowderMeet
//
//  Friend system — search users, send/accept/decline requests, load friends list.
//

import Foundation
import Observation
import Supabase

/// Params struct for the `get_social_snapshot` RPC. Declared at file scope so
/// its `Encodable` / `Sendable` conformances are not inferred as main-actor
/// isolated (Swift 6 rejects passing a MainActor-isolated Encodable into the
/// Sendable-generic Supabase RPC entrypoint).
private nonisolated struct GetSocialSnapshotParams: Encodable, Sendable {
    let p_resort_id: String?
}

@MainActor @Observable
final class FriendService {
    private let supabase: SupabaseManager
    private let registry: ChannelRegistry

    var friends: [UserProfile] = []
    var pendingReceived: [Friendship] = []
    var pendingSent: [Friendship] = []
    var searchResults: [UserProfile] = []
    var contactSuggestions: [UserProfile] = []
    var isLoading = false
    var isLoadingContactSuggestions = false

    /// True after `loadFriends()` has finished at least one full attempt for the
    /// current session. While false, `friends` may still be empty simply because
    /// the network fetch has not completed — not because the user has no friends.
    /// `RealtimeLocationService` uses this to avoid friend-filtering broadcasts
    /// against an empty set during that window.
    private(set) var isFriendListHydrated = false

    /// Monotonic counter bumped on every authoritative apply of social state
    /// (`loadSocialSnapshot`, `loadFriends`, realtime accept/decline patches).
    /// `0` means nothing authoritative has landed yet — `RealtimeLocationService`
    /// uses this as the broadcast gate per `CLAUDE.md` (social snapshot gate):
    /// position broadcasts from peers are discarded until the caller's
    /// social state is at least provisionally known, closing the
    /// "accept-everyone-during-cold-launch" window.
    private(set) var socialGeneration: UInt64 = 0

    /// Server-side generation stamp of the last applied snapshot, from
    /// `get_social_snapshot.generation`. Used to reject out-of-order snapshot
    /// applications when two in-flight RPCs land in reverse order.
    private var lastServerGeneration: Int64 = 0

    /// IDs dismissed by the user so they don't re-appear this session.
    private var dismissedSuggestionIds: Set<UUID> = []

    /// Per-user friendship channel name. Held separately from MeetRequestService's
    /// `meets:{id}` channel because Supabase requires all `postgresChange()`
    /// registrations to land BEFORE the first `subscribeWithError()` — sharing
    /// one channel between two services races on that ordering.
    private var sharedChannelName: String?
    private var insertTask: Task<Void, Never>?
    private var updateRequesterTask: Task<Void, Never>?
    private var updateAddresseeTask: Task<Void, Never>?
    private var deleteRequesterTask: Task<Void, Never>?
    private var deleteAddresseeTask: Task<Void, Never>?

    init(supabase: SupabaseManager? = nil, registry: ChannelRegistry? = nil) {
        self.supabase = supabase ?? .shared
        self.registry = registry ?? ChannelRegistry.shared
    }

    // MARK: - Realtime

    /// Subscribe to friendship changes so the UI updates when someone
    /// accepts/declines a request or sends a new one. Owns its own
    /// `friends:{userId}` channel — MeetRequestService uses `meets:{id}`.
    func startRealtimeSubscription() async {
        // Tear down any existing subscription
        await stopRealtimeSubscription()

        guard let userId = supabase.currentSession?.user.id else { return }
        let name = "friends:\(userId.uuidString)"
        sharedChannelName = name

        // Prepare (or reuse) the shared channel and register filters BEFORE
        // subscribe — Supabase requires postgresChange() to land first.
        let channel = await registry.prepare(name: name)

        let insertions = channel.postgresChange(
            InsertAction.self,
            table: "friendships",
            filter: .eq("addressee_id", value: userId.uuidString)
        )
        let updatesAsRequester = channel.postgresChange(
            UpdateAction.self,
            table: "friendships",
            filter: .eq("requester_id", value: userId.uuidString)
        )
        let updatesAsAddressee = channel.postgresChange(
            UpdateAction.self,
            table: "friendships",
            filter: .eq("addressee_id", value: userId.uuidString)
        )
        // DELETE handlers — without these, an unfriend or a decline by the
        // other side is invisible on this device until a manual refresh.
        // Filter is split by role because postgresChange() only accepts a
        // single eq() predicate per registration.
        let deletesAsRequester = channel.postgresChange(
            DeleteAction.self,
            table: "friendships",
            filter: .eq("requester_id", value: userId.uuidString)
        )
        let deletesAsAddressee = channel.postgresChange(
            DeleteAction.self,
            table: "friendships",
            filter: .eq("addressee_id", value: userId.uuidString)
        )

        do {
            try await registry.subscribe(name: name)
            print("[FriendService] realtime subscribed (shared user channel)")
        } catch {
            print("[FriendService] subscribe failed: \(error)")
            await registry.release(name: name)
            sharedChannelName = nil
            return
        }

        // Every friendship change refreshes via the atomic snapshot RPC
        // rather than two parallel fetches — so the UI never sees a
        // "friend in both accepted and pending" intermediate state that
        // postgres snapshot boundaries can produce when we split the read.
        // Per `CLAUDE.md` (social snapshot): re-fetch snapshot on each change
        // for correctness; incremental patching deferred.
        insertTask = Task { [weak self] in
            for await _ in insertions {
                await self?.loadSocialSnapshot()
            }
        }
        updateRequesterTask = Task { [weak self] in
            for await _ in updatesAsRequester {
                await self?.loadSocialSnapshot()
            }
        }
        updateAddresseeTask = Task { [weak self] in
            for await _ in updatesAsAddressee {
                await self?.loadSocialSnapshot()
            }
        }
        deleteRequesterTask = Task { [weak self] in
            for await _ in deletesAsRequester {
                await self?.loadSocialSnapshot()
            }
        }
        deleteAddresseeTask = Task { [weak self] in
            for await _ in deletesAsAddressee {
                await self?.loadSocialSnapshot()
            }
        }
    }

    func stopRealtimeSubscription() async {
        insertTask?.cancel(); insertTask = nil
        updateRequesterTask?.cancel(); updateRequesterTask = nil
        updateAddresseeTask?.cancel(); updateAddresseeTask = nil
        deleteRequesterTask?.cancel(); deleteRequesterTask = nil
        deleteAddresseeTask?.cancel(); deleteAddresseeTask = nil
        if let name = sharedChannelName {
            await registry.release(name: name)
            sharedChannelName = nil
        }
    }

    // MARK: - Reset (on sign-out / account deletion)

    /// Clears all cached state so the service is ready for a fresh user session.
    /// Called by ContentView.onDisappear when the user signs out or deletes their account.
    func reset() {
        friends = []
        pendingReceived = []
        pendingSent = []
        searchResults = []
        contactSuggestions = []
        isLoading = false
        isLoadingContactSuggestions = false
        dismissedSuggestionIds = []
        isFriendListHydrated = false
        socialGeneration = 0
        lastServerGeneration = 0
        print("[FriendService] reset — all cached state cleared")
    }

    // MARK: - Social snapshot (atomic cold-start + refresh)

    /// Atomic read of friends + pending via the `get_social_snapshot` RPC.
    ///
    /// Replaces the legacy parallel `loadFriends()` + `loadPending()` cold
    /// path, which raced on Postgres snapshot boundaries (a freshly-accepted
    /// friend could appear in `friends` while still appearing in
    /// `pendingReceived`, producing the amber "PENDING" flash on already-
    /// accepted friends). One transaction → one `MainActor` apply → one
    /// `socialGeneration` bump → consistent UI.
    ///
    /// The server's `generation` stamp (nanoseconds) makes this safe against
    /// out-of-order RPC returns: if a stale in-flight snapshot lands after a
    /// newer one, its server generation is smaller and the client discards it.
    ///
    /// See `CLAUDE.md` — Key architectural invariants (social snapshot gate).
    @discardableResult
    func loadSocialSnapshot(resortId: String? = nil) async -> Bool {
        guard supabase.currentSession?.user.id != nil else { return false }
        let startGen = supabase.sessionGeneration
        isLoading = true
        defer { isLoading = false }

        let payload: SocialSnapshotPayload
        do {
            payload = try await supabase.client
                .rpc("get_social_snapshot",
                     params: GetSocialSnapshotParams(p_resort_id: resortId))
                .execute()
                .value
        } catch {
            print("[FriendService] get_social_snapshot failed: \(error)")
            // Fall back to the legacy split-fetch path so the user still
            // sees their friends even if the RPC is missing or errored on
            // a particular environment.
            async let f: () = loadFriends()
            async let p: () = loadPending()
            _ = await (f, p)
            return false
        }

        // Session rotated — discard.
        guard supabase.sessionGeneration == startGen else { return false }

        // Out-of-order snapshot — discard (a newer one already applied).
        if payload.generation > 0 && payload.generation <= lastServerGeneration {
            print("[FriendService] discarding stale snapshot gen=\(payload.generation) <= \(lastServerGeneration)")
            return false
        }

        // Capture previous pending IDs before the swap so we can notify
        // on net-new incoming friend requests.
        let previousPendingIds = Set(self.pendingReceived.map(\.id))

        // Single atomic MainActor apply — no intermediate empty states.
        self.friends = payload.friends.map { $0.toUserProfile() }
        self.pendingReceived = payload.pendingReceived.map { $0.toFriendship() }
        self.pendingSent = payload.pendingSent.map { $0.toFriendship() }
        refilterSuggestions()

        // Friend-request notifications are delivered server-side via
        // the `notify_friend_request_insert` trigger → `send-push` edge
        // function → APNs. Local in-app notifications would either
        // duplicate the system banner (foreground) or be silenced by
        // permission state (background). Capturing previousPendingIds
        // is no longer needed; left in for future delta-driven UI.
        _ = previousPendingIds

        lastServerGeneration = payload.generation
        isFriendListHydrated = true
        socialGeneration &+= 1
        return true
    }

    /// RPC response shape. Must match `supabase/migrations/20260418_get_social_snapshot.sql`.
    private struct SocialSnapshotPayload: Decodable {
        let generation: Int64
        let friends: [FriendSummary]
        let pendingReceived: [FriendshipRow]
        let pendingSent: [FriendshipRow]
        // presence is decoded by RealtimeLocationService separately; FriendService
        // doesn't need it.

        enum CodingKeys: String, CodingKey {
            case generation
            case friends
            case pendingReceived = "pending_received"
            case pendingSent = "pending_sent"
        }

        struct FriendSummary: Decodable {
            let id: UUID
            let displayName: String
            let avatarUrl: String?
            let skillLevel: String?
            let currentResortId: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case avatarUrl = "avatar_url"
                case skillLevel = "skill_level"
                case currentResortId = "current_resort_id"
            }

            func toUserProfile() -> UserProfile {
                var p = UserProfile.defaultProfile(id: id)
                p.displayName = displayName
                p.avatarUrl = avatarUrl
                p.currentResortId = currentResortId
                if let s = skillLevel { p.skillLevel = s }
                p.onboardingCompleted = true
                return p
            }
        }

        struct FriendshipRow: Decodable {
            let id: UUID
            let requesterId: UUID
            let addresseeId: UUID
            let status: String
            let createdAt: Date?

            enum CodingKeys: String, CodingKey {
                case id
                case requesterId = "requester_id"
                case addresseeId = "addressee_id"
                case status
                case createdAt = "created_at"
            }

            func toFriendship() -> Friendship {
                Friendship(
                    id: id,
                    requesterId: requesterId,
                    addresseeId: addresseeId,
                    status: status,
                    createdAt: createdAt
                )
            }
        }
    }

    // MARK: - Load Friends

    /// Fetch all accepted friendships and resolve profiles.
    func loadFriends() async {
        guard let userId = supabase.currentSession?.user.id else { return }
        let startGen = supabase.sessionGeneration
        isLoading = true
        do {
            // Accepted friendships where I'm either requester or addressee
            let friendships: [Friendship] = try await supabase.client.from("friendships")
                .select()
                .eq("status", value: "accepted")
                .or("requester_id.eq.\(userId.uuidString),addressee_id.eq.\(userId.uuidString)")
                .execute()
                .value

            // Session rotated mid-flight — discard results so a stale query can't
            // repopulate (or wipe) the new session's cache.
            guard supabase.sessionGeneration == startGen else {
                isLoading = false
                return
            }

            // Collect friend IDs
            let friendIds = friendships.compactMap { f -> UUID? in
                let reqId = f.requesterId
                let addId = f.addresseeId
                return reqId == userId ? addId : reqId
            }

            if !friendIds.isEmpty {
                let profiles: [UserProfile] = try await supabase.client.from("profiles")
                    .select()
                    .in("id", values: friendIds.map { $0.uuidString })
                    .execute()
                    .value
                guard supabase.sessionGeneration == startGen else {
                    isLoading = false
                    return
                }
                self.friends = profiles
            } else if self.friends.isEmpty {
                // Only commit an empty result if we had nothing anyway. A zero-row
                // response during a token refresh / RLS blip must NOT wipe a
                // populated cache — that's what was flashing "ADD FRIEND" on
                // real friends until the next refresh.
                self.friends = []
            }
            refilterSuggestions()

        } catch {
            print("[FriendService] loadFriends error: \(error)")
        }
        prunePendingOverlappingFriends()
        isLoading = false
        // Only mark hydrated if we didn't bail early on a session-generation
        // mismatch (those returns mean this fetch wasn't authoritative).
        if supabase.sessionGeneration == startGen {
            isFriendListHydrated = true
            // Bump socialGeneration so the broadcast gate opens even when the
            // snapshot RPC is unavailable and we fell back to the legacy path.
            socialGeneration &+= 1
        }
    }

    // MARK: - Load Pending Requests

    func loadPending() async {
        guard let userId = supabase.currentSession?.user.id else { return }
        do {
            // Fetch received and sent in parallel — two independent queries.
            async let receivedTask: [Friendship] = supabase.client.from("friendships")
                .select()
                .eq("addressee_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .execute()
                .value
            async let sentTask: [Friendship] = supabase.client.from("friendships")
                .select()
                .eq("requester_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .execute()
                .value

            let (received, sent) = try await (receivedTask, sentTask)
            self.pendingReceived = received
            self.pendingSent = sent
            refilterSuggestions()

        } catch {
            print("[FriendService] loadPending error: \(error)")
        }
        prunePendingOverlappingFriends()
    }

    /// Removes pending rows that cannot coexist with accepted friendships.
    /// `loadFriends` and `loadPending` run in parallel on startup; Postgres
    /// snapshot timing can leave a stale `pending` row in memory after the
    /// accepted profile list has already hydrated — that flashes amber PENDING
    /// in search even though `relationshipStatus` will soon prefer `.friends`.
    private func prunePendingOverlappingFriends() {
        let friendIds = Set(friends.map(\.id))
        guard !friendIds.isEmpty else { return }
        pendingSent.removeAll { friendIds.contains($0.addresseeId) }
        pendingReceived.removeAll { friendIds.contains($0.requesterId) }
    }

    // MARK: - Search Users

    func searchUsers(query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            await MainActor.run { searchResults = [] }
            return
        }
        guard let userId = supabase.currentSession?.user.id else { return }
        do {
            let results: [UserProfile] = try await supabase.client.from("profiles")
                .select()
                .ilike("display_name", pattern: "%\(query)%")
                .neq("id", value: userId.uuidString)
                .limit(20)
                .execute()
                .value
            await MainActor.run { self.searchResults = results }
        } catch {
            print("[FriendService] searchUsers error: \(error)")
        }
    }

    // MARK: - Send Friend Request

    func sendRequest(to addresseeId: UUID) async throws {
        guard supabase.currentSession?.user.id != nil else { return }
        let startGen = supabase.sessionGeneration

        // Atomic dedupe + insert via SECURITY DEFINER RPC. The previous
        // version did `select existing → maybe insert` from the client,
        // which had a narrow race under simultaneous taps + realtime echo
        // (two `pending` rows for the same pair). The `send_friend_request`
        // RPC (migration 20260425_send_friend_request_rpc.sql) collapses
        // both steps into one SQL call: it inspects the friendships table
        // under SECURITY DEFINER, dedupes against accepted/pending rows
        // either direction, and only inserts a fresh row if the slot is
        // genuinely empty (or the prior row was declined/expired).
        try await supabase.client.rpc(
            "send_friend_request",
            params: ["p_addressee_id": AnyJSON.string(addresseeId.uuidString)]
        ).execute()
        guard supabase.sessionGeneration == startGen else { return }

        // Refresh both lists. The RPC may have returned an existing
        // accepted row (so loadFriends should re-render) or a new pending
        // row (so loadPending picks it up).
        await loadFriends()
        await loadPending()
    }

    // MARK: - Accept / Decline

    func acceptRequest(_ friendshipId: UUID) async throws {
        let startGen = supabase.sessionGeneration

        // ── Optimistic UI update ──
        // Remove from pending IMMEDIATELY so the card disappears without
        // waiting for the DB roundtrip. The user sees instant feedback.
        let previousPending = pendingReceived
        let acceptedFriendship = pendingReceived.first(where: { $0.id == friendshipId })
        pendingReceived.removeAll(where: { $0.id == friendshipId })

        // ── DB update ──
        // Rollback the optimistic removal if the update fails — otherwise a
        // transient network error leaves the card gone while the row stays
        // `pending` on the server, and the user has no way to retry until a
        // realtime refresh arrives. Matches the pattern used in
        // `MeetRequestService.acceptRequest`.
        do {
            try await supabase.client.from("friendships")
                .update(["status": "accepted"])
                .eq("id", value: friendshipId.uuidString)
                .execute()
        } catch {
            if supabase.sessionGeneration == startGen {
                pendingReceived = previousPending
            }
            throw error
        }

        // Session rotated mid-flight — drop follow-up writes to the new
        // session's cache (the new user has no business seeing the old
        // account's accepted friendship).
        guard supabase.sessionGeneration == startGen else { return }

        // ── Eagerly fetch the new friend's profile ──
        // This makes the friend appear in the list without waiting for a full loadFriends() sweep.
        var addedProfileName: String?
        if let requesterId = acceptedFriendship?.requesterId,
           !friends.contains(where: { $0.id == requesterId }) {
            if let profile = await loadProfile(id: requesterId),
               supabase.sessionGeneration == startGen {
                friends.append(profile)
                refilterSuggestions()
                addedProfileName = profile.displayName
            }
        }

        // Friend-added notifications are delivered to the requester
        // via the `notify_friend_accepted` trigger → APNs path. The
        // accepting user (this device) doesn't get a notification —
        // they just took the action.
        _ = addedProfileName

        // ── Background refresh for full consistency ──
        _ = await loadSocialSnapshot()
    }

    func declineRequest(_ friendshipId: UUID) async throws {
        let startGen = supabase.sessionGeneration
        // Optimistic remove so the card disappears without the roundtrip.
        pendingReceived.removeAll(where: { $0.id == friendshipId })
        try await supabase.client.from("friendships")
            .delete()
            .eq("id", value: friendshipId.uuidString)
            .execute()
        guard supabase.sessionGeneration == startGen else { return }
        await loadPending()
    }

    /// Withdraw a request we sent that the recipient hasn't acted on yet.
    /// Without this the sender has no way to back out — the PENDING badge
    /// just sits there forever unless the other side declines.
    func cancelSentRequest(to addresseeId: UUID) async throws {
        guard let userId = supabase.currentSession?.user.id else { return }
        let startGen = supabase.sessionGeneration
        // Optimistic: drop the matching pending row locally so the UI
        // flips back to "ADD" immediately.
        pendingSent.removeAll { $0.addresseeId == addresseeId && $0.requesterId == userId }
        try await supabase.client.from("friendships")
            .delete()
            .eq("requester_id", value: userId.uuidString)
            .eq("addressee_id", value: addresseeId.uuidString)
            .eq("status", value: "pending")
            .execute()
        guard supabase.sessionGeneration == startGen else { return }
        await loadPending()
    }

    // MARK: - Remove Friend

    func removeFriend(_ friendId: UUID) async throws {
        guard let userId = supabase.currentSession?.user.id else { return }
        let startGen = supabase.sessionGeneration
        // Optimistic: drop from in-memory friends list so the row disappears
        // immediately. Realtime DELETE event on the other device handles the
        // far side (see startRealtimeSubscription DeleteAction handlers).
        friends.removeAll { $0.id == friendId }
        try await supabase.client.from("friendships")
            .delete()
            .or("and(requester_id.eq.\(userId.uuidString),addressee_id.eq.\(friendId.uuidString)),and(requester_id.eq.\(friendId.uuidString),addressee_id.eq.\(userId.uuidString))")
            .execute()
        guard supabase.sessionGeneration == startGen else { return }
        await loadFriends()
    }

    // MARK: - Contact Suggestions

    /// Fetches contact emails and phone numbers, then calls Supabase RPCs
    /// to find matching profiles. Filters out existing friends, pending requests,
    /// and dismissed entries.
    func loadContactSuggestions() async {
        guard !isLoadingContactSuggestions else { return }
        isLoadingContactSuggestions = true
        defer { isLoadingContactSuggestions = false }

        let (emails, phones) = await ContactsService.shared.fetchContactEmailsAndPhones()
        guard let userId = supabase.currentSession?.user.id else { return }
        guard !emails.isEmpty || !phones.isEmpty else { return }

        var allMatches: [UUID: UserProfile] = [:]

        // Match by email
        if !emails.isEmpty {
            do {
                let matches: [UserProfile] = try await supabase.client
                    .rpc("find_users_by_emails", params: ["emails": emails])
                    .execute()
                    .value
                for m in matches { allMatches[m.id] = m }
            } catch {
                print("[FriendService] email suggestions error: \(error)")
            }
        }

        // Match by phone number
        if !phones.isEmpty {
            do {
                let matches: [UserProfile] = try await supabase.client
                    .rpc("find_users_by_phones", params: ["phones": phones])
                    .execute()
                    .value
                for m in matches { allMatches[m.id] = m }
            } catch {
                print("[FriendService] phone suggestions error: \(error)")
                // Silently fail — RPC may not be set up yet
            }
        }

        let friendIds  = Set(friends.map(\.id))
        let pendingIds = Set(pendingSent.map(\.addresseeId) + pendingReceived.map(\.requesterId))

        contactSuggestions = Array(allMatches.values).filter {
            $0.id != userId
                && !friendIds.contains($0.id)
                && !pendingIds.contains($0.id)
                && !dismissedSuggestionIds.contains($0.id)
        }
    }

    /// Hides a suggestion for the rest of the session without sending a request.
    func dismissSuggestion(_ id: UUID) {
        dismissedSuggestionIds.insert(id)
        contactSuggestions.removeAll { $0.id == id }
    }

    /// Prunes `contactSuggestions` so nobody already in friends or pending
    /// appears in the SUGGESTED section. Called from every path that mutates
    /// the friendship graph — `loadContactSuggestions` runs a filter once at
    /// fetch time, but accept / decline / remove / cancel all happen later
    /// and would otherwise leave stale entries in view.
    private func refilterSuggestions() {
        guard !contactSuggestions.isEmpty else { return }
        let friendIds = Set(friends.map(\.id))
        let pendingIds = Set(pendingSent.map(\.addresseeId) + pendingReceived.map(\.requesterId))
        contactSuggestions.removeAll {
            friendIds.contains($0.id) || pendingIds.contains($0.id)
        }
    }

    // MARK: - Helpers

    /// Check if a user is already a friend or has pending request.
    func relationshipStatus(with userId: UUID) -> RelationshipStatus {
        if friends.contains(where: { $0.id == userId }) { return .friends }
        if pendingSent.contains(where: { $0.addresseeId == userId }) { return .pendingSent }
        if pendingReceived.contains(where: { $0.requesterId == userId }) { return .pendingReceived }
        return .none
    }

    /// Resolve a profile by ID for pending request display.
    func loadProfile(id: UUID) async -> UserProfile? {
        do {
            let profile: UserProfile = try await supabase.client.from("profiles")
                .select()
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value
            return profile
        } catch {
            return nil
        }
    }

    enum RelationshipStatus {
        case none, friends, pendingSent, pendingReceived
    }
}

// MARK: - Friendship Model

struct Friendship: Codable, Identifiable {
    let id: UUID
    let requesterId: UUID
    let addresseeId: UUID
    let status: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
        case status
        case createdAt = "created_at"
    }
}

struct NewFriendship: Codable {
    let requesterId: UUID
    let addresseeId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
        case status
    }
}

