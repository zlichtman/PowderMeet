//
//  ActivityModels.swift
//  PowderMeet
//
//  Data types for the GPS activity import pipeline.
//

import Foundation

// MARK: - Track Point

nonisolated struct GPXTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date?
    let speed: Double?  // m/s — device-reported if available (Garmin FIT/TCX)

    init(latitude: Double, longitude: Double, elevation: Double? = nil, timestamp: Date? = nil, speed: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
        self.speed = speed
    }
}

nonisolated struct GPXTrack {
    var name: String?
    var points: [GPXTrackPoint]
}

// MARK: - Source enum

/// Where an imported activity came from. Used as the first segment of
/// the dedup hash so the same activity uploaded from two different apps
/// (e.g. Slopes export + Strava export) keeps both rows — the user
/// explicitly asked us not to fuzzy-match across sources.
nonisolated enum ImportSource: String, Codable, CaseIterable {
    case slopes
    case gpx
    case tcx
    case fit
    /// Captured live in-app via `LiveRunRecorder` — passive run/lift
    /// segmentation from CoreLocation fixes while the app is open and
    /// `liveRecordingEnabled` is true on the user's profile. Same
    /// downstream contract as a Slopes import (writes `imported_runs`,
    /// triggers `recompute_profile_edge_speeds`).
    case live
    /// Pulled from Apple Health via `HKWorkoutActivityType.downhillSkiing`
    /// or `.snowboarding`. Acts as the omnibus integration: HealthKit
    /// catches Slopes, Apple Watch native workouts, and any third-party
    /// app (Strava / Garmin Connect / Trace Snow) that writes workouts
    /// to Health. Each workout becomes one ParsedActivity; per-workout
    /// `HKWorkoutRoute` samples drive trail matching.
    case healthKit = "healthkit"
    /// Restored from a `.powdermeet` backup. Replaces whatever the
    /// original source was so the log surfaces the red POWDERMEET
    /// tag — gives users a clear signal that "these came back from
    /// a backup, not a fresh import."
    case powdermeet

    /// Display label for the imported-runs viewer badge.
    var displayName: String {
        switch self {
        case .slopes:     return "SLOPES"
        case .gpx:        return "GPX"         // Strava, generic
        case .tcx:        return "TCX"         // Garmin Connect / Training Center
        case .fit:        return "FIT"         // Garmin native
        case .live:       return "LIVE"        // captured in-app
        case .healthKit:  return "HEALTH"      // Apple Health workouts
        case .powdermeet: return "POWDERMEET"  // restored backup
        }
    }
}

// MARK: - Parsed Activity (unified envelope from any format)

/// One run extracted from an activity file. When the source format
/// already encoded per-run stats (Slopes Metadata.xml, TCX `<Lap>`,
/// FIT `mesg_num=21`), those native values populate the optional
/// stats fields and the importer carries them straight through —
/// no haversine re-derivation. When the source had no native lap
/// concept (raw GPX), stats stay nil and the importer computes from
/// `points`.
/// Describes how much authority the source container has over a segment's
/// boundaries. Most formats expose tracks/laps that are only hints and still
/// need physical downhill reconstruction. A modern Slopes `Run` action is an
/// explicit provider-classified ski run, so its boundary must survive GPS
/// elevation noise intact.
nonisolated enum ActivitySegmentBoundary: Sendable, Equatable {
    case providerHint
    case authoritativeDownhillRun
}

