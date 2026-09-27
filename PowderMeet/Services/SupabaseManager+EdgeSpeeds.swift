//
//  SupabaseManager+EdgeSpeeds.swift
//  PowderMeet
//
//  Extension of SupabaseManager — per-edge skill-memory (profile_edge_speeds) load + recompute.
//  Split out of SupabaseManager.swift (behavior-preserving code motion). Methods
//  inherit @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension SupabaseManager {
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
            // Group by edge_id → stable dataset/equipment/conditions key.
            // Multiple equipment cohorts must coexist: collapsing on
            // conditions_fp would make the last database row win according to
            // response order and silently reuse the wrong ski's pace.
            var dict: [String: [String: PerEdgeSpeed]] = [:]
            for row in rows {
                dict[row.edgeId, default: [:]][row.historyKey] = row
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
                dict[row.edgeId, default: [:]][row.historyKey] = row
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
}
