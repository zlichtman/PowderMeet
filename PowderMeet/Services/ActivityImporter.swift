//
//  ActivityImporter.swift
//  PowderMeet
//
//  Production-grade unified import pipeline for activity files
//  (.slopes, .gpx, .tcx, .fit). Handles single- and multi-file
//  uploads, graph-match enrichment without gating persistence on
//  match success, and one-RPC profile-stats refresh per batch.
//
//  Pipeline per file (run on detached tasks so multi-file uploads
//  parallelise):
//
//   1. Read bytes once → SHA256 → fast-skip if any imported_runs row
//      already has this hash for this profile.
//   2. Detect format (extension first, magic bytes second).
//   3. Parse → unified `ParsedActivity` envelope with native lap-level
//      stats when the format encoded them.
//   4. Identify resort: catalog bbox lookup; on miss, fall back to a
//      slug of the file's reported `resortName` ("big-sky-resort"); on
//      double-miss, "unknown-resort".
//   5. Try graph load — best-effort, never throws upward. A network or
//      build failure means we skip enrichment, never the import.
//   6. Build MatchedRun per ParsedRunSegment. When a graph is present,
//      attach edge id / difficulty / trail name. Stats come from native
//      lap data when present, or computed (haversine) from points.
//   7. Persist all runs to imported_runs. Dedup hash:
//        "<source>|<minute_floor(start)>|<resort_id>|<edge_id ?? unmatched>"
//      — minute-floor absorbs ms drift across re-exports of the same
//      file; including <source> means the same activity logged in two
//      apps keeps both rows by design.
//   8. Per-file profile-merge (per-difficulty median, condition ratios)
//      runs only against runs with non-nil difficulty.
//   9. ONE recompute_profile_stats RPC at end of batch, not per-file.
//

import Foundation
import CryptoKit
import Supabase

// MARK: - Errors

enum ImportError: LocalizedError {
    case noTracks
    case unsupportedFormat
    /// Slopes-specific failure surfaced from `SlopesParser`.
    case slopesParseFailed(SlopesParserError)
    case parseEmpty                       // file parsed but yielded no segments
    case fileReadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noTracks:                 return "No GPS tracks found in the file."
        case .unsupportedFormat:        return "Unsupported file format. Use GPX, TCX, FIT, or Slopes files."
        case .slopesParseFailed(let i): return i.errorDescription
        case .parseEmpty:               return "Could not extract any runs from this file."
        case .fileReadFailed(let u):    return "Could not read file: \(u.localizedDescription)"
        }
    }
}

// MARK: - File-format detection

nonisolated enum ActivityFileFormat {
    case gpx, tcx, fit, slopes
    /// PowderMeet backup envelope (JSON with profile + stats + runs).
    /// Handled separately from activity formats — it doesn't go through
    /// per-file parse → match → persist; it goes straight to
    /// `restoreImportedRuns` + profile field copy.
    case powdermeetBackup

    var importSource: ImportSource {
        switch self {
        case .gpx:    return .gpx
        case .tcx:    return .tcx
        case .fit:    return .fit
        case .slopes: return .slopes
        // Backups don't contribute a single ImportSource — each
        // restored row keeps its original `source` field.
        case .powdermeetBackup: return .slopes // placeholder, never used
        }
    }

    static func detect(url: URL, data: Data) -> ActivityFileFormat? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "gpx": return .gpx
        case "tcx": return .tcx
        case "fit": return .fit
        case "slopes": return .slopes
        case "powdermeet": return .powdermeetBackup
        default: break
        }
        // Fall back to magic bytes / content sniffing.
        if data.count >= 14 {
            let sig = String(data: data[8..<12], encoding: .ascii)
            if sig == ".FIT" { return .fit }
        }
        if data.count > 16 {
            let header = String(data: data.prefix(15), encoding: .utf8)
            if header == "SQLite format 3" { return .slopes }
        }
        // ZIP magic — Slopes' modern export, but could also be a third-party
        // GPX-in-ZIP. We treat ZIP as .slopes here; SlopesParser falls back
        // gracefully to "no tracks" if it isn't actually a Slopes archive.
        if data.count >= 4, data[0] == 0x50, data[1] == 0x4B {
            return .slopes
        }
        // GPX / TCX live in the first 4KB by spec — small sniff is fine.
        if let head = String(data: data.prefix(4096), encoding: .utf8)?.lowercased() {
            if head.contains("<gpx") { return .gpx }
            if head.contains("<trainingcenterdatabase") { return .tcx }
        }
        // PowderMeet backup sniff — much wider window because v3
        // backups embed a base64 avatar that can run hundreds of KB.
        // New exports place the schema marker first (struct member
        // order, no .sortedKeys), so it lands in the first ~80 bytes.
        // Legacy sorted-keys v3 exports could push the marker past
        // megabytes of avatar payload. 2 MB cap covers any realistic
        // avatar without slurping the whole file.
        let sniffLimit = min(data.count, 2_097_152)
        if let body = String(data: data.prefix(sniffLimit), encoding: .utf8)?.lowercased(),
           body.contains("\"export_schema_version\"")
            || body.contains("\"exported_at\"")
            || body.contains("\"exportschemaversion\"")
            || body.contains("\"exportedat\"") {
            return .powdermeetBackup
        }
        return nil
    }
}

// MARK: - Batch result types

