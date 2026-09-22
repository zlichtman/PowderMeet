//
//  SupabaseManager+ImportedRuns.swift
//  PowderMeet
//
//  Extension of SupabaseManager — imported_runs CRUD + backup restore + stats/edge recompute triggers.
//  Split out of SupabaseManager.swift (behavior-preserving code motion). Methods
//  inherit @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension SupabaseManager {
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
    /// resort using the now-loaded graph. Targets null/empty and legacy
    /// synthetic labels such as "Run"; concrete trail names remain intact.
    /// Idempotent — only rows with a resolvable edge can be repaired here.
    func remapUnnamedRuns(resortId: String, graph: MountainGraph) async {
        guard let userId = currentSession?.user.id else { return }
        struct UnnamedRow: Decodable {
            let id: UUID
            let edge_id: String?
            let trail_name: String?
        }
        let unnamed: [UnnamedRow]
        do {
            unnamed = try await client.from("imported_runs")
                .select("id,edge_id,trail_name")
                .eq("profile_id", value: userId.uuidString)
                .eq("resort_id", value: resortId)
                .execute()
                .value
        } catch {
            AppLog.supabase.error("remapUnnamedRuns fetch failed: \(error.localizedDescription)")
            return
        }
        guard !unnamed.isEmpty else { return }

        let naming = MountainNaming(graph)
        struct UpdatePayload: Encodable { let trail_name: String }

        var updates = 0
        for row in unnamed {
            guard !ImportedRunNameQuality.isConcrete(row.trail_name),
                  let edgeId = row.edge_id,
                  let edge = graph.edge(byID: edgeId) else { continue }
            guard let label = ImportedRunNameQuality.evidenceBackedTrailName(
                for: edge,
                naming: naming
            ) else { continue }
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

        let rows: [ImportedRunWriteRow] = runs.map { run in
            ImportedRunWriteRow(
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
                raw_source_identity: run.rawSourceIdentity,
                dataset_version: run.datasetVersion,
                matched_segment_ids: run.matchedSegmentIds ?? [],
                edge_observations: run.edgePaceObservations ?? [],
                match_confidence: run.matchConfidence ?? 0,
                match_method: run.matchMethod ?? "legacy_unmatched",
                equipment_id_at_activity: run.equipmentIdAtActivity,
                trail_name: run.trailName,
                conditions_fp: ConditionsFingerprint.defaultBucket
            )
        }

        let inserted = try await upsertImportedRunRows(rows)
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
        return inserted.count
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
    ///   3. **Preserves each archived `dedup_hash`** so distinct source rows
    ///      stay distinct and re-importing the same backup remains
    ///      idempotent. Dataset/match/equipment/raw-source provenance also
    ///      round-trips unchanged.
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
        let rows: [ImportedRunWriteRow] = runs.compactMap { run in
            guard seenHashes.insert(run.dedupHash).inserted else { return nil }
            return ImportedRunWriteRow(
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
                raw_source_identity: run.rawSourceIdentity,
                dataset_version: run.datasetVersion,
                matched_segment_ids: run.matchedSegmentIds ?? [],
                edge_observations: run.edgePaceObservations ?? [],
                match_confidence: run.matchConfidence ?? 0,
                match_method: run.matchMethod ?? "legacy_unmatched",
                equipment_id_at_activity: run.equipmentIdAtActivity,
                trail_name: run.trailName,
                conditions_fp: ConditionsFingerprint.defaultBucket
            )
        }

        var inserted: Set<String> = []
        if !rows.isEmpty {
            // upsert with ignoreDuplicates so a partial-state DB (e.g.
            // a row that survived the DELETE because of replication
            // lag) doesn't fail the whole batch.
            inserted = try await upsertImportedRunRows(rows)
        }

        try await client
            .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(profileId)])
            .execute()
        await loadProfileStats()
        await recomputeProfileEdgeSpeeds()
        await loadEdgeSpeedHistory()
        return inserted.count
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
}
