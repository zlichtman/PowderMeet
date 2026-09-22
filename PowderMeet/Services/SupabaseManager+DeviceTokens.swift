//
//  SupabaseManager+DeviceTokens.swift
//  PowderMeet
//
//  Extension of SupabaseManager — APNs device-token registration.
//  Split out of SupabaseManager.swift (behavior-preserving code motion). Methods
//  inherit @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension SupabaseManager {
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
}
