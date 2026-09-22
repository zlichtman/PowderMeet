//
//  LiveRunRecorder.swift
//  PowderMeet
//
//  Passive in-app run/lift segmentation. While `start()` is active and
//  the user has `liveRecordingEnabled` on their profile, every fix
//  delivered by `LocationManager` is appended to a sliding-window
//  buffer and classified by the same `SkiActivitySegmenter` used for
//  imported activity files.
//
//  When the classifier transitions from "in a run" → "out of run"
//  (i.e. the user got on a lift, or stopped moving), the buffered run
//  points are flushed: matched against `ResortDataManager.currentGraph`
//  via `TrailMatcher.matchRun`, packaged as a `MatchedRun` with
//  `source = .live`, and upserted into `imported_runs`. The dedup hash
//  uses the same identity builder as `ActivityImporter.persistRuns`.
//  Source remains part of that identity intentionally: cross-provider
//  physical dedup waits for paired real-world fixtures.
//
//  After every successful persist, the recorder fires a debounced
//  (≥30s) call to `SupabaseManager.recomputeProfileEdgeSpeeds()` so
//  the per-edge skill memory loop picks up the new observation on
//  the next solve.
//
//  No graph loaded for the current resort? Persist the row anyway
//  with `edge_id == nil`. Same contract as `ActivityImporter`: "X
//  runs you skied → X runs in your profile" regardless of mountain
//  data availability.
//
//  Concurrency contract:
//   - `flushRun(points:)` is fire-and-forget via `Task { ... }` from
//     the run/lift transition and from `stop()`. The Task strongly
//     captures `self` so the recorder stays alive until the persist
//     completes; this is intentional — the in-flight points must hit
//     `imported_runs` even if the user backgrounds the app or signs
//     out mid-flush. (The DB write is the source of truth; nothing
//     downstream depends on the recorder still existing afterwards.)
//   - `recomputeTask` IS owned: it's reassigned on each scheduling
//     call, so the prior debounce can be cancelled cleanly. We capture
//     `supabase` (the SupabaseManager singleton, always alive) rather
//     than `self`, so the trailing-edge recompute fires even if the
//     recorder is torn down between the debounce trigger and the
//     RPC roundtrip.
//
//  Buffer cap: 10 minutes of fixes (~600 at ~1 Hz). Drop oldest on
//  overflow. A run that's been going for >10 minutes is either a very
//  long run or — more realistically — a lift the classifier hasn't
//  detected yet because GPS noise looks just-not-quite-flat-enough.
//  Either way, dropping oldest preserves recent context for the
//  classifier without unbounded memory growth.
//

import Foundation
import CoreLocation
import Observation
import Supabase
import Auth

@MainActor
@Observable
final class LiveRunRecorder {

    // MARK: - Dependencies

    @ObservationIgnored private let supabase: SupabaseManager
    @ObservationIgnored private let resortManager: ResortDataManager
    @ObservationIgnored private let locationManager: LocationManager

    /// Read-back hook for the coordinator's live `ResortConditions`.
    /// Wired up in `ContentCoordinator.bind(resortManager:)` so the
    /// recorder doesn't need a back-pointer to the coordinator. Returns
    /// `nil` when no current conditions snapshot is available — runs
    /// then fall back to the `default` conditions_fp bucket.
    @ObservationIgnored var conditionsProvider: () -> ResortConditions? = { nil }

    // MARK: - Public state

    /// True between `start()` and `stop()`. Surfaced to the Profile UI.
    private(set) var isRecording: Bool = false

    /// Latest classified state — used by the UI status pill.
    /// `.idle` before any classification, `.run` while in a downhill
    /// segment, `.lift` while on a lift / stopped.
    enum Phase { case idle, run, lift }
    private(set) var phase: Phase = .idle

    /// Number of runs persisted this session — drives the
    /// "ON · 4 RUNS" status pill copy.
    private(set) var runsRecordedThisSession: Int = 0

    // MARK: - Internal state

    /// Sliding-window buffer of recent fixes. Newest at the end.
    /// We hold up to `maxBufferedPoints` (~10 min @ 1 Hz). On overflow
    /// the oldest fix is dropped.
    private var buffer: [GPXTrackPoint] = []