/// Result of a multi-file import. Each file produces a FileOutcome so
/// the UI can show ✅ / ⚠️ duplicate / ❌ error per row without the
/// caller having to interpret a single thrown error.
///
/// `recomputeSucceeded` reflects the post-import RPC pair (stats +
/// per-edge speeds). When it's `false` the import rows DID land in
/// `imported_runs`, but the solver's per-edge memory wasn't refreshed
/// — surface to the banner so the user knows to retry rather than
/// thinking the calibration silently took.
nonisolated struct BatchImportResult {
    let perFile: [FileOutcome]
    let recomputeSucceeded: Bool

    var totalRunsImported: Int {
        perFile.reduce(0) { acc, outcome in
            switch outcome.status {
            case .imported(let n): return acc + n
            case .duplicate, .failed, .empty: return acc
            }
        }
    }
}

nonisolated struct FileOutcome {
    let url: URL
    let status: Status

    enum Status {
        case imported(runs: Int)
        case duplicate                    // file SHA256 already in imported_runs
        case empty                        // parsed cleanly but no runs
        case failed(error: Error)
    }
}

/// Internal: per-file work product that also carries the data needed
/// for post-join profile merging. Audit Phase 2.3 — `mergeSpeedsForFile`
/// / `mergeConditionsForFile` ran inside the parallel `processFile`,
/// so two files reading `currentUserProfile` at the same await point
/// produced last-writer-wins on the bucketed-speed columns. By
/// collecting matched runs across the parallel join and merging once,
/// every file contributes deterministically.
nonisolated struct ProcessedFile: @unchecked Sendable {
    let outcome: FileOutcome
    /// Empty when the file failed / was empty / was a duplicate. Non-
    /// empty when persistence succeeded; aggregator unions these and
    /// runs the per-difficulty median merge once.
    let matchedRuns: [MatchedRun]
    /// nil only on failure / empty — otherwise the resort the file
    /// belonged to. Aggregator groups by this so multi-resort batches
    /// (e.g. someone importing both Vail and BC files together) merge
    /// each side correctly against its own graph.
    let resortId: String?
    /// nil when the resort had no graph available — speed validation
    /// is then skipped but median merge still runs.
    let graph: MountainGraph?

    /// Wrap a fail / duplicate / empty `FileOutcome` with no matched
    /// runs. Convenience for the early-return sites in processFile.
    init(_ outcome: FileOutcome) {
        self.outcome = outcome
        self.matchedRuns = []
        self.resortId = nil
        self.graph = nil
    }

    init(outcome: FileOutcome, matchedRuns: [MatchedRun], resortId: String?, graph: MountainGraph?) {
        self.outcome = outcome
        self.matchedRuns = matchedRuns
        self.resortId = resortId
        self.graph = graph
    }
}

// MARK: - Activity Importer