nonisolated struct ParsedRunSegment {
    /// 1-based per-activity run index. 0 means "couldn't determine"
    /// (e.g., a GPX with no segments — single synthetic run).
    let runNumber: Int
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    // Native per-run stats — present only when the source format
    // recorded them. Populated from:
    //   - Slopes:  <Action type="Run"> attributes
    //   - TCX:     <Lap> child elements (TotalTimeSeconds, MaximumSpeed, …)
    //   - FIT:     lap message fields (max_speed, total_distance, …)
    //   - GPX:     usually nil — Strava/generic GPX has no lap concept
    let topSpeedMS: Double?
    let avgSpeedMS: Double?
    let distanceMeters: Double?
    let verticalMeters: Double?
    /// Raw GPS fixes that fall inside [startTime, endTime]. The importer
    /// uses these for graph-edge matching (best-fit polyline) regardless
    /// of whether the per-run stats above are present.
    let points: [GPXTrackPoint]
    let boundary: ActivitySegmentBoundary

    init(
        runNumber: Int,
        startTime: Date,
        endTime: Date,
        durationSeconds: Double,
        topSpeedMS: Double?,
        avgSpeedMS: Double?,
        distanceMeters: Double?,
        verticalMeters: Double?,
        points: [GPXTrackPoint],
        boundary: ActivitySegmentBoundary = .providerHint
    ) {
        self.runNumber = runNumber
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.topSpeedMS = topSpeedMS
        self.avgSpeedMS = avgSpeedMS
        self.distanceMeters = distanceMeters
        self.verticalMeters = verticalMeters
        self.points = points
        self.boundary = boundary
    }
}

/// Whole-activity envelope produced by every format parser. The importer
/// consumes this single shape — no per-format branching downstream of
/// the parsers.
nonisolated struct ParsedActivity {
    let source: ImportSource
    /// File-supplied resort name (Slopes carries one; others usually
    /// don't). Used as a fallback for resort identification when the
    /// catalog bbox lookup misses.
    let resortName: String?
    /// Stable raw-source identity. File imports use the original SHA256;
    /// synthesized sources use their own deterministic observation identity.
    /// Per-run idempotency is enforced later by `ImportedRunIdentity`.
    let sourceFileHash: String
    /// Provider-supplied run/lap/track hints. The shared
    /// `SkiActivitySegmenter` normalizes these into physical downhill runs
    /// after parsing, regardless of source format or graph availability.
    let segments: [ParsedRunSegment]
}

// MARK: - Matched Run

/// One trustworthy pace measurement for one stable graph edge inside a
/// physical run. A run may cross several edges, but its whole-run average must
/// never be copied onto all of them: each row here is derived only from GPS
/// intervals whose endpoints project to the same matched edge. Conditions are
/// carried per edge because surface flags may differ inside one run sequence.
nonisolated struct EdgePaceObservation: Codable, Sendable, Equatable {
    let edgeId: String
    let conditionsFp: String
    let speedMs: Double
    let peakSpeedMs: Double
    let durationS: Double
    let distanceM: Double

    init(
        edgeId: String,
        conditionsFp: String = ConditionsFingerprint.defaultBucket,
        speedMs: Double,
        peakSpeedMs: Double,
        durationS: Double,
        distanceM: Double
    ) {
        self.edgeId = edgeId
        self.conditionsFp = conditionsFp
        self.speedMs = speedMs
        self.peakSpeedMs = peakSpeedMs
        self.durationS = durationS
        self.distanceM = distanceM
    }

    func withConditions(_ fingerprint: String) -> EdgePaceObservation {
        EdgePaceObservation(
            edgeId: edgeId,
            conditionsFp: fingerprint,
            speedMs: speedMs,
            peakSpeedMs: peakSpeedMs,
            durationS: durationS,
            distanceM: distanceM
        )
    }

    enum CodingKeys: String, CodingKey {
        case edgeId = "edge_id"
        case conditionsFp = "conditions_fp"
        case speedMs = "speed_ms"
        case peakSpeedMs = "peak_speed_ms"
        case durationS = "duration_s"
        case distanceM = "distance_m"
    }
}