    /// Last fixGeneration we observed — guards against re-processing
    /// the same fix when SwiftUI publishes a no-op update (e.g.
    /// `currentLocation` reassigned to the same value).
    private var lastIngestedFixGeneration: UInt64 = 0

    /// Index in `buffer` where the current run started (or nil if
    /// currently on a lift / idle). When the classifier flips from
    /// run → not-run, we slice `buffer[runStartIndex..<currentBoundary]`
    /// out and feed that to `flushRun(...)`.
    private var runStartIndex: Int?

    /// Cached classifier state: true if the most recent window looked
    /// like a lift. Initially nil — first classification establishes
    /// the baseline without persisting an empty leading run.
    private var lastClassifiedAsLift: Bool?

    /// Last `recomputeProfileEdgeSpeeds()` time. The recompute runs
    /// at most once every `recomputeDebounceSeconds` so 5 fast runs
    /// in a row don't fire 5 server-side aggregations.
    @ObservationIgnored private var lastRecomputeAt: Date?

    /// In-flight recompute task. We don't kick a second one until the
    /// first finishes — recompute is server-side and idempotent, so
    /// stacking does no good and just wastes a round trip.
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?

    /// Set to true when a `flushRun` lands DURING the debounce
    /// window or while a recompute is already in flight. The
    /// completion handler checks this flag and re-schedules the
    /// recompute so the run that arrived mid-window doesn't sit
    /// uncalibrated until the user does something else that
    /// triggers a recompute. Without this, a burst of 5 runs in a
    /// minute would calibrate only the first one.
    @ObservationIgnored private var pendingRecomputeAfterFlight: Bool = false

    // MARK: - Tunables

    /// Min points to consider a flushed run. Same minimum
    /// `TrailMatcher.segmentTrack` enforces.
    private let minRunPoints = 4

    /// Resort-vicinity gate. Passive recording must only collect when
    /// the device is actually at a ski area — without this, driving to
    /// the mountain (or anywhere) with the toggle on logs garbage
    /// "runs" against whatever resort was selected. Buffer is generous
    /// so the base area / parking lot / access chairlift still count;
    /// hysteresis (enter ≤1 km, leave >2 km of a resort bbox) keeps a
    /// run that briefly clips the bbox edge from being chopped.
    private let vicinityEnterMeters: Double = 1_000
    private let vicinityExitMeters: Double = 2_000

    /// Sticky vicinity state for the hysteresis band.
    @ObservationIgnored private var wasInVicinity = false

    /// Sliding-window buffer cap. ~10 minutes @ 1 Hz. Drop oldest
    /// on overflow.
    private let maxBufferedPoints = 600

    /// Lower bound on the recompute call rate — server-side
    /// aggregation isn't free, and back-to-back runs on a busy day
    /// would otherwise spam it.
    private let recomputeDebounceSeconds: TimeInterval = 30

    // MARK: - Init

    init(
        supabase: SupabaseManager,
        resortManager: ResortDataManager,
        locationManager: LocationManager
    ) {
        self.supabase = supabase
        self.resortManager = resortManager
        self.locationManager = locationManager
    }

    // MARK: - Lifecycle

    /// Begin observing fixes. Idempotent — safe to call repeatedly
    /// (e.g. on every scenePhase resume).
    func start() {
        guard !isRecording else { return }
        isRecording = true
        // Start fresh — don't carry stale points across a stop/start.
        buffer.removeAll(keepingCapacity: true)
        runStartIndex = nil
        lastClassifiedAsLift = nil
        runsRecordedThisSession = 0
        phase = .idle
        wasInVicinity = false
        lastIngestedFixGeneration = locationManager.fixGeneration
    }

    /// Stop observing fixes. If a run was in progress, flush it before
    /// dropping state — otherwise a backgrounding mid-run would lose
    /// the partial. (We treat stop as "the run ended" because we
    /// can't tell whether the user is about to be backgrounded for
    /// 10 seconds or 10 hours.)
    func stop() {
        guard isRecording else { return }
        if let startIdx = runStartIndex, startIdx < buffer.count {
            let runPoints = Array(buffer[startIdx..<buffer.count])
            if runPoints.count >= minRunPoints {
                Task { await self.flushRun(points: runPoints) }
            }
        }
        isRecording = false
        runStartIndex = nil
        lastClassifiedAsLift = nil
        phase = .idle
    }

    // MARK: - Resort vicinity

