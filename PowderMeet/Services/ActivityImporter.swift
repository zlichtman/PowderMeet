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
//   1. Read bytes once → SHA256.
//   2. Detect format (extension first, magic bytes second).
//   3. Parse → unified `ParsedActivity` envelope with native lap-level
//      stats when the format encoded them.
//   4. Identify resort independently per physical run by catalog votes; on
//      miss, use an exact reported-name/alias match, then a stable slug.
//   5. Load each represented resort graph — best-effort. A graph failure
//      skips enrichment for that group, never the import.
//   6. Build MatchedRun per ParsedRunSegment. When its graph is present,
//      attach edge id / difficulty / trail name. Stats come from native
//      lap data when present, or computed (haversine) from points.
//   7. Idempotently upsert all resort groups in one statement using the
//      database's real (profile_id, dedup_hash) uniqueness contract.
//   8. One order-independent post-batch profile merge uses newly inserted,
//      learning-eligible single-edge runs only.
//   9. ONE recompute_profile_stats RPC at end of batch, not per-file.
//

import Foundation
import CryptoKit
import Supabase

// MARK: - Activity Importer

// `nonisolated` — file IO + parsing + graph match + DB upserts must
// run off the main actor so the user can navigate during a multi-file
// import. Project default isolation is MainActor; opt out. Methods
// that genuinely need MainActor (touching `supabase.currentUserProfile`
// or @Observable state) keep their explicit `@MainActor` annotations.
nonisolated struct ActivityImporter {
    let supabase: SupabaseManager
    /// App-scoped owner of the same frozen/canonical datasets used by the map.
    /// Optional only for pure parser/unit-test construction.
    let resortManager: ResortDataManager?

    @MainActor
    init(supabase: SupabaseManager, resortManager: ResortDataManager? = nil) {
        self.supabase = supabase
        self.resortManager = resortManager
    }

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
        let batchStart = DispatchTime.now().uptimeNanoseconds
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
                logPerFileTelemetry(pf)
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

        logBatchTelemetry(
            processed: processed,
            recomputeSucceeded: recomputeSucceeded,
            elapsedMs: elapsedMs(since: batchStart)
        )

        return BatchImportResult(perFile: outcomes, recomputeSucceeded: recomputeSucceeded)
    }

    /// Aggregate matched runs across files and produce one global profile
    /// update. Edge-local observations supply measured pace, but broad skier
    /// pace/preferences are not resort-specific and must not depend on
    /// dictionary iteration or file completion order.
    /// Audit Phase 2.3 — running these inside the parallel `processFile`
    /// produced last-writer-wins on the bucketed-speed columns when two
    /// tasks hit the read+write across an `await`. Now: serialised on
    /// the main actor, deterministic over outcomes.
    @MainActor
    func runPostJoinMerges(processed: [ProcessedFile]) async {
        let groups = processed
            .flatMap(\.resortGroups)
            .sorted { lhs, rhs in lhs.resortId < rhs.resortId }
        let runs = groups.flatMap(\.matchedRuns)
        guard !runs.isEmpty else { return }

        let medians = ActivityCalibration.medianSpeeds(from: runs)
        await mergeSpeedsIntoProfile(
            medians,
            matchedRunCount: runs.filter(\.isProfileCalibrationEligible).count
        )
        await mergeConditionsIntoProfile(
            ActivityCalibration.inferConditionPreferences(from: runs)
        )
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
        let batchStart = DispatchTime.now().uptimeNanoseconds
        var processed: [ProcessedFile] = []
        processed.reserveCapacity(parsedList.count)

        await withTaskGroup(of: ProcessedFile.self) { group in
            for parsed in parsedList {
                let label = Self.syntheticLabel(for: parsed)
                group.addTask { await self.processParsed(parsed, label: label) }
            }
            for await pf in group {
                processed.append(pf)
                logPerFileTelemetry(pf)
            }
        }

        await runPostJoinMerges(processed: processed)

        let outcomes = processed.map(\.outcome)
        var recomputeSucceeded = true
        if outcomes.contains(where: { if case .imported = $0.status { return true }; return false }) {
            recomputeSucceeded = await recomputeProfileStats()
        }

        logBatchTelemetry(
            processed: processed,
            recomputeSucceeded: recomputeSucceeded,
            elapsedMs: elapsedMs(since: batchStart)
        )

        return BatchImportResult(perFile: outcomes, recomputeSucceeded: recomputeSucceeded)
    }

    /// Synthesise a URL-shaped label for non-file sources. Used purely as
    /// a banner identifier — `lastPathComponent` is what the user sees if
    /// the workout fails to import.
    static func syntheticLabel(for parsed: ParsedActivity) -> URL {
        let stamp = parsed.segments.first?.startTime
            .formatted(.iso8601.year().month().day())
            ?? parsed.sourceFileHash.prefix(8).description
        return URL(string: "\(parsed.source.rawValue)://workout/\(stamp)")
            ?? URL(fileURLWithPath: stamp)
    }

    // MARK: - Per-file pipeline

    func processFile(url: URL) async -> ProcessedFile {
        let fileStart = DispatchTime.now().uptimeNanoseconds
        var readMs: Int?
        var detectMs: Int?
        var parseMs: Int?
        var processMs: Int?

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        AppLog.importer.debug("processFile: \(url.lastPathComponent) ext=\(url.pathExtension) scoped=\(accessed)")

        // 1. Read bytes.
        let readStart = DispatchTime.now().uptimeNanoseconds
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.importer.error("read failed: \(error.localizedDescription)")
            return ProcessedFile(FileOutcome(url: url, status: .failed(error: ImportError.fileReadFailed(underlying: error))))
        }
        readMs = elapsedMs(since: readStart)
        let hash = data.sha256Hex
        AppLog.importer.debug("read \(data.count) bytes, sha256=\(hash.prefix(12))…")

        // 2. Detect format before parsing. PowderMeet backups short-circuit
        // into their explicit replace/restore path below.
        let detectStart = DispatchTime.now().uptimeNanoseconds
        guard let format = ActivityFileFormat.detect(url: url, data: data) else {
            detectMs = elapsedMs(since: detectStart)
            AppLog.importer.error("format detection FAILED — extension=\(url.pathExtension), first 200 bytes: \(String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>")")
            return ProcessedFile(FileOutcome(url: url, status: .failed(error: ImportError.unsupportedFormat)))
        }
        detectMs = elapsedMs(since: detectStart)
        AppLog.importer.debug("detected format: \(format)")

        // 2a. PowderMeet backup short-circuit. Backups use their explicit
        // restore identity and replacement semantics inside processBackup.
        if format == .powdermeetBackup {
            let processStart = DispatchTime.now().uptimeNanoseconds
            let pf = ProcessedFile(await processBackup(url: url, data: data))
            processMs = elapsedMs(since: processStart)
            return ProcessedFile(
                outcome: pf.outcome,
                resortGroups: pf.resortGroups,
                timing: FileImportTiming(
                    totalMs: elapsedMs(since: fileStart),
                    readMs: readMs,
                    detectMs: detectMs,
                    parseMs: parseMs,
                    processMs: processMs
                ),
                matchQuality: pf.matchQuality
            )
        }

        // There is no fragile whole-file preflight. Per-run upserts below use
        // the database's real uniqueness key, so exact repeats are skipped
        // without rejecting new runs that share a container with them.

        // 4. Parse → unified ParsedActivity envelope.
        let parseStart = DispatchTime.now().uptimeNanoseconds
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
        parseMs = elapsedMs(since: parseStart)

        let processStart = DispatchTime.now().uptimeNanoseconds
        let pf = await processParsed(parsed, label: url)
        processMs = elapsedMs(since: processStart)
        return ProcessedFile(
            outcome: pf.outcome,
            resortGroups: pf.resortGroups,
            timing: FileImportTiming(
                totalMs: elapsedMs(since: fileStart),
                readMs: readMs,
                detectMs: detectMs,
                parseMs: parseMs,
                processMs: processMs
            ),
            matchQuality: pf.matchQuality
        )
    }

    /// Post-parse pipeline shared by file imports and HealthKit. Takes a
    /// fully-formed `ParsedActivity` and runs steps 4–8 (resort id → graph
    /// load → match → persist → per-file merge). The `label` URL is only
    /// used to populate `FileOutcome.url` for banner copy.
    func processParsed(_ parsed: ParsedActivity, label url: URL) async -> ProcessedFile {
        guard !parsed.segments.isEmpty else {
            return ProcessedFile(FileOutcome(url: url, status: .empty))
        }

        // 4. Normalize provider hints into physical downhill runs before
        // matching. This is graph-independent, so GPX / Health / TCX / FIT /
        // legacy Slopes all agree on run-vs-lift boundaries even when the
        // mountain dataset is unavailable.
        let segmentsForMatching = SkiActivitySegmenter.downhillRunSegments(
            from: parsed.segments
        )
        guard !segmentsForMatching.isEmpty else {
            return ProcessedFile(FileOutcome(url: url, status: .empty))
        }

        // 5. Resolve each physical run independently. Provider archives and
        // merged workout exports can contain more than one mountain; assigning
        // the entire file from its first fix silently mislabeled every later
        // run and trained the wrong graph.
        let reportedCatalogEntry = ActivityResortResolver.identifyResort(
            named: parsed.resortName
        )
        let resolvedGroups = ActivityResortResolver.group(
            segmentsForMatching,
            fallbackResortId: reportedCatalogEntry?.id ?? slugify(parsed.resortName),
            fallbackCatalogEntry: reportedCatalogEntry
        )
        var preparedGroups: [ProcessedResortGroup] = []
        preparedGroups.reserveCapacity(resolvedGroups.count)
        var strictCount = 0
        var relaxedCount = 0
        var nearestCount = 0
        var unmatchedCount = 0

        for resolved in resolvedGroups {
            // 6. Graph load is best-effort and isolated per resort. Failure at
            // one mountain leaves only that group's runs unnamed.
            var dataset: MountainDataset?
            var graph: MountainGraph?
            if let entry = resolved.catalogEntry {
                do {
                    dataset = try await loadDataset(for: entry)
                    graph = dataset?.graph
                } catch {
                    AppLog.importer.error("loadGraph failed for \(entry.id): \(error.localizedDescription) — proceeding without trail names")
                }
            }
            let matcher = graph.map(TrailMatcher.init(graph:))
            let naming = graph.map { MountainNaming($0) }

            // 7. Match every physical run to that resort's canonical graph.
            var matchedRuns: [MatchedRun] = []
            matchedRuns.reserveCapacity(resolved.segments.count)
            for segment in resolved.segments {
            // Graph-match is enrichment only — never gates persistence.
            var edgeId: String?
            var difficulty: RunDifficulty?
            var trailName: String?
            var hasMoguls = false
            var isGroomed: Bool?
            var isGladed = false
            var widthMeters: Double?
            var fallLineExposure: Double?
            var matchedSegmentIDs: [String] = []
            var edgePaceObservations: [EdgePaceObservation] = []
            var matchConfidence = 0.0
            var matchMethod = "unmatched"

            if let matcher, segment.points.count >= 4 {
                let trailMatcherSegment = SegmentedRun(points: segment.points, isLift: false)
                if let topologyMatch = matcher.matchRunTopology(trailMatcherSegment) {
                    let edge = topologyMatch.primaryEdge
                    // Tier 1 — strict (60m / 45°). Gates per-edge skill
                    // memory and the condition-flag merge. High-confidence
                    // input only.
                    edgeId = edge.id
                    difficulty = edge.attributes.difficulty
                    trailName = naming.flatMap {
                        ImportedRunNameQuality.evidenceBackedTrailName(
                            for: edge,
                            naming: $0
                        )
                    }
                    hasMoguls = edge.attributes.hasMoguls
                    isGroomed = edge.attributes.isGroomed
                    isGladed = edge.attributes.isGladed
                    widthMeters = edge.attributes.estimatedTrailWidthMeters
                    fallLineExposure = edge.attributes.fallLineExposure
                    matchedSegmentIDs = topologyMatch.segmentIDs
                    edgePaceObservations = topologyMatch.edgePaceObservations
                    let evidence = RecordedPaceEvidence(
                        confidence: topologyMatch.confidence,
                        observations: edgePaceObservations
                    )
                    matchConfidence = evidence.confidence
                    matchMethod = evidence.method
                    strictCount += 1
                } else if let nameEdge = matcher.bestEffortNameMatch(for: trailMatcherSegment) {
                    // Tier 2 — relaxed (120m / 70°). Recovers parallel-
                    // trail / sparse-GPS runs that strict dropped. Sets
                    // trail name only; does NOT feed edge_id / skill
                    // memory / conditions so a best-effort guess can't
                    // bias the algorithm.
                    trailName = naming.flatMap {
                        ImportedRunNameQuality.evidenceBackedTrailName(
                            for: nameEdge,
                            naming: $0
                        )
                    }
                    // Inherit difficulty from the matched edge for display
                    // purposes (still doesn't go into the algo's
                    // condition merge — that's gated above on edgeId).
                    if difficulty == nil { difficulty = nameEdge.attributes.difficulty }
                    matchConfidence = 0.4
                    matchMethod = "relaxed_name"
                    relaxedCount += 1
                } else if let nearest = matcher.nearestRunEdgeByCentroid(for: trailMatcherSegment) {
                    // Tier 3 — nearest-by-centroid (≤300m). Fires when
                    // tier 1 and tier 2 both rejected. Catches dense-
                    // tree / sparse-GPS / off-piste runs whose tracks
                    // wandered too far from any single trail. Capped at
                    // 300m so we don't pick a trail on the other side
                    // of a peak.
                    trailName = naming.flatMap {
                        ImportedRunNameQuality.evidenceBackedTrailName(
                            for: nearest,
                            naming: $0
                        )
                    }
                    if difficulty == nil { difficulty = nearest.attributes.difficulty }
                    matchConfidence = 0.15
                    matchMethod = "nearest_name"
                    nearestCount += 1
                } else {
                    unmatchedCount += 1
                }
            } else {
                unmatchedCount += 1
            }

            // Stats: prefer native lap-level numbers from the parser;
            // compute from points only when missing.
            let computedSpeed = computedAvgSpeed(points: segment.points)
            let rawSpeed = segment.avgSpeedMS ?? computedSpeed
            let speed = rawSpeed.isFinite
                ? min(GPXSpeedStats.peakSpeedCeiling, max(0, rawSpeed))
                : 0
            let computedPeak = computedPeakSpeed(points: segment.points)
            let rawPeak = segment.topSpeedMS ?? computedPeak
            let peak = min(
                GPXSpeedStats.peakSpeedCeiling,
                max(speed, rawPeak.isFinite ? rawPeak : computedPeak)
            )
            let rawDuration = segment.durationSeconds > 0
                ? segment.durationSeconds
                : segment.endTime.timeIntervalSince(segment.startTime)
            let metricsAreValid = speed > 0
                && rawDuration.isFinite
                && rawDuration > 0
            let duration = metricsAreValid ? rawDuration : 1
            if !metricsAreValid {
                // Keep the row for the user's log, but never let a track with
                // no usable clock/speed anchor per-edge learning at zero.
                matchedSegmentIDs = []
                edgePaceObservations = []
                matchConfidence = 0
                matchMethod = "display_only_invalid_metrics"
            }

                matchedRuns.append(MatchedRun(
                edgeId: edgeId,
                datasetVersion: dataset?.version.identifier,
                matchedSegmentIDs: matchedSegmentIDs,
                edgePaceObservations: edgePaceObservations,
                matchConfidence: matchConfidence,
                matchMethod: matchMethod,
                // Imported history cannot truthfully inherit the ski selected
                // in the profile today. Live recording stamps its known ski;
                // file/Health imports stay unknown until a source exposes
                // trustworthy equipment metadata.
                equipmentIDAtActivity: nil,
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
            preparedGroups.append(ProcessedResortGroup(
                resortId: resolved.resortId,
                matchedRuns: matchedRuns,
                graph: graph
            ))
        }

        // 8. Persist runs only. Profile-column merges defer to the
        // post-join aggregator (`runPostJoinMerges`) so two parallel
        // tasks can't last-writer-win on the bucketed-speed columns.
        // A persistence failure must surface as `.failed` — reporting
        // `.imported` for runs that never reached the DB is a lie the user
        // pays for later (empty log under a "success" banner).
        do {
            let insertedHashes = try await persistRuns(preparedGroups)
            let quality = MatchQualityStats(
                strictCount: strictCount,
                relaxedCount: relaxedCount,
                nearestCount: nearestCount,
                unmatchedCount: unmatchedCount
            )
            if insertedHashes.isEmpty {
                return ProcessedFile(
                    outcome: FileOutcome(url: url, status: .duplicate),
                    resortGroups: [],
                    matchQuality: quality
                )
            }
            var remainingHashes = insertedHashes
            let insertedGroups = preparedGroups.compactMap { group -> ProcessedResortGroup? in
                let insertedRuns = group.matchedRuns.filter { run in
                    remainingHashes.remove(
                        ImportedRunIdentity.dedupHash(
                            for: run,
                            resortID: group.resortId
                        )
                    ) != nil
                }
                guard !insertedRuns.isEmpty else { return nil }
                return ProcessedResortGroup(
                    resortId: group.resortId,
                    matchedRuns: insertedRuns,
                    graph: group.graph
                )
            }
            let insertedCount = insertedGroups.reduce(0) { $0 + $1.matchedRuns.count }
            return ProcessedFile(
                outcome: FileOutcome(
                    url: url,
                    status: .imported(runs: insertedCount)
                ),
                // Profile calibration must learn only from rows this import
                // actually inserted. Replayed rows are already represented in
                // the profile and must not receive a second merge weight.
                resortGroups: insertedGroups,
                matchQuality: quality
            )
        } catch {
            AppLog.importer.error("persistRuns failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return ProcessedFile(
                outcome: FileOutcome(url: url, status: .failed(error: error)),
                resortGroups: [],
                matchQuality: MatchQualityStats(
                    strictCount: 0,
                    relaxedCount: 0,
                    nearestCount: 0,
                    unmatchedCount: 0
                )
            )
        }
    }
}