/// A run extracted from an activity file, optionally enriched with
/// graph-edge metadata when a match was found. `edgeId` and
/// `difficulty` are nil when the run couldn't be matched (resort
/// outside the catalog, no graph available, line missed the matcher's
/// bearing/distance threshold). The user contract is "X runs in your
/// file → X runs on your profile" — the importer persists every run
/// regardless of match status.
nonisolated struct MatchedRun {
    /// Nil when no graph edge matched. Persisted as NULL.
    let edgeId: String?
    /// Immutable dataset identity used while matching this observation.
    /// Nil only when no mountain dataset was available.
    let datasetVersion: String?
    /// Ordered, directed, contiguous stable segment IDs traversed by the
    /// recorded run. Empty for display-only or unmatched guesses.
    let matchedSegmentIDs: [String]
    /// Edge-local pace measurements. Multi-edge runs only train routing when
    /// these measurements exist; the whole-run average is never fanned out.
    let edgePaceObservations: [EdgePaceObservation]
    /// 0...1 match confidence used by the persisted learning gate (>= 0.75).
    /// New route-only matches store zero to exclude legacy server averaging;
    /// their method preserves the distinction from an unmatched activity.
    let matchConfidence: Double
    /// `polyline_sequence`, `polyline_sequence_no_pace`, or a naming-only /
    /// unmatched method. Route-only matches retain topology, not timed pace.
    let matchMethod: String
    /// Ski known to have been selected when the observation was recorded.
    /// Historical imports remain nil unless their source provides trustworthy
    /// equipment provenance; today's preferred ski is not retroactive.
    let equipmentIDAtActivity: UUID?
    /// Nil when no graph match (difficulty came from the matched edge).
    let difficulty: RunDifficulty?
    let speed: Double          // m/s — moving average across the run (pauses excluded)
    let peakSpeed: Double      // m/s — peak instantaneous (3-sample smoothed, GPS-noise-capped)
    let duration: TimeInterval // seconds
    let timestamp: Date
    let trailName: String?
    // Trail condition flags from the matched edge — defaults are 'false'
    // when no match. Inference code skips nil-edge runs so defaults don't
    // tilt the ratios.
    let hasMoguls: Bool
    /// Tri-state from the matched graph. Unknown grooming must not be treated
    /// as ungroomed when learning condition preferences.
    let isGroomed: Bool?
    let isGladed: Bool
    // Edge geometry attributes for tolerance inference (Phase 3.7).
    let widthMeters: Double?
    let fallLineExposure: Double?
    // Source-measured overrides — when the format recorded them, prefer
    // these over graph-edge nominals. A single run can span multiple
    // graph edges, so the edge's verticalDrop / lengthMeters can over-
    // or undershoot the actual descended line.
    let measuredVerticalM: Double?
    let measuredDistanceM: Double?
    // Provenance — used to build the dedup hash and badge in the UI.
    let source: ImportSource
    let sourceFileHash: String
    /// Stable identity supplied by the raw source. For file imports this is
    /// the file SHA; live observations use their recorder-generated ID.
    let rawSourceIdentity: String

    var isLearningEligible: Bool {
        guard let edgeId, !edgeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let datasetVersion,
              !datasetVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !matchedSegmentIDs.isEmpty,
              matchedSegmentIDs.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return false
        }
        return matchConfidence.isFinite
            && matchConfidence >= 0.75
            && speed.isFinite
            && speed > 0
            && speed <= GPXSpeedStats.peakSpeedCeiling
            && duration.isFinite
            && duration > 0
            && duration <= GPXSpeedStats.maximumLearningDuration
    }

    /// Broad learning needs a measured forward pace on exactly one accepted
    /// edge. Raw provider summaries remain activity history, not a fallback
    /// for missing, ambiguous, or malformed edge observations.
    var profileCalibrationSpeed: Double? {
        guard isLearningEligible, difficulty != nil,
              matchedSegmentIDs.count == 1,
              matchedSegmentIDs.first == edgeId,
              edgePaceObservations.count == 1,
              let observation = edgePaceObservations.first,
              observation.edgeId == edgeId,
              observation.speedMs.isFinite, observation.speedMs > 0,
              observation.speedMs <= GPXSpeedStats.peakSpeedCeiling,
              observation.peakSpeedMs.isFinite,
              observation.peakSpeedMs >= observation.speedMs,
              observation.peakSpeedMs <= GPXSpeedStats.peakSpeedCeiling,
              observation.durationS.isFinite, observation.durationS >= 5,
              observation.durationS <= duration + 0.001,
              observation.distanceM.isFinite, observation.distanceM >= 15 else {
            return nil
        }
        let measuredSpeed = observation.distanceM / observation.durationS
        guard abs(measuredSpeed - observation.speedMs)
                <= max(0.000001, observation.speedMs * 0.000001) else { return nil }
        return observation.speedMs
    }

    var isProfileCalibrationEligible: Bool {
        profileCalibrationSpeed != nil
    }

    init(
        edgeId: String?,
        datasetVersion: String? = nil,
        matchedSegmentIDs: [String] = [],
        edgePaceObservations: [EdgePaceObservation] = [],
        matchConfidence: Double = 0,
        matchMethod: String = "unmatched",
        equipmentIDAtActivity: UUID? = nil,
        difficulty: RunDifficulty?,
        speed: Double,
        peakSpeed: Double,
        duration: TimeInterval,
        timestamp: Date,
        trailName: String?,
        hasMoguls: Bool,
        isGroomed: Bool?,
        isGladed: Bool,
        widthMeters: Double?,
        fallLineExposure: Double?,
        measuredVerticalM: Double? = nil,
        measuredDistanceM: Double? = nil,
        source: ImportSource,
        sourceFileHash: String,
        rawSourceIdentity: String? = nil
    ) {
        self.edgeId = edgeId
        self.datasetVersion = datasetVersion
        self.matchedSegmentIDs = matchedSegmentIDs
        self.edgePaceObservations = edgePaceObservations
        self.matchConfidence = matchConfidence
        self.matchMethod = matchMethod
        self.equipmentIDAtActivity = equipmentIDAtActivity
        self.difficulty = difficulty
        self.speed = speed
        self.peakSpeed = peakSpeed
        self.duration = duration
        self.timestamp = timestamp
        self.trailName = trailName
        self.hasMoguls = hasMoguls
        self.isGroomed = isGroomed
        self.isGladed = isGladed
        self.widthMeters = widthMeters
        self.fallLineExposure = fallLineExposure
        self.measuredVerticalM = measuredVerticalM
        self.measuredDistanceM = measuredDistanceM
        self.source = source
        self.sourceFileHash = sourceFileHash
        self.rawSourceIdentity = rawSourceIdentity ?? sourceFileHash
    }
}