    /// True when `coord` is at (or right next to) a ski area. Prefers
    /// the loaded resort; falls back to any catalog resort so a session
    /// that armed before a resort loaded still gates correctly.
    /// Hysteresis: a generous enter buffer, a wider exit buffer, so a
    /// run skirting the bbox edge isn't repeatedly chopped.
    func isWithinResortVicinity(_ coord: CLLocationCoordinate2D) -> Bool {
        let buffer = wasInVicinity ? vicinityExitMeters : vicinityEnterMeters
        let inside: Bool
        if let here = resortManager.currentEntry,
           Self.bbox(here.bounds, contains: coord, bufferMeters: buffer) {
            inside = true
        } else {
            inside = ResortEntry.catalog.contains {
                Self.bbox($0.bounds, contains: coord, bufferMeters: buffer)
            }
        }
        wasInVicinity = inside
        return inside
    }

    /// `BoundingBox.contains` expanded by `bufferMeters` (converted to
    /// degrees at the bbox latitude). Internal for unit testing.
    static func bbox(
        _ b: BoundingBox,
        contains c: CLLocationCoordinate2D,
        bufferMeters: Double
    ) -> Bool {
        let midLat = (b.minLat + b.maxLat) / 2
        let dLat = bufferMeters / 111_000.0
        let dLon = bufferMeters / (111_000.0 * max(cos(midLat * .pi / 180), 0.0001))
        return c.latitude  >= b.minLat - dLat && c.latitude  <= b.maxLat + dLat
            && c.longitude >= b.minLon - dLon && c.longitude <= b.maxLon + dLon
    }

    // MARK: - Fix ingestion

    /// Hook the recorder up to the LocationManager. Caller drives
    /// this from wherever it observes `fixGeneration` (the
    /// `ContentCoordinator.handleLocationChange` path is the natural
    /// fit — every accepted fix bumps `fixGeneration`).
    func ingestCurrentFix() {
        guard isRecording else { return }
        // Honour the user-level kill switch — checked on every fix,
        // not just at start, so a mid-session toggle takes effect
        // immediately.
        guard supabase.currentUserProfile?.liveRecordingEnabled ?? true else {
            // User disabled recording mid-session — flush in-progress
            // run + halt. They can flip it back on later.
            stop()
            return
        }

        let gen = locationManager.fixGeneration
        guard gen != lastIngestedFixGeneration else { return }
        lastIngestedFixGeneration = gen

        guard let coord = locationManager.currentLocation,
              RoutingFixPolicy.isUsable(
                horizontalAccuracyMeters: locationManager.currentAccuracy,
                capturedAt: locationManager.currentFixTimestamp
              ) else { return }

        // Resort-vicinity gate. If the device isn't at a ski area, drop
        // the fix; if a run was somehow in progress (drove away mid-run)
        // flush the partial and halt accumulation. No resort nearby =
        // nothing to record.
        if !isWithinResortVicinity(coord) {
            if runStartIndex != nil { stop() }
            return
        }

        let speed = locationManager.currentSpeed >= 0 ? locationManager.currentSpeed : nil
        let point = GPXTrackPoint(
            latitude: coord.latitude,
            longitude: coord.longitude,
            elevation: locationManager.currentAltitude,
            timestamp: locationManager.currentFixTimestamp ?? .now,
            speed: speed
        )
        ingest(point: point)
    }

