//
//  ActivityImporter+GraphSupport.swift
//  PowderMeet
//
//  Extension of ActivityImporter — graph loading, per-file profile merge, persistence.
//  Split out of ActivityImporter.swift. `nonisolated extension` preserves the
//  struct's off-main default; methods needing the main actor keep @MainActor.
//

import Foundation
import CryptoKit
import Supabase

nonisolated extension ActivityImporter {
    // MARK: - Graph Loading

    func loadDataset(for entry: ResortEntry) async throws -> MountainDataset {
        // Fast immutable cache lookup first.
        if let canonical = await MountainRepository.shared.loadCanonical(resortID: entry.id) {
            return canonical
        }
        if let cached = await MountainRepository.shared.loadLegacy(resortID: entry.id),
           cached.dataset.version.graphVersion == MountainRepository.expectedLegacyVersion || resortManager == nil {
            let enriched = await GraphEnricher.enrich(cached.graph, resortId: entry.id)
            return cached.dataset.applyingLegacyEnrichment(enriched)
        }

        // Cold imports must use the map's loader instead of giving up. The
        // loader fetches the published canonical graph or builds from the same
        // frozen server snapshot and caches the result without navigating the
        // visible map. This makes reconstruction independent of screen order.
        if let resortManager {
            return try await resortManager.datasetForActivityImport(entry)
        }

        // Pure tests may omit a manager. Production imports always inject it.
        throw ResortLoadError.snapshotUnavailable
    }

    // MARK: - Per-file profile merge

    /// Only measured forward pace on one confidently matched edge calibrates
    /// a difficulty bucket. Preserve measurements: comparing a partial descent
    /// with a modeled full-edge time is not a valid speed correction.
    @MainActor
    func mergeSpeedsForFile(matchedRuns: [MatchedRun], graph: MountainGraph?) async {
        let medians = ActivityCalibration.medianSpeeds(from: matchedRuns)
        guard !medians.isEmpty else { return }
        let eligibleCount = matchedRuns.filter(\.isProfileCalibrationEligible).count
        await mergeSpeedsIntoProfile(
            medians,
            matchedRunCount: eligibleCount
        )
    }

    @MainActor
    func mergeConditionsForFile(matchedRuns: [MatchedRun]) async {
        let inference = ActivityCalibration.inferConditionPreferences(
            from: matchedRuns
        )
        await mergeConditionsIntoProfile(inference)
    }

    // MARK: - Condition Inference

    func inferConditionPreferences(from runs: [MatchedRun]) -> ConditionInference {
        ActivityCalibration.inferConditionPreferences(from: runs)
    }

    // MARK: - Median helper

    static func median(_ values: [Double]) -> Double {
        ActivityCalibration.median(values)
    }

    // MARK: - Persistence

    @MainActor
    func persistRuns(
        _ runs: [MatchedRun],
        resortId: String,
        graph: MountainGraph?
    ) async throws -> Set<String> {
        try await persistRuns([ProcessedResortGroup(
            resortId: resortId,
            matchedRuns: runs,
            graph: graph
        )])
    }

    /// Persists every resort represented by one source container in a single
    /// PostgREST statement. This keeps a multi-mountain import all-or-nothing
    /// at the database statement boundary and returns the exact identities
    /// inserted across every group.
    @MainActor
    func persistRuns(_ groups: [ProcessedResortGroup]) async throws -> Set<String> {
        guard groups.contains(where: { !$0.matchedRuns.isEmpty }) else { return [] }
        guard let userId = supabase.currentSession?.user.id else {
            throw ImportError.notAuthenticated
        }
        let profileId = userId.uuidString

        let rows: [ImportedRunWriteRow] = groups.flatMap { group in
            var attrsByEdge: [String: (drop: Double, length: Double, maxGradeDeg: Double)] = [:]
            var nameByEdge: [String: String] = [:]
            if let graph = group.graph {
                // Build one naming index per resort so every run resolves
                // through the same picker-aligned canonical label rules.
                let naming = MountainNaming(graph)
                for edge in graph.edges {
                    attrsByEdge[edge.id] = (
                        edge.attributes.verticalDrop,
                        edge.attributes.lengthMeters,
                        edge.attributes.maxGradient
                    )
                    nameByEdge[edge.id] = ImportedRunNameQuality
                        .evidenceBackedTrailName(for: edge, naming: naming)
                }
            }
            return group.matchedRuns.map { run in
                let a = run.edgeId.flatMap { attrsByEdge[$0] } ?? (0, 0, 0)
                let hash = ImportedRunIdentity.dedupHash(
                    for: run,
                    resortID: group.resortId
                )
                // Prefer source-measured vertical/distance — graph nominals
                // systematically over/undershoot for partial-edge runs.
                let verticalM = run.measuredVerticalM ?? a.drop
                let distanceM = run.measuredDistanceM ?? a.length
                let primaryName = run.edgeId.flatMap { nameByEdge[$0] } ?? run.trailName
                // Store only an evidence-backed graph/provider label. The UI
                // can render "Run" for nil, but persisting that fallback made
                // it indistinguishable from a resolved name and permanently
                // excluded it from later graph-backed repair.
                let resolvedName = ImportedRunNameQuality.concreteName(primaryName)
                return ImportedRunWriteRow(
                    profile_id: profileId,
                    resort_id: group.resortId,
                    edge_id: run.edgeId,
                    difficulty: run.difficulty?.rawValue,
                    speed_ms: run.speed,
                    peak_speed_ms: run.peakSpeed,
                    duration_s: run.duration,
                    vertical_m: verticalM,
                    distance_m: distanceM,
                    max_grade_deg: a.maxGradeDeg,
                    run_at: run.timestamp,
                    dedup_hash: hash,
                    source: run.source.rawValue,
                    source_file_hash: run.sourceFileHash,
                    raw_source_identity: run.rawSourceIdentity,
                    dataset_version: run.datasetVersion,
                    matched_segment_ids: run.matchedSegmentIDs,
                    edge_observations: run.edgePaceObservations,
                    match_confidence: run.matchConfidence,
                    match_method: run.matchMethod,
                    equipment_id_at_activity: run.equipmentIDAtActivity,
                    trail_name: resolvedName,
                    conditions_fp: ConditionsFingerprint.defaultBucket
                )
            }
        }

        // The schema has always enforced UNIQUE(profile_id, dedup_hash).
        // Ignore exact re-imports, but ask PostgREST to return the identities
        // it actually inserted so the UI can distinguish imported vs duplicate
        // truthfully. A plain INSERT here makes one duplicate reject the whole
        // file.
        return try await supabase.upsertImportedRunRows(rows)
    }

    /// Returns `true` when both RPCs succeeded (or there was no session
    /// to talk to in the first place — caller treats no-session as "no
    /// failure to surface" since auth is already broken upstream).
    @MainActor
    func recomputeProfileStats() async -> Bool {
        guard let userId = supabase.currentSession?.user.id else { return true }
        async let statsOK = recomputeProfileStatsRow(userId: userId)
        async let edgeOK = supabase.recomputeProfileEdgeSpeeds()
        let (stats, edge) = await (statsOK, edgeOK)
        return stats && edge
    }

    @MainActor
    func recomputeProfileStatsRow(userId: UUID) async -> Bool {
        do {
            try await supabase.client
                .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(userId.uuidString)])
                .execute()
            await supabase.loadProfileStats()
            return true
        } catch {
            AppLog.importer.error("recompute_profile_stats failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Telemetry

    func logPerFileTelemetry(_ pf: ProcessedFile) {
        guard let timing = pf.timing else { return }
        let status: String = {
            switch pf.outcome.status {
            case .imported(let n): return "imported:\(n)"
            case .duplicate: return "duplicate"
            case .empty: return "empty"
            case .failed: return "failed"
            }
        }()
        let quality = pf.matchQuality ?? .empty
        AppLog.importer.info(
            "file=\(pf.outcome.url.lastPathComponent) status=\(status) " +
            "ms(total=\(timing.totalMs),read=\(timing.readMs ?? -1),detect=\(timing.detectMs ?? -1),parse=\(timing.parseMs ?? -1),process=\(timing.processMs ?? -1)) " +
            "match(strict=\(quality.strictCount),relaxed=\(quality.relaxedCount),nearest=\(quality.nearestCount),unmatched=\(quality.unmatchedCount))"
        )
    }

    func logBatchTelemetry(processed: [ProcessedFile], recomputeSucceeded: Bool, elapsedMs: Int) {
        guard !processed.isEmpty else { return }
        let importedCount = processed.reduce(0) { acc, pf in
            if case .imported = pf.outcome.status { return acc + 1 }
            return acc
        }
        let duplicateCount = processed.reduce(0) { acc, pf in
            if case .duplicate = pf.outcome.status { return acc + 1 }
            return acc
        }
        let failedCount = processed.reduce(0) { acc, pf in
            switch pf.outcome.status {
            case .failed, .empty: return acc + 1
            default: return acc
            }
        }
        let totals = processed.compactMap(\.timing).map(\.totalMs)
        let avgMs = totals.isEmpty ? 0 : totals.reduce(0, +) / totals.count
        let maxMs = totals.max() ?? 0
        let strict = processed.compactMap(\.matchQuality).reduce(0) { $0 + $1.strictCount }
        let relaxed = processed.compactMap(\.matchQuality).reduce(0) { $0 + $1.relaxedCount }
        let nearest = processed.compactMap(\.matchQuality).reduce(0) { $0 + $1.nearestCount }
        let unmatched = processed.compactMap(\.matchQuality).reduce(0) { $0 + $1.unmatchedCount }

        AppLog.importer.info(
            "batch files=\(processed.count) imported=\(importedCount) duplicate=\(duplicateCount) failed=\(failedCount) " +
            "ms(total=\(elapsedMs),avg_file=\(avgMs),max_file=\(maxMs)) recompute_ok=\(recomputeSucceeded) " +
            "match(strict=\(strict),relaxed=\(relaxed),nearest=\(nearest),unmatched=\(unmatched))"
        )
    }

    func elapsedMs(since startNanos: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
    }

    // MARK: - Profile Speed Merge

    @MainActor
    func mergeSpeedsIntoProfile(_ imported: [RunDifficulty: Double], matchedRunCount: Int) async {
        guard !imported.isEmpty else { return }
        let newWeight = max(0.5, 1.0 - 1.0 / Double(matchedRunCount + 1))
        func weighted(existing: Double?, new: Double) -> Double {
            guard let existing else { return new }
            return existing * (1.0 - newWeight) + new * newWeight
        }
        var updates: [String: AnyJSON] = [:]
        let p = supabase.currentUserProfile
        if let v = imported[.green]      { updates["speed_green"]        = .double(weighted(existing: p?.speedGreen, new: v)) }
        if let v = imported[.blue]       { updates["speed_blue"]         = .double(weighted(existing: p?.speedBlue, new: v)) }
        if let v = imported[.black]      { updates["speed_black"]        = .double(weighted(existing: p?.speedBlack, new: v)) }
        if let v = imported[.doubleBlack]{ updates["speed_double_black"] = .double(weighted(existing: p?.speedDoubleBlack, new: v)) }
        if let v = imported[.terrainPark]{ updates["speed_terrain_park"] = .double(weighted(existing: p?.speedTerrainPark, new: v)) }
        guard !updates.isEmpty else { return }
        do {
            try await supabase.updateProfile(updates)
        } catch {
            AppLog.importer.error("speed-merge updateProfile failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile Condition Merge

    @MainActor
    func mergeConditionsIntoProfile(_ inf: ConditionInference) async {
        guard inf.mogulRatio != nil || inf.ungroomedRatio != nil
                || inf.gladedRatio != nil || inf.narrowRatio != nil
                || inf.exposureRatio != nil else { return }
        let p = supabase.currentUserProfile
        var updates: [String: AnyJSON] = [:]
        let bw = 0.6
        if let r = inf.mogulRatio {
            let e = p?.conditionMoguls ?? 0.5
            let et = p?.mogulTolerance ?? e
            // Either compatibility field may carry an explicit AVOID from an
            // older/newer client. Treat the effective value as user-owned and
            // leave both fields untouched when it is zero.
            if let merged = ActivityCalibration.mergedTerrainPreference(
                existing: min(e, et),
                inferred: r,
                observationWeight: bw
            ) {
                updates["condition_moguls"] = .double(merged)
                updates["mogul_tolerance"] = .double(merged)
            }
        }
        if let r = inf.ungroomedRatio {
            let e = p?.conditionUngroomed ?? 0.6
            if let merged = ActivityCalibration.mergedTerrainPreference(
                existing: e,
                inferred: r,
                observationWeight: bw
            ) {
                updates["condition_ungroomed"] = .double(merged)
            }
        }
        if let r = inf.gladedRatio {
            let e = p?.conditionGladed ?? 0.4
            if let merged = ActivityCalibration.mergedTerrainPreference(
                existing: e,
                inferred: r,
                observationWeight: bw
            ) {
                updates["condition_gladed"] = .double(merged)
            }
        }
        if let r = inf.narrowRatio {
            let e = p?.narrowTrailTolerance ?? 0.5
            updates["narrow_trail_tolerance"] = .double(e * (1 - bw) + r * bw)
        }
        if let r = inf.exposureRatio {
            let e = p?.exposureTolerance ?? 0.5
            updates["exposure_tolerance"] = .double(e * (1 - bw) + r * bw)
        }
        guard !updates.isEmpty else { return }
        do {
            try await supabase.updateProfile(updates)
        } catch {
            AppLog.importer.error("conditions-merge updateProfile failed: \(error.localizedDescription)")
        }
    }
}