// MARK: - Import Result

nonisolated struct ImportResult {
    let resortId: String?
    let runs: [MatchedRun]
    let averageSpeeds: [RunDifficulty: Double]
    let conditionInference: ConditionInference?
    /// Number of rows actually persisted in this batch (legacy callers
    /// peeking at this can show "Imported N runs"). 0 when the file was
    /// a duplicate.
    let runCountImported: Int

    init(
        resortId: String?,
        runs: [MatchedRun],
        averageSpeeds: [RunDifficulty: Double],
        conditionInference: ConditionInference?,
        runCountImported: Int = 0
    ) {
        self.resortId = resortId
        self.runs = runs
        self.averageSpeeds = averageSpeeds
        self.conditionInference = conditionInference
        self.runCountImported = runCountImported
    }
}

/// Inferred condition preferences from comparing speeds on condition vs. non-condition trails.
nonisolated struct ConditionInference {
    let mogulRatio: Double?     // speed on moguls / speed on non-mogul (same difficulty)
    let ungroomedRatio: Double? // speed on ungroomed / speed on groomed (same difficulty)
    let gladedRatio: Double?    // speed on gladed / speed on non-gladed (same difficulty)
    let narrowRatio: Double?    // speed on narrow (<12m) / speed on wide (≥20m), same difficulty
    let exposureRatio: Double?  // speed on high-exposure (>0.7) / low-exposure (<0.3), same difficulty

    // MARK: - Phase 3 continuous tolerances
    //
    // These feed directly into the `mogulTolerance` / `exposureTolerance` /
    // `narrowTrailTolerance` profile fields. Nil if the activity didn't touch
    // enough varied terrain to infer reliably.
    var inferredMogulTolerance: Double? { mogulRatio }
    var inferredUngroomedTolerance: Double? { ungroomedRatio }
    var inferredGladedTolerance: Double? { gladedRatio }
    var inferredNarrowTolerance: Double? { narrowRatio }
    var inferredExposureTolerance: Double? { exposureRatio }
}