    /// Test-friendly entry point. Production code should always go
    /// through `ingestCurrentFix()`.
    func ingest(point: GPXTrackPoint) {
        buffer.append(point)
        // Buffer cap — drop oldest. If we drop while a run is in
        // progress, slide the run-start index down so it still
        // points at the right slot.
        if buffer.count > maxBufferedPoints {
            let drop = buffer.count - maxBufferedPoints
            buffer.removeFirst(drop)
            if let s = runStartIndex {
                runStartIndex = max(0, s - drop)
            }
        }

        // Need at least 2 points to classify; bail until we do.
        guard buffer.count >= 2 else { return }

        let windowStart = max(
            0,
            buffer.count - SkiActivitySegmenter.observationWindowSize
        )
        let window = Array(buffer[windowStart..<buffer.count])
        let observed = SkiActivitySegmenter.classifyWindow(window)
        let isLift: Bool = {
            switch observed {
            case .uphill, .stationary:
                return true
            case .downhill:
                return false
            case .unknown:
                return lastClassifiedAsLift ?? false
            }
        }()

        // First classification establishes the baseline without
        // emitting anything. Without this guard, a cold-start lift
        // ride would be flushed as a 0-point run on its first
        // transition.
        guard let prev = lastClassifiedAsLift else {
            lastClassifiedAsLift = isLift
            phase = isLift ? .lift : .run
            // Starting in a run — mark its start index here.
            if !isLift {
                runStartIndex = buffer.count - 1
            }
            return
        }

        if prev == isLift {
            // No transition — just keep accumulating.
            return
        }

        // Transition.
        lastClassifiedAsLift = isLift
        phase = isLift ? .lift : .run

        if isLift {
            // run → lift transition: flush the in-progress run.
            if let startIdx = runStartIndex, startIdx < buffer.count {
                let runPoints = Array(buffer[startIdx..<buffer.count])
                if runPoints.count >= minRunPoints {
                    Task { await self.flushRun(points: runPoints) }
                }
            }
            runStartIndex = nil
        } else {
            // lift → run transition: mark the run start. Keeping the
            // lift points in the buffer is fine — the cap evicts
            // them eventually, and the classifier doesn't reread
            // older windows, just the trailing one.
            runStartIndex = buffer.count - 1
        }
    }

    // MARK: - Flush + persist

