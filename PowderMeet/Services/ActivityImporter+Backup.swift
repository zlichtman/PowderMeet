//
//  ActivityImporter+Backup.swift
//  PowderMeet
//
//  Extension of ActivityImporter — PowderMeet backup (.powdermeet) restore path.
//  Split out of ActivityImporter.swift. `nonisolated extension` preserves the
//  struct's off-main default; methods needing the main actor keep @MainActor.
//

import Foundation
import CryptoKit
import Supabase

nonisolated extension ActivityImporter {
    // MARK: - PowderMeet Backup Path

    /// Decodes a PowderMeet backup envelope, copies every profile field
    /// into the importing user's profile, restores the embedded
    /// `imported_runs` rows (idempotent via dedup_hash), and returns a
    /// FileOutcome reporting the run count restored. Profile-stats +
    /// per-edge-speeds recompute happens inside `restoreImportedRuns`.
    @MainActor
    func processBackup(url: URL, data: Data) async -> FileOutcome {
        AppLog.importer.debug("processBackup: \(url.lastPathComponent), \(data.count) bytes")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Four accepted shapes:
        //   v3 wrapper: profile + stats + runs + avatar bytes + version
        //   v2 wrapper: profile + stats + runs + version
        //   v1 wrapper: profile + stats (no runs)
        //   bare UserProfile JSON (oldest)
        let importedProfile: UserProfile
        let importedRuns: [ImportedRunBackup]
        let avatarImageBase64: String?
        // Decode with explicit error capture so a schema-shape problem
        // surfaces in logs instead of silently falling through to
        // .unsupportedFormat. The user reported "import does nothing"
        // and we couldn't tell which leg of the if-let was failing.
        let wrapper: PowderMeetExport?
        do {
            wrapper = try decoder.decode(PowderMeetExport.self, from: data)
        } catch {
            AppLog.importer.error("PowderMeetExport decode failed: \(error)")
            wrapper = nil
        }
        if let wrapper {
            importedProfile = wrapper.profile
            importedRuns = wrapper.runs ?? []
            avatarImageBase64 = wrapper.avatarImageBase64
            AppLog.importer.debug("processBackup decoded v\(wrapper.exportSchemaVersion): \(importedRuns.count) runs, avatar=\(avatarImageBase64?.count ?? 0) chars")
        } else if let bare = try? decoder.decode(UserProfile.self, from: data) {
            importedProfile = bare
            importedRuns = []
            avatarImageBase64 = nil
            AppLog.importer.debug("processBackup decoded bare UserProfile (legacy v0)")
        } else {
            AppLog.importer.debug("processBackup: file is neither PowderMeetExport nor UserProfile")
            return FileOutcome(url: url, status: .failed(error: ImportError.unsupportedFormat))
        }

        guard var current = supabase.currentUserProfile else {
            return FileOutcome(url: url, status: .failed(error: ImportError.fileReadFailed(underlying: NSError(domain: "PowderMeet", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sign in before importing a backup."]))))
        }

        // Cross-user transfer detection. When the backup was created by
        // a different user, we KEEP the importing user's identity
        // (display_name, avatar) — the unique-display-name constraint
        // would reject a copy from user A onto user B's profile, which
        // is the exact failure the user reported as "powdermeet files
        // won't import if tied to another user." Same-user re-imports
        // still copy display_name as before.
        let isCrossUserImport = importedProfile.id != current.id

        // Copy every PREFERENCE field — bucketed speeds AND continuous
        // tolerances. These are not identity-bound, so they always copy.
        if !isCrossUserImport {
            current.displayName = importedProfile.displayName
        }
        current.skillLevel = importedProfile.skillLevel
        current.speedGreen = importedProfile.speedGreen
        current.speedBlue = importedProfile.speedBlue
        current.speedBlack = importedProfile.speedBlack
        current.speedDoubleBlack = importedProfile.speedDoubleBlack
        current.speedTerrainPark = importedProfile.speedTerrainPark
        current.conditionMoguls = importedProfile.conditionMoguls
        current.conditionUngroomed = importedProfile.conditionUngroomed
        current.conditionIcy = importedProfile.conditionIcy
        current.conditionGladed = importedProfile.conditionGladed
        current.maxComfortableGradientDegrees = importedProfile.maxComfortableGradientDegrees
        current.mogulTolerance = importedProfile.mogulTolerance
        current.narrowTrailTolerance = importedProfile.narrowTrailTolerance
        current.exposureTolerance = importedProfile.exposureTolerance
        current.crustConditionTolerance = importedProfile.crustConditionTolerance

        do {
            let saved = try await supabase.sendFullProfileUpdate(current)
            supabase.currentUserProfile = saved
        } catch {
            return FileOutcome(url: url, status: .failed(error: error))
        }

        // Restore avatar bytes (v3+) — re-uploads the embedded image
        // to the avatars bucket and points the profile at the new URL.
        // Skipped on cross-user imports: the importing user keeps their
        // own profile photo. Best-effort otherwise: a failure here
        // doesn't fail the whole import, since the bucketed speeds +
        // runs were already restored.
        if !isCrossUserImport,
           let base64 = avatarImageBase64,
           let imageData = Data(base64Encoded: base64) {
            do {
                let newURL = try await supabase.uploadAvatar(imageData: imageData)
                try await supabase.updateProfile([
                    "avatar_url": .string(newURL)
                ])
            } catch {
                AppLog.importer.error("avatar restore failed: \(error.localizedDescription)")
            }
        }

        // Replace-mode restore. .powdermeet files are backups, not
        // additive imports — the user expects "put me back where I
        // was": existing imported_runs wiped, backup runs inserted
        // tagged with the POWDERMEET source so the log surfaces the
        // red pill. Idempotent against itself (re-running the same
        // backup dedupes), never collides with non-backup rows.
        var restored = 0
        if !importedRuns.isEmpty {
            do {
                restored = try await supabase.replaceImportedRunsFromBackup(importedRuns)
            } catch {
                return FileOutcome(url: url, status: .failed(error: error))
            }
        }
        await supabase.loadProfileStats()
        await supabase.loadEdgeSpeedHistory()

        // Report restored-run count under the .imported branch so the
        // batch banner and per-file outcome read the same as an
        // activity-file import did.
        return FileOutcome(url: url, status: .imported(runs: restored))
    }
}
