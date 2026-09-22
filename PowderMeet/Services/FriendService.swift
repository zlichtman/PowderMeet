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
    let supabase: SupabaseManager
    let registry: ChannelRegistry

    var friends: [UserProfile] = []
    var pendingReceived: [Friendship] = []
    var pendingSent: [Friendship] = []
    var searchResults: [UserProfile] = []
    var contactSuggestions: [UserProfile] = []
    var isLoading = false
    var isLoadingContactSuggestions = false

    /// Set of user IDs the local user has blocked. Hides those users
    /// from search results, contact suggestions, and the friends list,
    /// and (server-side) from `live_presence` / `profile_edge_speeds`
    /// reads via the RLS exclude clause introduced in the
    /// `user_blocks` migration. Loaded once at cold launch alongside
    /// the social snapshot; mutated optimistically by `block(_:)` /
    /// `unblock(_:)`.
    var blockedUserIds: Set<UUID> = []
    /// Display profiles for the user IDs in `blockedUserIds`. Looked
    /// up once when the blocked-users sheet opens — there's no
    /// realtime path for unblocking, so a snapshot at sheet-open is
    /// fine.
    var blockedProfiles: [UserProfile] = []

    /// Per-friend stats cache. Populated lazily by `loadStatsBatch(for:)`
    /// when the friends list renders. `lastStatsLoadAt` rate-limits
    /// re-fetches per friend to once per 24h so scrolling the friends
    /// tab doesn't hammer the profiles+stats endpoint.
    var profileStatsCache: [UUID: ProfileStats] = [:]
    var lastStatsLoadAt: [UUID: Date] = [:]

    /// True after `loadFriends()` has finished at least one full attempt for the
    /// current session. While false, `friends` may still be empty simply because
    /// the network fetch has not completed — not because the user has no friends.
    /// `RealtimeLocationService` uses this to avoid friend-filtering broadcasts
    /// against an empty set during that window.
    private(set) var isFriendListHydrated = false

    /// Monotonic counter bumped on every authoritative apply of social state
    /// (`loadSocialSnapshot`, `loadFriends`, realtime accept/decline patches).
    /// `0` means nothing authoritative has landed yet — `RealtimeLocationService`
    /// uses this as the broadcast gate per `AGENTS.md` (social snapshot gate):
    /// position broadcasts from peers are discarded until the caller's
    /// social state is at least provisionally known, closing the
    /// "accept-everyone-during-cold-launch" window.
    private(set) var socialGeneration: UInt64 = 0

    /// Server-side generation stamp of the last applied snapshot, from
    /// `get_social_snapshot.generation`. Used to reject out-of-order snapshot
    /// applications when two in-flight RPCs land in reverse order.
    var lastServerGeneration: Int64 = 0

    /// IDs dismissed by the user so they don't re-appear this session.
    var dismissedSuggestionIds: Set<UUID> = []

    /// Per-user friendship channel name. Held separately from MeetRequestService's
    /// `meets:{id}` channel because Supabase requires all `postgresChange()`
    /// registrations to land BEFORE the first `subscribeWithError()` — sharing
    /// one channel between two services races on that ordering.
    private(set) var subscriptionState: RealtimeSubscriptionState = .stopped
    private var subscriptionGeneration: UInt64 = 0
    var insertTask: Task<Void, Never>?
    var updateRequesterTask: Task<Void, Never>?
    var updateAddresseeTask: Task<Void, Never>?
    var deleteRequesterTask: Task<Void, Never>?
    var deleteAddresseeTask: Task<Void, Never>?

    init(supabase: SupabaseManager? = nil, registry: ChannelRegistry? = nil) {
        self.supabase = supabase ?? .shared
        self.registry = registry ?? ChannelRegistry.shared
    }

    // MARK: - Realtime

    /// Subscribe to friendship changes so the UI updates when someone
    /// accepts/declines a request or sends a new one. Owns its own
    /// `friends:{userId}` channel — MeetRequestService uses `meets:{id}`.
    func startRealtimeSubscription() async {
        guard let userId = supabase.currentSession?.user.id else { return }
        let name = "friends:\(userId.uuidString)"
        guard subscriptionState.canBegin(channelName: name) else {
            print("[FriendService] realtime start ignored in state \(String(describing: subscriptionState))")
            return
        }
        if subscriptionState != .stopped {
            await stopRealtimeSubscription()
        }
        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        subscriptionState = .connecting(channelName: name)

        // Prepare (or reuse) the shared channel and register filters BEFORE
        // subscribe — Supabase requires postgresChange() to land first.
        let channel = await registry.prepare(name: name)
        guard generation == subscriptionGeneration,
              subscriptionState == .connecting(channelName: name) else {
            await registry.release(name: name)
            return
        }

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
            if generation == subscriptionGeneration {
                subscriptionState = .stopped
            }
            return
        }
        guard generation == subscriptionGeneration,
              subscriptionState == .connecting(channelName: name) else {
            await registry.release(name: name)
            return
        }
        subscriptionState = .listening(channelName: name)

        // Every friendship change refreshes via the atomic snapshot RPC
        // rather than two parallel fetches — so the UI never sees a
        // "friend in both accepted and pending" intermediate state that
        // postgres snapshot boundaries can produce when we split the read.
        // Per `AGENTS.md` (social snapshot): re-fetch snapshot on each change
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
        subscriptionGeneration &+= 1
        let name = subscriptionState.channelName
        subscriptionState = .stopping(channelName: name)
        insertTask?.cancel(); insertTask = nil
        updateRequesterTask?.cancel(); updateRequesterTask = nil
        updateAddresseeTask?.cancel(); updateAddresseeTask = nil
        deleteRequesterTask?.cancel(); deleteRequesterTask = nil
        deleteAddresseeTask?.cancel(); deleteAddresseeTask = nil
        if let name {
            await registry.release(name: name)
        }
        subscriptionState = .stopped
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
        blockedUserIds = []
        blockedProfiles = []
        profileStatsCache = [:]
        lastStatsLoadAt = [:]
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
    /// See `AGENTS.md` — Key architectural invariants (social snapshot gate).
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

        // Diff before reassigning. The RPC fires on every realtime
        // event (presence ticks, location updates, peer activity) and
        // typically returns the same snapshot back. Reassigning the
        // arrays unconditionally hands SwiftUI fresh struct instances,
        // which causes any LazyVStack-virtualized friend rows to
        // re-mount on next paint — and a re-mount resets the
        // `CachedAvatarView`'s `@State image` to nil for one frame
        // before the cache lookup completes. That's the visible
        // "avatar bug-out" the user was reporting.
        //
        // UserProfile + Friendship are Equatable, so we can compare
        // arrays cheaply and skip the assignment when contents match.
        let nextFriends = payload.friends.map { $0.toUserProfile() }
        let nextPendingReceived = payload.pendingReceived.map { $0.toFriendship() }
        let nextPendingSent = payload.pendingSent.map { $0.toFriendship() }

        if self.friends != nextFriends {
            self.friends = nextFriends
        }
        if self.pendingReceived != nextPendingReceived {
            self.pendingReceived = nextPendingReceived
        }
        if self.pendingSent != nextPendingSent {
            self.pendingSent = nextPendingSent
        }
        refilterSuggestions()

        // Load blocks + stats in parallel with the rest. Blocks come
        // from a different table; the snapshot RPC doesn't include
        // them. Stats are per-friend, fetched in batch once the
        // friend list is known.
        let friendIds = self.friends.map(\.id)
        Task { await self.loadBlocks() }
        Task { await self.loadStatsBatch(for: friendIds) }

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
    private nonisolated struct SocialSnapshotPayload: Decodable, Sendable {
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

        nonisolated struct FriendSummary: Decodable, Sendable {
            let id: UUID
            let displayName: String
            let avatarUrl: String?
            let skillLevel: String?
            let currentResortId: String?
            let preferredSkiId: UUID?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case avatarUrl = "avatar_url"
                case skillLevel = "skill_level"
                case currentResortId = "current_resort_id"
                case preferredSkiId = "preferred_ski_id"
            }

            func toUserProfile() -> UserProfile {
                var p = UserProfile.defaultProfile(id: id)
                p.displayName = displayName
                p.avatarUrl = avatarUrl
                p.currentResortId = currentResortId
                p.preferredSkiId = preferredSkiId
                if let s = skillLevel { p.skillLevel = s }
                p.onboardingCompleted = true
                return p
            }
        }

        nonisolated struct FriendshipRow: Decodable, Sendable {
            let id: UUID
            let requesterId: UUID
            let addresseeId: UUID
            let status: FriendshipStatus
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
                .eq("status", value: FriendshipStatus.accepted.rawValue)
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
                .eq("status", value: FriendshipStatus.pending.rawValue)
                .execute()
                .value
            async let sentTask: [Friendship] = supabase.client.from("friendships")
                .select()
                .eq("requester_id", value: userId.uuidString)
                .eq("status", value: FriendshipStatus.pending.rawValue)
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
    func prunePendingOverlappingFriends() {
        let friendIds = Set(friends.map(\.id))
        guard !friendIds.isEmpty else { return }
        pendingSent.removeAll { friendIds.contains($0.addresseeId) }
        pendingReceived.removeAll { friendIds.contains($0.requesterId) }
    }

}

// MARK: - Friendship Model

nonisolated struct Friendship: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let requesterId: UUID
    let addresseeId: UUID
    let status: FriendshipStatus
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
        case status
        case createdAt = "created_at"
    }
}

nonisolated struct NewFriendship: Codable, Sendable {
    let requesterId: UUID
    let addresseeId: UUID
    let status: FriendshipStatus

    enum CodingKeys: String, CodingKey {
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
        case status
    }
}
