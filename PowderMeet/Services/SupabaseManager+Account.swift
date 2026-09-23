//
//  SupabaseManager+Account.swift
//  PowderMeet
//
//  Extension of SupabaseManager — account deletion + avatar upload.
//  Split out of SupabaseManager.swift (behavior-preserving code motion). Methods
//  inherit @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension SupabaseManager {
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
    /// Thin delegate to `AvatarUploader` (the storage-REST plumbing lives
    /// there now); the public API is unchanged so onboarding + profile call
    /// sites don't move.
    func uploadAvatar(imageData: Data, expectedUserID: UUID? = nil) async throws -> String {
        try await AvatarUploader.upload(
            imageData: imageData,
            client: client,
            projectURL: Self.projectURL,
            anonKey: Self.anonKey,
            expectedUserID: expectedUserID
        )
    }
}
