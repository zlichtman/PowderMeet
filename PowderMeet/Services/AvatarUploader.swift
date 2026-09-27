//
//  AvatarUploader.swift
//  PowderMeet
//
//  Avatar image upload to Supabase Storage, extracted from SupabaseManager so
//  the manager isn't the home for storage-REST plumbing. `SupabaseManager
//  .uploadAvatar` delegates here, so callers (onboarding, profile) are unchanged.
//

import Foundation
import Supabase

@MainActor
enum AvatarUploader {

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
    static func upload(
        imageData: Data,
        client: SupabaseClient,
        projectURL: String,
        anonKey: String,
        expectedUserID: UUID? = nil
    ) async throws -> String {
        // Force-fetch the SDK's current session — this refreshes if
        // expired and ensures we have a usable access token.
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            throw NSError(domain: "AvatarUploader", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated. Try signing out and back in."])
        }
        let userId = session.user.id
        if let expectedUserID, userId != expectedUserID {
            throw NSError(domain: "AvatarUploader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Account changed while preparing your photo. Please try again."])
        }
        let userIdLower = userId.uuidString.lowercased()
        let path = "\(userIdLower)/avatar.jpg"

        AppLog.supabase.debug("upload path=\(path) bytes=\(imageData.count)")

        // POST /storage/v1/object/avatars/<userId>/avatar.jpg
        // x-upsert: true overwrites the previous avatar without a 409.
        guard let url = URL(string: "\(projectURL)/storage/v1/object/avatars/\(path)") else {
            throw NSError(domain: "AvatarUploader", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Bad storage URL"])
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: imageData)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "AvatarUploader", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's error body so RLS / quota / 4xx
            // failures read clearly.
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            AppLog.supabase.error("upload failed HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "AvatarUploader", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Storage upload \(http.statusCode): \(body.prefix(200))"])
        }

        // The object path is stable for upsert, but the profile URL must
        // change after every successful replacement. Otherwise URLCache and
        // AvatarCache keep serving the previous photo across app launches
        // and devices. CachedAvatarView retains the old image while the new
        // URL loads, so this does not flash a placeholder.
        return "\(projectURL)/storage/v1/object/public/avatars/\(path)?v=\(UUID().uuidString.lowercased())"
    }
}
