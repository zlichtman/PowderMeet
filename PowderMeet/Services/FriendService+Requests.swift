//
//  FriendService+Requests.swift
//  PowderMeet
//
//  Extension of FriendService — search, send, accept/decline, remove.
//  Split out of FriendService.swift (behavior-preserving). Methods inherit
//  @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension FriendService {
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
        guard let userID = supabase.currentSession?.user.id,
              let acceptedFriendship = pendingReceived.first(where: { $0.id == friendshipId }),
              acceptedFriendship.addresseeId == userID,
              acceptedFriendship.status == .pending else {
            throw SocialRequestWriteError.unavailable
        }
        pendingReceived.removeAll(where: { $0.id == friendshipId })

        // ── DB update ──
        // Rollback the optimistic removal if the update fails — otherwise a
        // transient network error leaves the card gone while the row stays
        // `pending` on the server, and the user has no way to retry until a
        // realtime refresh arrives. Matches the pattern used in
        // `MeetRequestService.acceptRequest`.
        do {
            try await SocialRequestWriter(client: supabase.client).acceptFriendship(
                id: friendshipId, receiverID: userID)
        } catch {
            if supabase.sessionGeneration == startGen,
               !pendingReceived.contains(where: { $0.id == friendshipId }) {
                pendingReceived.append(acceptedFriendship)
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
        let requesterId = acceptedFriendship.requesterId
        if !friends.contains(where: { $0.id == requesterId }) {
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
        let removed = pendingReceived.filter { $0.id == friendshipId }
        pendingReceived.removeAll(where: { $0.id == friendshipId })
        do {
            try await supabase.client.from("friendships")
                .delete()
                .eq("id", value: friendshipId.uuidString)
                .eq("status", value: FriendshipStatus.pending.rawValue)
                .execute()
        } catch {
            if supabase.sessionGeneration == startGen {
                pendingReceived.append(contentsOf: removed.filter { row in
                    !pendingReceived.contains(where: { $0.id == row.id })
                })
            }
            throw error
        }
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
        let removed = pendingSent.filter { $0.addresseeId == addresseeId && $0.requesterId == userId }
        pendingSent.removeAll { $0.addresseeId == addresseeId && $0.requesterId == userId }
        do {
            try await supabase.client.from("friendships")
                .delete()
                .eq("requester_id", value: userId.uuidString)
                .eq("addressee_id", value: addresseeId.uuidString)
                .eq("status", value: FriendshipStatus.pending.rawValue)
                .execute()
        } catch {
            if supabase.sessionGeneration == startGen {
                pendingSent.append(contentsOf: removed.filter { row in
                    !pendingSent.contains(where: { $0.id == row.id })
                })
            }
            throw error
        }
        guard supabase.sessionGeneration == startGen else { return }
        _ = await loadSocialSnapshot()
    }

    // MARK: - Remove Friend

    func removeFriend(_ friendId: UUID) async throws {
        guard let userId = supabase.currentSession?.user.id else { return }
        let startGen = supabase.sessionGeneration
        // Optimistic: drop from in-memory friends list so the row disappears
        // immediately. Realtime DELETE event on the other device handles the
        // far side (see startRealtimeSubscription DeleteAction handlers).
        let removed = friends.filter { $0.id == friendId }
        friends.removeAll { $0.id == friendId }
        do {
            try await supabase.client.from("friendships")
                .delete()
                .or("and(requester_id.eq.\(userId.uuidString),addressee_id.eq.\(friendId.uuidString)),and(requester_id.eq.\(friendId.uuidString),addressee_id.eq.\(userId.uuidString))")
                .execute()
        } catch {
            if supabase.sessionGeneration == startGen {
                friends.append(contentsOf: removed.filter { row in
                    !friends.contains(where: { $0.id == row.id })
                })
            }
            throw error
        }
        guard supabase.sessionGeneration == startGen else { return }
        await loadFriends()
    }
}
