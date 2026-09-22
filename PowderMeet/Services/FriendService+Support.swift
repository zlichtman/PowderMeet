//
//  FriendService+Support.swift
//  PowderMeet
//
//  Extension of FriendService — helpers, block/unblock, per-friend stats cache.
//  Split out of FriendService.swift (behavior-preserving). Methods inherit
//  @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension FriendService {
    // MARK: - Helpers

    /// Check if a user is already a friend or has pending request.
    func relationshipStatus(with userId: UUID) -> RelationshipStatus {
        if blockedUserIds.contains(userId) { return .blocked }
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
        case none, friends, pendingSent, pendingReceived, blocked
    }

    // MARK: - Blocks

    private struct BlockRow: Decodable {
        let blockee_id: UUID
    }

    /// Reload `blockedUserIds` from `user_blocks`. Called from
    /// `loadSocialSnapshot` and from the blocked-users sheet on open.
    func loadBlocks() async {
        guard let userId = supabase.currentSession?.user.id else { return }
        do {
            let rows: [BlockRow] = try await supabase.client.from("user_blocks")
                .select("blockee_id")
                .eq("blocker_id", value: userId.uuidString)
                .execute()
                .value
            blockedUserIds = Set(rows.map(\.blockee_id))
            // Drop blocked users from any local arrays the client
            // hydrated before the block list landed (cold-launch race
            // where the social snapshot returned a friend that is
            // also blocked — RLS on the snapshot RPC may not yet apply
            // the exclude predicate the same way regular table reads do).
            applyBlockFilter()
        } catch {
            AppLog.supabase.error("loadBlocks failed: \(error.localizedDescription)")
        }
    }

    /// Look up display profiles for currently-blocked users. Used by
    /// `BlockedUsersSheet` to render the unblock list — there's no
    /// realtime channel for blocks so we re-fetch on sheet open.
    func loadBlockedProfiles() async {
        guard !blockedUserIds.isEmpty else {
            blockedProfiles = []
            return
        }
        do {
            let ids = blockedUserIds.map(\.uuidString)
            let profiles: [UserProfile] = try await supabase.client.from("profiles")
                .select()
                .in("id", values: ids)
                .execute()
                .value
            blockedProfiles = profiles
        } catch {
            AppLog.supabase.error("loadBlockedProfiles failed: \(error.localizedDescription)")
        }
    }

    /// Block a user. Optimistically removes them from every local
    /// roster (friends / pending / search / suggestions) so the UI
    /// updates immediately, then writes the block row. The server-side
    /// RLS exclude predicate makes the block authoritative — any
    /// further reads of `friendships` / `live_presence` /
    /// `profile_edge_speeds` from the blocker's perspective will not
    /// see the blockee, regardless of friendship status.
    func block(_ userId: UUID) async {
        guard let blockerId = supabase.currentSession?.user.id else { return }
        guard userId != blockerId else { return }
        // Optimistic local apply.
        blockedUserIds.insert(userId)
        applyBlockFilter()
        struct BlockInsert: Encodable {
            let blocker_id: String
            let blockee_id: String
        }
        do {
            try await supabase.client.from("user_blocks")
                .insert(BlockInsert(
                    blocker_id: blockerId.uuidString,
                    blockee_id: userId.uuidString
                ))
                .execute()
        } catch {
            AppLog.supabase.error("block(\(userId)) failed: \(error.localizedDescription)")
            // Roll back the optimistic apply on failure so the user
            // doesn't see a permanent local-only block that the
            // server didn't acknowledge.
            blockedUserIds.remove(userId)
        }
    }

    /// Unblock a user. Doesn't restore any prior friendship — that's a
    /// separate user action (re-send friend request from search). The
    /// row deletion makes the RLS exclude predicate stop hiding them
    /// from regular reads.
    func unblock(_ userId: UUID) async {
        guard let blockerId = supabase.currentSession?.user.id else { return }
        blockedUserIds.remove(userId)
        blockedProfiles.removeAll { $0.id == userId }
        do {
            try await supabase.client.from("user_blocks")
                .delete()
                .eq("blocker_id", value: blockerId.uuidString)
                .eq("blockee_id", value: userId.uuidString)
                .execute()
        } catch {
            AppLog.supabase.error("unblock(\(userId)) failed: \(error.localizedDescription)")
            blockedUserIds.insert(userId)
        }
    }

    /// Drop blocked users from every local roster array. Idempotent.
    /// Belt-and-suspenders for any cold-launch race where a roster
    /// hydrated before `loadBlocks()` returned.
    func applyBlockFilter() {
        guard !blockedUserIds.isEmpty else { return }
        friends.removeAll { blockedUserIds.contains($0.id) }
        pendingReceived.removeAll { blockedUserIds.contains($0.requesterId) }
        pendingSent.removeAll { blockedUserIds.contains($0.addresseeId) }
        searchResults.removeAll { blockedUserIds.contains($0.id) }
        contactSuggestions.removeAll { blockedUserIds.contains($0.id) }
    }

    // MARK: - Per-friend stats cache

    /// Bulk-fetch stats for the given user IDs and populate
    /// `profileStatsCache`. Per-friend rate-limited to once per 24 h
    /// so re-rendering the friends list (or new friends arriving via
    /// realtime) doesn't burn round-trips on cached values. Misses
    /// fall back to nothing — the view hides the stats line for
    /// friends with no cache entry rather than blocking on the fetch.
    func loadStatsBatch(for userIds: [UUID]) async {
        let now = Date.now
        let staleAfter: TimeInterval = 24 * 60 * 60
        let toFetch = userIds.filter { id in
            guard let last = lastStatsLoadAt[id] else { return true }
            return now.timeIntervalSince(last) > staleAfter
        }
        guard !toFetch.isEmpty else { return }
        await withTaskGroup(of: (UUID, ProfileStats?).self) { group in
            for id in toFetch {
                group.addTask { [weak self] in
                    let stats = await self?.supabase.fetchProfileStats(for: id)
                    return (id, stats)
                }
            }
            for await (id, stats) in group {
                if let stats {
                    profileStatsCache[id] = stats
                }
                lastStatsLoadAt[id] = now
            }
        }
    }
}