// `nonisolated` — file IO + parsing + graph match + DB upserts must
// run off the main actor so the user can navigate during a multi-file
// import. Project default isolation is MainActor; opt out. Methods
// that genuinely need MainActor (touching `supabase.currentUserProfile`
// or @Observable state) keep their explicit `@MainActor` annotations.
nonisolated struct ActivityImporter {
    let supabase: SupabaseManager

    // MARK: - Public entry points

    /// Universal batch entry — handles single or multi-file import. Files
    /// run in parallel via `withTaskGroup` so a 6-file upload finishes in
    /// roughly the time of the slowest file, not the sum of all of them.
    /// Calls `recompute_profile_stats` exactly once at the end.
    ///
    /// `onProgress` fires once per file as outcomes land, with the
    /// running `(processed, total)` tuple. Caller (the import session)
    /// drives a "UPLOADING · 3/10" counter off this so the user can
    /// see the queue draining instead of staring at an indeterminate
    /// spinner. The closure is `@Sendable` because it crosses actor
    /// boundaries — invoke it from inside the loop, callers should
    /// hop to the main actor themselves before mutating UI state.
    func importActivities(
        urls: [URL],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> BatchImportResult {
        var processed: [ProcessedFile] = []
        processed.reserveCapacity(urls.count)
        let total = urls.count

        // Fan out per-file work. Each task computes its own outcome and
        // persists its rows; profile-column merges defer to the post-
        // join aggregator (audit Phase 2.3) and a single recompute
        // happens after that.
        await withTaskGroup(of: ProcessedFile.self) { group in
            for url in urls {
                group.addTask { await self.processFile(url: url) }
            }
            for await pf in group {
                processed.append(pf)
                onProgress?(processed.count, total)
            }
        }

        await runPostJoinMerges(processed: processed)

        let outcomes = processed.map(\.outcome)
        // One stats refresh per batch. If anything actually imported, run
        // the RPC; otherwise skip — no point hitting the server.
        var recomputeSucceeded = true
        if outcomes.contains(where: { if case .imported = $0.status { return true }; return false }) {
            recomputeSucceeded = await recomputeProfileStats()
        }

        return BatchImportResult(perFile: outcomes, recomputeSucceeded: recomputeSucceeded)
    }

    /// Aggregate matched runs across files (grouped by resort) and run
    /// `mergeSpeedsForFile` / `mergeConditionsForFile` once per group.
    /// Audit Phase 2.3 — running these inside the parallel `processFile`
    /// produced last-writer-wins on the bucketed-speed columns when two
    /// tasks hit the read+write across an `await`. Now: serialised on
    /// the main actor, deterministic over outcomes.
    @MainActor
    private func runPostJoinMerges(processed: [ProcessedFile]) async {
        var byResort: [String: (runs: [MatchedRun], graph: MountainGraph?)] = [:]
        for pf in processed {
            guard let resortId = pf.resortId, !pf.matchedRuns.isEmpty else { continue }
            byResort[resortId, default: ([], nil)].runs.append(contentsOf: pf.matchedRuns)
            // Keep the first non-nil graph we see for this resort —
            // every parallel task loaded the same graph for the same
            // resort id (resort manager dedupes), so this is safe.
            if byResort[resortId]?.graph == nil, let g = pf.graph {
                byResort[resortId]?.graph = g
            }
        }
        for (_, group) in byResort {
            await mergeSpeedsForFile(matchedRuns: group.runs, graph: group.graph)
            await mergeConditionsForFile(matchedRuns: group.runs)
        }
    }

    /// Backward-compat single-file entry. Wraps importActivities and
    /// returns an ImportResult for the legacy callers (kept so
    /// ProfileTabContents continues working until the batch UI lands).
    func importActivityFile(url: URL) async throws -> ImportResult {
        let batch = await importActivities(urls: [url])
        guard let outcome = batch.perFile.first else {
            throw ImportError.noTracks
        }
        switch outcome.status {
        case .imported(let n):
            return ImportResult(
                resortId: nil,
                runs: [],
                averageSpeeds: [:],
                conditionInference: nil,
                runCountImported: n
            )
        case .duplicate:
            return ImportResult(resortId: nil, runs: [], averageSpeeds: [:], conditionInference: nil, runCountImported: 0)
        case .empty:
            throw ImportError.parseEmpty
        case .failed(let err):
            throw err
        }
    }

    /// Backward-compat alias for the GPX-only legacy entry.
    func importGPXFile(url: URL) async throws -> ImportResult {
        try await importActivityFile(url: url)
    }

    /// HealthKit / synthesized-source entry. Each `ParsedActivity` already
    /// carries its own `sourceFileHash` (derived from the workout UUID +
    /// sample fingerprint), so we go straight into the post-parse pipeline
    /// — no URL bytes to read, no format sniff. Same recompute-once-at-end
    /// contract as `importActivities(urls:)`.
    func importParsedActivities(_ parsedList: [ParsedActivity]) async -> BatchImportResult {
        var processed: [ProcessedFile] = []
        processed.reserveCapacity(parsedList.count)

        await withTaskGroup(of: ProcessedFile.self) { group in
            for parsed in parsedList {
                let label = Self.syntheticLabel(for: parsed)
                group.addTask { await self.processParsed(parsed, label: label) }
            }
            for await pf in group {
                processed.append(pf)
            }
        }

        await runPostJoinMerges(processed: processed)

        let outcomes = processed.map(\.outcome)
        var recomputeSucceeded = true
        if outcomes.contains(where: { if case .imported = $0.status { return true }; return false }) {
            recomputeSucceeded = await recomputeProfileStats()
        }

        return BatchImportResult(perFile: outcomes, recomputeSucceeded: recomputeSucceeded)
    }

    /// Synthesise a URL-shaped label for non-file sources. Used purely as
    /// a banner identifier — `lastPathComponent` is what the user sees if
    /// the workout fails to import.
    private static func syntheticLabel(for parsed: ParsedActivity) -> URL {
        let stamp = parsed.segments.first?.startTime
            .formatted(.iso8601.year().month().day())
            ?? parsed.sourceFileHash.prefix(8).description
        return URL(string: "\(parsed.source.rawValue)://workout/\(stamp)")
            ?? URL(fileURLWithPath: stamp)
    }

    // MARK: - Per-file pipeline

    private func processFile(url: URL) async -> ProcessedFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        AppLog.importer.debug("processFile: \(url.lastPathComponent) ext=\(url.pathExtension) scoped=\(accessed)")

        // 1. Read bytes.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.importer.error("read failed: \(error.localizedDescription)")
            return ProcessedFile(FileOutcome(url: url, status: .failed(error: ImportError.fileReadFailed(underlying: error))))
        }
        let hash = sha256(data)
        AppLog.importer.debug("read \(data.count) bytes, sha256=\(hash.prefix(12))…")

        // 2. Detect format. We do this BEFORE the whole-file dedup
        // check so .powdermeet backups can short-circuit through
        // processBackup — backups are explicitly meant to be re-
        // importable as a restore (e.g. user purges, then wants
        // their data back), and the source_file_hash check would
        // mark the file as a duplicate after the first import.
        guard let format = ActivityFileFormat.detect(url: url, data: data) else {
            AppLog.importer.error("format detection FAILED — extension=\(url.pathExtension), first 200 bytes: \(String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>")")
            return ProcessedFile(FileOutcome(url: url, status: .failed(error: ImportError.unsupportedFormat)))
        }
        AppLog.importer.debug("detected format: \(format)")

        // 2a. PowderMeet backup short-circuit. Replace-semantics are
        // handled inside processBackup; whole-file dedup intentionally
        // does NOT apply here.
        if format == .powdermeetBackup {
            return ProcessedFile(await processBackup(url: url, data: data))
        }

        // 3. Whole-file dedup for activity files only — re-uploading
        // the same Slopes / GPX / TCX / FIT / HK file doesn't even
        // pay the parse cost.
        if await isWholeFileAlreadyImported(hash: hash) {
            return ProcessedFile(FileOutcome(url: url, status: .duplicate))
        }

        // 4. Parse → unified ParsedActivity envelope.
        let parsed: ParsedActivity
        switch format {
        case .gpx:    parsed = GPXParser.parseUnified(data: data, sourceFileHash: hash)
        case .tcx:    parsed = TCXParser.parseUnified(data: data, sourceFileHash: hash)
        case .fit:    parsed = FITParser.parseUnified(data: data, sourceFileHash: hash)
        case .slopes:
            switch SlopesParser.parseUnified(url: url, sourceFileHash: hash) {
            case .success(let act): parsed = act
            case .failure(let err): return ProcessedFile(FileOutcome(url: url, status: .failed(error: ImportError.slopesParseFailed(err))))
            }
        case .powdermeetBackup:
            // Already handled above — defensive guard so the switch
            // stays exhaustive without falling through.
            return ProcessedFile(FileOutcome(url: url, status: .failed(error: ImportError.unsupportedFormat)))
        }

        return await processParsed(parsed, label: url)
    }

    /// Post-parse pipeline shared by file imports and HealthKit. Takes a
    /// fully-formed `ParsedActivity` and runs steps 4–8 (resort id → graph
    /// load → match → persist → per-file merge). The `label` URL is only
    /// used to populate `FileOutcome.url` for banner copy.
    private func processParsed(_ parsed: ParsedActivity, label url: URL) async -> ProcessedFile {
        guard !parsed.segments.isEmpty else {
            return ProcessedFile(FileOutcome(url: url, status: .empty))
        }

        // Whole-source dedup — HealthKit re-imports a workout with the
        // same UUID-derived hash, so check before we pay the matching cost.
        if await isWholeFileAlreadyImported(hash: parsed.sourceFileHash) {
            return ProcessedFile(FileOutcome(url: url, status: .duplicate))
        }

        // 4. Resort identification — bbox catalog lookup; if no first
        // GPS point or no bbox match, fall back to a slug of the
        // reported resort name; if even that's absent, "unknown-resort".
        let firstPoint = parsed.segments.flatMap(\.points).first
        let catalogEntry: ResortEntry? = firstPoint.flatMap(TrailMatcher.identifyResort(from:))
        let resortId = catalogEntry?.id ?? slugify(parsed.resortName)

        // 5. Try graph load (best effort). Never throws upward — the
        // import contract is "X runs in your file → X runs on your
        // profile" regardless of mountain data availability. Failures
        // here mean unnamed runs ("Imported Run" fallback) instead of
        // zero runs, so log them rather than swallowing silently.
        var graph: MountainGraph?
        if let entry = catalogEntry {
            do {
                graph = try await loadGraph(for: entry)
            } catch {
                AppLog.importer.error("loadGraph failed for \(entry.id): \(error.localizedDescription) — proceeding without trail names")
                graph = nil
            }
        }
        let matcher = graph.map(TrailMatcher.init(graph:))
        // Build naming once per file so relaxed-tier matches can resolve
        // canonical labels without reconstructing the cache per run.
        let naming = graph.map { MountainNaming($0) }

        // 6. Build MatchedRun per ParsedRunSegment. For GPX or HealthKit
        // sources with a single segment AND a graph, run elevation
        // segmentation now to recover per-run breakdown — HealthKit
        // returns a whole ski day as one workout, so without this split
        // every day collapsed into a single "run". Without a graph,
        // persist as one row.
        let segmentsForMatching: [ParsedRunSegment]
        if (parsed.source == .gpx || parsed.source == .healthKit),
           parsed.segments.count == 1,
           let matcher,
           parsed.segments[0].points.count >= 30 {
            segmentsForMatching = elevationSegment(parsed.segments[0], with: matcher)
        } else {
            segmentsForMatching = parsed.segments
        }

        var matchedRuns: [MatchedRun] = []
        matchedRuns.reserveCapacity(segmentsForMatching.count)

        for segment in segmentsForMatching {
            // Graph-match is enrichment only — never gates persistence.
            var edgeId: String?
            var difficulty: RunDifficulty?
            var trailName: String?
            var hasMoguls = false
            var isGroomed = false
            var isGladed = false
            var widthMeters: Double?
            var fallLineExposure: Double?

            if let matcher, segment.points.count >= 4 {
                let trailMatcherSegment = SegmentedRun(points: segment.points, isLift: false)
                if let (edge, _, _) = matcher.matchRun(trailMatcherSegment) {
                    // Tier 1 — strict (60m / 45°). Gates per-edge skill
                    // memory and the condition-flag merge. High-confidence
                    // input only.
                    edgeId = edge.id
                    difficulty = edge.attributes.difficulty
                    trailName = edge.attributes.trailName
                    hasMoguls = edge.attributes.hasMoguls
                    isGroomed = edge.attributes.isGroomed ?? false
                    isGladed = edge.attributes.isGladed
                    widthMeters = edge.attributes.estimatedTrailWidthMeters
                    fallLineExposure = edge.attributes.fallLineExposure
                } else if let nameEdge = matcher.bestEffortNameMatch(for: trailMatcherSegment) {
                    // Tier 2 — relaxed (120m / 70°). Recovers parallel-
                    // trail / sparse-GPS runs that strict dropped. Sets
                    // trail name only; does NOT feed edge_id / skill
                    // memory / conditions so a best-effort guess can't
                    // bias the algorithm.
                    trailName = naming?.edgeLabel(nameEdge, style: .canonical)
                        ?? nameEdge.attributes.trailName
                    // Inherit difficulty from the matched edge for display
                    // purposes (still doesn't go into the algo's
                    // condition merge — that's gated above on edgeId).
                    if difficulty == nil { difficulty = nameEdge.attributes.difficulty }
                } else if let nearest = matcher.nearestRunEdgeByCentroid(for: trailMatcherSegment) {
                    // Tier 3 — nearest-by-centroid (≤300m). Fires when
                    // tier 1 and tier 2 both rejected. Catches dense-
                    // tree / sparse-GPS / off-piste runs whose tracks
                    // wandered too far from any single trail. Capped at
                    // 300m so we don't pick a trail on the other side
                    // of a peak.
                    trailName = naming?.edgeLabel(nearest, style: .canonical)
                        ?? nearest.attributes.trailName
                    if difficulty == nil { difficulty = nearest.attributes.difficulty }
                }
            }

            // Stats: prefer native lap-level numbers from the parser;
            // compute from points only when missing.
            let speed = segment.avgSpeedMS ?? computedAvgSpeed(points: segment.points)
            let peak = max(segment.topSpeedMS ?? computedPeakSpeed(points: segment.points), speed)
            let duration = segment.durationSeconds > 0 ? segment.durationSeconds
                         : segment.endTime.timeIntervalSince(segment.startTime)

            matchedRuns.append(MatchedRun(
                edgeId: edgeId,
                difficulty: difficulty,
                speed: speed,
                peakSpeed: peak,
                duration: duration,
                timestamp: segment.startTime,
                trailName: trailName,
                hasMoguls: hasMoguls,
                isGroomed: isGroomed,
                isGladed: isGladed,
                widthMeters: widthMeters,
                fallLineExposure: fallLineExposure,
                measuredVerticalM: segment.verticalMeters,
                measuredDistanceM: segment.distanceMeters,
                source: parsed.source,
                sourceFileHash: parsed.sourceFileHash
            ))
        }

        // 7. Persist runs only. Profile-column merges defer to the
        // post-join aggregator (`runPostJoinMerges`) so two parallel
        // tasks can't last-writer-win on the bucketed-speed columns.
        await persistRuns(matchedRuns, resortId: resortId, graph: graph)

        return ProcessedFile(
            outcome: FileOutcome(url: url, status: .imported(runs: matchedRuns.count)),
            matchedRuns: matchedRuns,
            resortId: resortId,
            graph: graph
        )
    }

    // MARK: - PowderMeet Backup Path

    /// Decodes a PowderMeet backup envelope, copies every profile field
    /// into the importing user's profile, restores the embedded
    /// `imported_runs` rows (idempotent via dedup_hash), and returns a
    /// FileOutcome reporting the run count restored. Profile-stats +
    /// per-edge-speeds recompute happens inside `restoreImportedRuns`.
    @MainActor
    private func processBackup(url: URL, data: Data) async -> FileOutcome {
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

    // MARK: - Helpers

    private func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whole-file fast-skip lookup: returns true when any imported_runs
    /// row for this profile already carries this source_file_hash.
    private func isWholeFileAlreadyImported(hash: String) async -> Bool {
        guard let userId = await MainActor.run(body: { supabase.currentSession?.user.id }) else {
            return false
        }
        do {
            let resp: [HashRow] = try await supabase.client
                .from("imported_runs")
                .select("source_file_hash")
                .eq("profile_id", value: userId.uuidString)
                .eq("source_file_hash", value: hash)
                .limit(1)
                .execute()
                .value
            return !resp.isEmpty
        } catch {
            // Network or auth failure → treat as "not duplicate" so we
            // attempt the import. The unique-constraint on
            // (profile_id, dedup_hash) still protects against double-rows.
            return false
        }
    }

    private struct HashRow: Decodable {
        let source_file_hash: String?
    }

    /// Deterministic slug of a resort name for the "no catalog match"
    /// case. Lowercase, alphanumeric, dash-separated. Empty / nil →
    /// "unknown-resort". Same name on two devices → same slug, so runs
    /// from "Big Sky Resort" group correctly even before we add it to
    /// the catalog.
    private func slugify(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "unknown-resort" }
        let lowered = name.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "unknown-resort" : collapsed
    }

    /// Splits a single GPX segment via TrailMatcher's elevation/speed
    /// classifier into per-run subsegments. Drops lift segments. Used
    /// when an exporter shipped one big trkseg covering an entire ski
    /// day — common for Strava GPX and Garmin Explore.
    ///
    /// Stationary-segment guard: the classifier is binary (lift vs run),
    /// so a 30-minute lunch break with no movement gets classified as
    /// run (no elevation gain → not a lift). Same for long gondola
    /// loading lines and end-of-day pauses with the watch still
    /// recording. Without this guard those got persisted as multi-
    /// minute "runs" with ~0 distance and ~0 m/s avg speed.
    ///
    /// Drop a non-lift segment when EITHER:
    ///   - duration > 25 min (no real ski run lasts that long even on
    ///     top-to-bottom monsters), OR
    ///   - haversine avg speed < 0.5 m/s (stationary or near-stationary)
    private func elevationSegment(
        _ source: ParsedRunSegment,
        with matcher: TrailMatcher
    ) -> [ParsedRunSegment] {
        let segments = matcher.segmentTrack(source.points)
        var out: [ParsedRunSegment] = []
        var runIdx = 0
        for seg in segments where !seg.isLift && seg.points.count >= 4 {
            let start = seg.points.first?.timestamp ?? source.startTime
            let end = seg.points.last?.timestamp ?? source.endTime
            let duration = end.timeIntervalSince(start)
            if duration > Self.maxRunDurationSeconds { continue }
            let avgSpeed = computedAvgSpeed(points: seg.points)
            if avgSpeed < Self.minRunAvgSpeedMS { continue }

            runIdx += 1
            out.append(ParsedRunSegment(
                runNumber: runIdx,
                startTime: start,
                endTime: end,
                durationSeconds: duration,
                topSpeedMS: nil,
                avgSpeedMS: nil,
                distanceMeters: nil,
                verticalMeters: nil,
                points: seg.points
            ))
        }
        // No segments (sparse data, malformed) → fall back to the
        // original single segment so the file still imports.
        return out.isEmpty ? [source] : out
    }

    /// Maximum plausible duration for a single ski run. Anything longer
    /// is the classifier mis-grouping a stationary period (lunch, long
    /// loading line, end-of-day pause) as a run. Conservative ceiling —
    /// even Whistler's Peak 2 Creek top-to-bottom is comfortably under.
    private static let maxRunDurationSeconds: TimeInterval = 25 * 60

    /// Minimum average ground speed for a "run" to count. Below this is
    /// effectively stationary — milling around at the bottom, waiting in
    /// a lift line, etc. Bottom of the range for actual skiing is well
    /// above (~3 m/s for greens).
    private static let minRunAvgSpeedMS: Double = 0.5

    /// Haversine moving-average speed over a point list, with sustained-
    /// pause segments excluded (audit Phase 4.1 — moving-time filter).
    /// Only used when the source format didn't provide native avgSpeed
    /// (raw GPX). Mirrors `TrailMatcher.movingSpeed` so imports and live
    /// recordings agree on what "moving" means: skip any window where
    /// the user was below 1 m/s for at least 10 continuous seconds (lift
    /// wait, lunch break, gear adjust). Without this, lift-and-lunch
    /// time silently dragged the average ski speed down by 30-50% for
    /// users importing whole-day GPX traces from non-Slopes apps.
    private func computedAvgSpeed(points: [GPXTrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }

        let pauseSpeedThreshold: Double = 1.0   // m/s
        let pauseMinDuration: TimeInterval = 10 // seconds

        var movingDistance = 0.0
        var movingTime: TimeInterval = 0

        var i = 0
        while i < points.count - 1 {
            let a = points[i]
            let b = points[i + 1]
            guard let t1 = a.timestamp, let t2 = b.timestamp else {
                i += 1
                continue
            }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0 else {
                i += 1
                continue
            }

            let dist = haversine(
                from: Coordinate(lat: a.latitude, lon: a.longitude),
                to: Coordinate(lat: b.latitude, lon: b.longitude)
            )
            let segSpeed = dist / dt

            if segSpeed < pauseSpeedThreshold {
                // Look ahead — only skip if the slow window lasts at
                // least `pauseMinDuration`. Brief slow patches inside
                // a normal run (powder turn, traverse) are kept.
                var pauseEnd = i + 1
                var pauseDuration = dt
                while pauseEnd < points.count - 1 {
                    let na = points[pauseEnd]
                    let nb = points[pauseEnd + 1]
                    guard let nt1 = na.timestamp, let nt2 = nb.timestamp else { break }
                    let nDt = nt2.timeIntervalSince(nt1)
                    guard nDt > 0 else { break }
                    let nDist = haversine(
                        from: Coordinate(lat: na.latitude, lon: na.longitude),
                        to: Coordinate(lat: nb.latitude, lon: nb.longitude)
                    )
                    if nDist / nDt >= pauseSpeedThreshold { break }
                    pauseDuration += nDt
                    pauseEnd += 1
                }
                if pauseDuration >= pauseMinDuration {
                    i = pauseEnd
                    continue
                }
            }

            movingDistance += dist
            movingTime += dt
            i += 1
        }
        return movingTime > 0 ? movingDistance / movingTime : 0
    }

    /// 3-sample-smoothed peak speed, capped at recreational ski
    /// ceiling (30 m/s) to defang GPS noise spikes. Same logic as
    /// TrailMatcher.peakSpeed kept here so we don't depend on having
    /// a graph just to compute peak from raw points.
    private func computedPeakSpeed(points: [GPXTrackPoint]) -> Double {
        guard points.count >= 4 else { return 0 }
        var samples: [(dist: Double, dt: Double)] = []
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            guard let t1 = a.timestamp, let t2 = b.timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0, dt <= 30 else { continue }
            samples.append((
                haversine(
                    from: Coordinate(lat: a.latitude, lon: a.longitude),
                    to: Coordinate(lat: b.latitude, lon: b.longitude)
                ),
                dt
            ))
        }
        guard samples.count >= 3 else { return 0 }
        var peak = 0.0
        for i in 2..<samples.count {
            let d = samples[i - 2].dist + samples[i - 1].dist + samples[i].dist
            let t = samples[i - 2].dt + samples[i - 1].dt + samples[i].dt
            guard t > 0 else { continue }
            let s = d / t
            if s > peak { peak = s }
        }
        return min(peak, 30.0)
    }

    // MARK: - Graph Loading

    private func loadGraph(for entry: ResortEntry) async throws -> MountainGraph {
        // Curated overlay + rebuild indices through GraphEnricher so
        // the importer, live recorder, and resort loader all stay in
        // lockstep. See GraphEnricher.swift for why this matters.
        if let cached = await GraphCacheManager.shared.loadGraph(resortID: entry.id) {
            return await GraphEnricher.enrich(cached, resortId: entry.id)
        }
        let resortData = try await OverpassService().fetchResortData(entry: entry)
        let dataForBuild = resortData.withGraphBuildHints(CuratedResortLoader.load(resortId: entry.id)?.graphBuildHints)
        let graph = GraphBuilder.buildGraph(from: dataForBuild, resortID: entry.id)
        let enriched = await GraphEnricher.enrich(graph, resortId: entry.id)
        await GraphCacheManager.shared.saveGraph(enriched)
        return enriched
    }

    // MARK: - Per-file profile merge

    /// Median per-difficulty speed merge — only runs against rows with
    /// non-nil difficulty (i.e., graph match succeeded). Unmatched runs
    /// still persist; they just don't contribute to the per-difficulty
    /// medians since there's no bucket to put them in.
    @MainActor
    private func mergeSpeedsForFile(matchedRuns: [MatchedRun], graph: MountainGraph?) async {
        var grouped: [RunDifficulty: [Double]] = [:]
        for run in matchedRuns {
            guard let d = run.difficulty else { continue }
            grouped[d, default: []].append(run.speed)
        }
        guard !grouped.isEmpty else { return }
        let medians = grouped.mapValues { Self.median($0) }
        var corrected = medians
        if let graph {
            validateAndCorrectSpeeds(matchedRuns: matchedRuns, graph: graph, averageSpeeds: &corrected)
        }
        await mergeSpeedsIntoProfile(corrected, matchedRunCount: matchedRuns.count)
    }

    @MainActor
    private func mergeConditionsForFile(matchedRuns: [MatchedRun]) async {
        let inference = inferConditionPreferences(from: matchedRuns)
        await mergeConditionsIntoProfile(inference)
    }

    // MARK: - Time validation (graph-required, optional)

    @MainActor
    private func validateAndCorrectSpeeds(
        matchedRuns: [MatchedRun],
        graph: MountainGraph,
        averageSpeeds: inout [RunDifficulty: Double]
    ) {
        guard matchedRuns.count >= 5 else { return }
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 2000,
            windSpeedKmh: 0,
            visibilityKm: 10,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )
        guard let profile = supabase.currentUserProfile else { return }
        var ratios: [RunDifficulty: [Double]] = [:]
        for run in matchedRuns {
            guard run.duration > 5 else { continue }
            guard let edgeId = run.edgeId, let difficulty = run.difficulty else { continue }
            guard let edge = graph.edges.first(where: { $0.id == edgeId }) else { continue }
            guard let predicted = profile.traverseTime(for: edge, context: context),
                  predicted > 0 else { continue }
            ratios[difficulty, default: []].append(run.duration / predicted)
        }
        for (difficulty, list) in ratios where list.count >= 3 {
            let r = Self.median(list)
            if r > 1.3 || r < 0.7, var s = averageSpeeds[difficulty] {
                s /= r
                averageSpeeds[difficulty] = s
            }
        }
    }

    // MARK: - Condition Inference

    private func inferConditionPreferences(from runs: [MatchedRun]) -> ConditionInference {
        var mogul: [Double] = []
        var nonMogul: [Double] = []
        var ungroomed: [Double] = []
        var groomed: [Double] = []
        var gladed: [Double] = []
        var nonGladed: [Double] = []
        var narrow: [Double] = []
        var wide: [Double] = []
        var exposed: [Double] = []
        var sheltered: [Double] = []
        // Only runs with a graph match contribute — for unmatched runs
        // condition flags default to false, which would tilt every ratio.
        for run in runs where run.edgeId != nil {
            if run.hasMoguls { mogul.append(run.speed) } else { nonMogul.append(run.speed) }
            if run.isGroomed { groomed.append(run.speed) } else { ungroomed.append(run.speed) }
            if run.isGladed  { gladed.append(run.speed) }  else { nonGladed.append(run.speed) }
            if let w = run.widthMeters {
                if w < 12 { narrow.append(run.speed) } else if w >= 20 { wide.append(run.speed) }
            }
            if let e = run.fallLineExposure {
                if e > 0.7 { exposed.append(run.speed) } else if e < 0.3 { sheltered.append(run.speed) }
            }
        }
        let ratio: ([Double], [Double]) -> Double? = { a, b in
            (a.count >= 3 && b.count >= 3) ? Self.median(a) / Self.median(b) : nil
        }
        let clamp: (Double) -> Double = { max(0.1, min(2.0, $0)) }
        return ConditionInference(
            mogulRatio: ratio(mogul, nonMogul).map(clamp),
            ungroomedRatio: ratio(ungroomed, groomed).map(clamp),
            gladedRatio: ratio(gladed, nonGladed).map(clamp),
            narrowRatio: ratio(narrow, wide).map(clamp),
            exposureRatio: ratio(exposed, sheltered).map(clamp)
        )
    }

    // MARK: - Median helper

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2.0
            : sorted[mid]
    }

    // MARK: - Persistence

    private struct ImportedRunRow: Encodable {
        let profile_id: String
        let resort_id: String
        let edge_id: String?
        let difficulty: String?
        let speed_ms: Double
        let peak_speed_ms: Double
        let duration_s: Double
        let vertical_m: Double
        let distance_m: Double
        let max_grade_deg: Double
        let run_at: Date
        let dedup_hash: String
        let source: String
        let source_file_hash: String
        /// Resolved at import-time so the viewer doesn't re-derive from
        /// the live graph on every render. Nil when the run didn't match
        /// any edge (no graph available, resort outside catalog, or the
        /// line missed the matcher's threshold).
        let trail_name: String?
        /// Audit Phase 2.1 — bucketed weather + surface fingerprint
        /// used by `recompute_profile_edge_speeds` to aggregate per
        /// bucket. The importer can't authoritatively reconstruct
        /// historical weather for old GPX files, so it stamps the
        /// `default` sentinel; the live recorder will populate real
        /// fingerprints once the conditions provider is wired in.
        let conditions_fp: String
    }

    @MainActor
    private func persistRuns(_ runs: [MatchedRun], resortId: String, graph: MountainGraph?) async {
        guard !runs.isEmpty,
              let userId = supabase.currentSession?.user.id else { return }
        let profileId = userId.uuidString

        var attrsByEdge: [String: (drop: Double, length: Double, maxGradeDeg: Double)] = [:]
        var nameByEdge: [String: String] = [:]
        if let graph {
            // Build a single MountainNaming per persistence call so each
            // run resolves through the same picker-aligned label rules
            // the rest of the app uses (matches what the imported-runs
            // viewer renders when the graph IS loaded — captured here so
            // it stays correct when the graph is unloaded later).
            let naming = MountainNaming(graph)
            for edge in graph.edges {
                attrsByEdge[edge.id] = (
                    edge.attributes.verticalDrop,
                    edge.attributes.lengthMeters,
                    edge.attributes.maxGradient
                )
                nameByEdge[edge.id] = naming.edgeLabel(edge, style: .canonical)
            }
        }

        let rows: [ImportedRunRow] = runs.map { run in
            let a = run.edgeId.flatMap { attrsByEdge[$0] } ?? (0, 0, 0)
            // Minute-floor of the start time absorbs ms-level drift when
            // the same activity is re-exported. Including <source> means
            // same activity from two apps keeps both rows by design.
            //
            // Bucket = 15 seconds (vs. the previous 60). Audit Phase 2.2:
            // back-to-back laps on the same chair within a single minute
            // were colliding under minute-bucketing and the second lap was
            // silently dropped by `ignoreDuplicates: true`. 15s is short
            // enough that real fast laps survive while still absorbing
            // the same-source re-export case (a second export of the same
            // run carries the same `timestamp` and lands in the same bucket).
            let startBucket = Int(run.timestamp.timeIntervalSince1970 / 15)
            let hash: String
            if let edgeId = run.edgeId {
                hash = "\(run.source.rawValue)|\(startBucket)|\(resortId)|\(edgeId)"
            } else {
                hash = "\(run.source.rawValue)|\(startBucket)|\(resortId)|unmatched"
            }
            // Prefer source-measured vertical/distance — graph nominals
            // systematically over/undershoot for partial-edge runs.
            let verticalM = run.measuredVerticalM ?? a.drop
            let distanceM = run.measuredDistanceM ?? a.length
            // Prefer naming-resolved label over the raw attribute on
            // MatchedRun — naming routes through the canonical chain
            // group title so a single OSM-fragmented chain reads
            // consistently. Fall back to MatchedRun.trailName when the
            // edge wasn't in the lookup. Last resort: synthesize a
            // label from difficulty + run timestamp so the row never
            // ships with a nil name (which would render as "Imported
            // Run" in the viewer).
            let primaryName = run.edgeId.flatMap { nameByEdge[$0] } ?? run.trailName
            let resolvedName: String = {
                if let n = primaryName, !n.isEmpty { return n }
                let timeFormatter = DateFormatter()
                timeFormatter.dateFormat = "h:mm a"
                let stamp = timeFormatter.string(from: run.timestamp)
                if let diff = run.difficulty {
                    return "\(diff.displayName) Run · \(stamp)"
                }
                return "Run · \(stamp)"
            }()
            return ImportedRunRow(
                profile_id: profileId,
                resort_id: resortId,
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
                trail_name: resolvedName,
                conditions_fp: ConditionsFingerprint.defaultBucket
            )
        }

        do {
            try await supabase.client
                .from("imported_runs")
                .upsert(rows, onConflict: "profile_id,dedup_hash", ignoreDuplicates: true)
                .execute()
        } catch {
            AppLog.importer.error("imported_runs upsert failed: \(error.localizedDescription)")
        }
    }

    /// Returns `true` when both RPCs succeeded (or there was no session
    /// to talk to in the first place — caller treats no-session as "no
    /// failure to surface" since auth is already broken upstream).
    @MainActor
    private func recomputeProfileStats() async -> Bool {
        guard let userId = supabase.currentSession?.user.id else { return true }
        var statsOK = true
        do {
            try await supabase.client
                .rpc("recompute_profile_stats", params: ["uid": AnyJSON.string(userId.uuidString)])
                .execute()
            await supabase.loadProfileStats()
        } catch {
            statsOK = false
            AppLog.importer.error("recompute_profile_stats failed: \(error.localizedDescription)")
        }
        // Per-edge rolling speeds also recompute from imported_runs, so
        // the solver picks up the new run's speed signal on its very
        // next solve. Lives downstream of stats so a stats failure
        // doesn't block edge-history rebuild (and vice versa).
        let edgeOK = await supabase.recomputeProfileEdgeSpeeds()
        return statsOK && edgeOK
    }

    // MARK: - Profile Speed Merge

    @MainActor
    private func mergeSpeedsIntoProfile(_ imported: [RunDifficulty: Double], matchedRunCount: Int) async {
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
    private func mergeConditionsIntoProfile(_ inf: ConditionInference) async {
        guard inf.mogulRatio != nil || inf.ungroomedRatio != nil
                || inf.gladedRatio != nil || inf.narrowRatio != nil
                || inf.exposureRatio != nil else { return }
        let p = supabase.currentUserProfile
        var updates: [String: AnyJSON] = [:]
        let bw = 0.6
        if let r = inf.mogulRatio {
            let e = p?.conditionMoguls ?? 0.5
            updates["condition_moguls"] = .double(e * (1 - bw) + r * bw)
            let et = p?.mogulTolerance ?? e
            updates["mogul_tolerance"] = .double(et * (1 - bw) + r * bw)
        }
        if let r = inf.ungroomedRatio {
            let e = p?.conditionUngroomed ?? 0.6
            updates["condition_ungroomed"] = .double(e * (1 - bw) + r * bw)
        }
        if let r = inf.gladedRatio {
            let e = p?.conditionGladed ?? 0.4
            updates["condition_gladed"] = .double(e * (1 - bw) + r * bw)
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