    /// Match a finished run against the current graph (best effort)
    /// and persist a single `imported_runs` row. Mirrors the
    /// `ActivityImporter.persistRuns` row shape and source-aware identity.
    private func flushRun(points: [GPXTrackPoint]) async {
        guard points.count >= minRunPoints else { return }
        guard let userId = supabase.currentSession?.user.id else { return }

        let resortEntry = resortManager.currentEntry
        // Resort id resolution: prefer the loaded resort (the user is
        // skiing on it). Without that, identify from the first GPS
        // point — same fallback ActivityImporter uses. Worst case:
        // "unknown-resort" so the row still persists.
        let resortId: String =
            resortEntry?.id
            ?? points.first.flatMap(TrailMatcher.identifyResort(from:))?.id
            ?? "unknown-resort"

        let segment = SegmentedRun(points: points, isLift: false)
        // Canonical datasets are already fully named and grouped by the
        // server-authoritative build. Reapplying an IPA-bundled overlay here
        // would let live recording interpret the same run differently from
        // activity import and routing. Legacy compatibility graphs still need
        // the local overlay before matching.
        let dataset = resortManager.currentDataset
        let graph = await Self.matchingGraph(
            dataset: dataset,
            displayedGraph: resortManager.currentGraph,
            resortID: resortId
        )

        var edgeId: String?
        var difficulty: RunDifficulty?
        var trailName: String?
        var hasMoguls = false
        var isGroomed = false
        var isGladed = false
        var widthMeters: Double?
        var fallLineExposure: Double?
        var verticalDrop: Double = 0
        var lengthMeters: Double = 0
        var maxGradeDeg: Double = 0
        var matchedSegmentIDs: [String] = []
        var edgePaceObservations: [EdgePaceObservation] = []
        var matchConfidence = 0.0
        var matchMethod = "unmatched"

        if let graph {
            let matcher = TrailMatcher(graph: graph)
            if let topologyMatch = matcher.matchRunTopology(segment) {
                let edge = topologyMatch.primaryEdge
                edgeId = edge.id
                difficulty = edge.attributes.difficulty
                hasMoguls = edge.attributes.hasMoguls
                isGroomed = edge.attributes.isGroomed ?? false
                isGladed = edge.attributes.isGladed
                widthMeters = edge.attributes.estimatedTrailWidthMeters
                fallLineExposure = edge.attributes.fallLineExposure
                verticalDrop = edge.attributes.verticalDrop
                lengthMeters = edge.attributes.lengthMeters
                maxGradeDeg = edge.attributes.maxGradient
                matchedSegmentIDs = topologyMatch.segmentIDs
                edgePaceObservations = topologyMatch.edgePaceObservations
                let evidence = RecordedPaceEvidence(
                    confidence: topologyMatch.confidence,
                    observations: edgePaceObservations
                )
                matchConfidence = evidence.confidence
                matchMethod = evidence.method
                // Naming routes through MountainNaming so the imported-runs
                // viewer reads the same canonical chain title the rest of
                // the app uses (matches ActivityImporter.persistRuns).
                let naming = MountainNaming(graph)
                trailName = ImportedRunNameQuality.evidenceBackedTrailName(
                    for: edge,
                    naming: naming
                )
            }
        }

        // Speed stats from the matcher's helpers when we have a
        // graph; otherwise compute via simple haversine. Using the
        // matcher's helpers when available keeps live runs and Slopes
        // imports apples-to-apples (pause exclusion, peak smoothing,
        // GPS-noise ceiling — all the same).
        let avgSpeed: Double
        let peakSpeed: Double
        if let graph {
            let matcher = TrailMatcher(graph: graph)
            avgSpeed = matcher.movingSpeed(for: points)
            peakSpeed = max(matcher.peakSpeed(for: points), avgSpeed)
        } else {
            avgSpeed = LiveRunRecorder.haversineAvgSpeed(points: points)
            peakSpeed = max(LiveRunRecorder.haversinePeakSpeed(points: points), avgSpeed)
        }

        guard avgSpeed > 0 else {
            // Degenerate run (no time delta between points, all
            // duplicates). Don't persist a 0 m/s row — it would
            // anchor the per-edge rolling speed at zero.
            return
        }

        let startTime = points.first?.timestamp ?? Date()
        let endTime = points.last?.timestamp ?? startTime
        let duration = max(1, endTime.timeIntervalSince(startTime))
        // 15-second buckets — match ActivityImporter (audit Phase 2.2).
        // Two real laps started within the same minute used to collide
        // under the previous minute-bucket and the second one was
        // silently dropped by `ignoreDuplicates: true`.
        let startBucket = Int(startTime.timeIntervalSince1970 / 15)
        let dedupHash = ImportedRunIdentity.dedupHash(
            source: .live,
            timestamp: startTime,
            duration: duration,
            resortID: resortId,
            edgeID: edgeId
        )

        // Live recordings have no source file — use a stable per-row
        // sentinel so the column stays non-empty (other code paths
        // expect a string).
        let sourceFileHash = "live-\(userId.uuidString)-\(startBucket)"

        // Audit Phase 2.1 — populate `conditions_fp` from the live
        // weather snapshot when available. Live recordings have a
        // strong claim to "conditions at run time" because the run
        // happened seconds ago. When the snapshot is missing (cold
        // launch race, no network), fall back to the `default` bucket
        // so legacy rows still aggregate cleanly server-side.
        let surface = ConditionsFingerprint.SurfaceFlags(
            hasMoguls: hasMoguls,
            isUngroomed: !isGroomed,
            isGladed: isGladed
        )
        let conditions = conditionsProvider()
        let fingerprint: (ConditionsFingerprint.SurfaceFlags) -> String = { surface in
            conditions.map { c in
                ConditionsFingerprint.fingerprint(
                    temperatureC: c.temperatureC,
                    windSpeedKph: c.windSpeedKph,
                    snowfallLast24hCm: c.snowfallLast24hCm,
                    visibilityKm: c.visibilityKm,
                    cloudCoverPercent: c.cloudCoverPercent,
                    surface: surface
                )
            } ?? ConditionsFingerprint.defaultBucket
        }
        let cf = fingerprint(surface)
        if let graph {
            edgePaceObservations = edgePaceObservations.map { observation in
                guard let edge = graph.edge(byID: observation.edgeId) else {
                    return observation.withConditions(ConditionsFingerprint.defaultBucket)
                }
                return observation.withConditions(fingerprint(.init(
                    hasMoguls: edge.attributes.hasMoguls,
                    isUngroomed: !(edge.attributes.isGroomed ?? false),
                    isGladed: edge.attributes.isGladed
                )))
            }
        } else {
            edgePaceObservations = edgePaceObservations.map {
                $0.withConditions(ConditionsFingerprint.defaultBucket)
            }
        }
        let measuredVertical = SkiActivitySegmenter.descentMeters(points)
        let measuredDistance = SkiActivitySegmenter.totalDistanceMeters(points)
        let row = ImportedRunWriteRow(
            profile_id: userId.uuidString,
            resort_id: resortId,
            edge_id: edgeId,
            difficulty: difficulty?.rawValue,
            speed_ms: avgSpeed,
            peak_speed_ms: peakSpeed,
            duration_s: duration,
            vertical_m: measuredVertical > 0 ? measuredVertical : verticalDrop,
            distance_m: measuredDistance > 0 ? measuredDistance : lengthMeters,
            max_grade_deg: maxGradeDeg,
            run_at: startTime,
            dedup_hash: dedupHash,
            source: ImportSource.live.rawValue,
            source_file_hash: sourceFileHash,
            raw_source_identity: sourceFileHash,
            dataset_version: dataset?.version.identifier,
            matched_segment_ids: matchedSegmentIDs,
            edge_observations: edgePaceObservations,
            match_confidence: matchConfidence,
            match_method: matchMethod,
            equipment_id_at_activity: supabase.currentUserProfile?.preferredSkiId,
            trail_name: trailName,
            conditions_fp: cf
        )

        do {
            let inserted = try await supabase.upsertImportedRunRows([row])
            guard !inserted.isEmpty else { return }
            runsRecordedThisSession += 1
            // Suppress unused warnings for trail-matcher-derived flags
            // we don't currently roll up here. They flow downstream
            // via the recompute aggregator from the persisted row.
            _ = (hasMoguls, isGroomed, isGladed, widthMeters, fallLineExposure)
            scheduleEdgeSpeedRecompute()
        } catch {
            AppLog.importer.error("persist failed: \(error.localizedDescription)")
        }
    }

