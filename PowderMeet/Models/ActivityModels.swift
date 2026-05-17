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

struct GPXTrack {
    var name: String?
    var points: [GPXTrackPoint]
}

// MARK: - Source enum

/// Where an imported activity came from. Used as the first segment of
/// the dedup hash so the same activity uploaded from two different apps
/// (e.g. Slopes export + Strava export) keeps both rows — the user
/// explicitly asked us not to fuzzy-match across sources.
enum ImportSource: String, Codable, CaseIterable {
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
struct ParsedRunSegment {
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
}

/// Whole-activity envelope produced by every format parser. The importer
/// consumes this single shape — no per-format branching downstream of
/// the parsers.
struct ParsedActivity {
    let source: ImportSource
    /// File-supplied resort name (Slopes carries one; others usually
    /// don't). Used as a fallback for resort identification when the
    /// catalog bbox lookup misses.
    let resortName: String?
    /// SHA256 of the original file bytes — the importer uses this for
    /// whole-file fast-skip dedup before parsing on a re-upload.
    let sourceFileHash: String
    /// Pre-segmented runs. For formats without native lap data, the
    /// segmenter (TrailMatcher.segmentTrack) splits a flat track into
    /// runs by elevation/speed before producing this list.
    let segments: [ParsedRunSegment]
}

// MARK: - Matched Run

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
    let isGroomed: Bool
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

    init(
        edgeId: String?,
        difficulty: RunDifficulty?,
        speed: Double,
        peakSpeed: Double,
        duration: TimeInterval,
        timestamp: Date,
        trailName: String?,
        hasMoguls: Bool,
        isGroomed: Bool,
        isGladed: Bool,
        widthMeters: Double?,
        fallLineExposure: Double?,
        measuredVerticalM: Double? = nil,
        measuredDistanceM: Double? = nil,
        source: ImportSource,
        sourceFileHash: String
    ) {
        self.edgeId = edgeId
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
struct ConditionInference {
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