    /// Resolves the immutable graph used for live activity matching.
    /// Canonical data passes through byte-for-byte; only transitional legacy
    /// data may receive the bundled compatibility overlay.
    nonisolated static func matchingGraph(
        dataset: MountainDataset?,
        displayedGraph: MountainGraph?,
        resortID: String
    ) async -> MountainGraph? {
        if let dataset {
            guard dataset.resortID == resortID else { return nil }
            if dataset.source == .canonicalServer {
                return dataset.graph
            }
            return await GraphEnricher.enrich(dataset.graph, resortId: resortID)
        }
        guard let displayedGraph, displayedGraph.resortID == resortID else {
            return nil
        }
        return await GraphEnricher.enrich(displayedGraph, resortId: resortID)
    }

    // MARK: - Debounced recompute

    /// Schedule a profile_edge_speeds recompute — rate-limited to at
    /// most one call per `recomputeDebounceSeconds`. Calls that land
    /// during the debounce window OR while a recompute is in flight
    /// flag a follow-up recompute so a burst of runs all eventually
    /// calibrate, even when only the first one wins the rate-limit
    /// race.
    private func scheduleEdgeSpeedRecompute() {
        let now = Date()
        let withinDebounce = lastRecomputeAt.map { now.timeIntervalSince($0) < recomputeDebounceSeconds } ?? false
        if withinDebounce || recomputeTask != nil {
            pendingRecomputeAfterFlight = true
            return
        }
        lastRecomputeAt = now
        recomputeTask = Task { [supabase] in
            // `recomputeProfileEdgeSpeeds()` returns false when the RPC
            // failed. Without surfacing it, a transient backend hiccup
            // would leave the solver's per-edge skill memory frozen and
            // the user would have no signal — they'd just notice the
            // solver picking the same edges as before their recent
            // runs. The amber `.calibrationStale` banner is quiet but
            // visible enough to catch.
            let ok = await supabase.recomputeProfileEdgeSpeeds()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recomputeTask = nil
                if !ok {
                    Notify.shared.post(.calibrationStale)
                }
                // If a flush arrived mid-flight or mid-window, fire
                // a trailing recompute. Use a short timer rather than
                // an immediate call so we still coalesce a tail of
                // back-to-back flushes into one trailing call.
                if self.pendingRecomputeAfterFlight {
                    self.pendingRecomputeAfterFlight = false
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(self?.recomputeDebounceSeconds ?? 30))
                        self?.scheduleEdgeSpeedRecompute()
                    }
                }
            }
        }
    }

    // MARK: - Speed helpers (graph-less fallback)

    private static func haversineAvgSpeed(points: [GPXTrackPoint]) -> Double {
        GPXSpeedStats.simpleAverageSpeed(points)
    }

    private static func haversinePeakSpeed(points: [GPXTrackPoint]) -> Double {
        GPXSpeedStats.peakSpeed(points)
    }
}
