//
//  SkiActivitySegmenter.swift
//  PowderMeet
//
//  Provider-independent normalization and downhill/lift segmentation for
//  activity imports. File-format parsers describe what their containers say;
//  this type decides what physically looks like a ski run.
//

import Foundation

nonisolated enum SkiMotionKind: Sendable, Equatable {
    case downhill
    case uphill
    case stationary
    case unknown
}

nonisolated struct SkiMotionSegment: Sendable {
    let kind: SkiMotionKind
    let points: [GPXTrackPoint]
}

nonisolated enum SkiActivitySegmenter {
    private static let phaseWindowSize = 6
    static let observationWindowSize = 11
    private static let maximumGapSeconds: TimeInterval = 90
    private static let minimumPhaseVerticalRateMS = 0.12
    private static let minimumPhaseVerticalChangeM = 3.0
    private static let maximumUphillGroundSpeedMS = 20.0
    private static let stationarySpeedMS = 0.5
    private static let stationaryWindowSeconds: TimeInterval = 10
    private static let maximumPlausiblePointSpeedMS = 60.0

    /// Normalizes every provider's segment hints into physical downhill runs.
    ///
    /// Slopes actions and genuine FIT/TCX laps remain intact when they contain
    /// one coherent descent. Whole-day laps, GPX track segments, HealthKit
    /// workouts, and legacy Slopes fallbacks are split whenever an ascent or
    /// multiple descents are observed. Pure lift/stationary segments are
    /// discarded. When the source lacks enough altitude/time evidence, the
    /// original segment is retained rather than manufacturing boundaries.
    static func downhillRunSegments(
        from sourceSegments: [ParsedRunSegment]
    ) -> [ParsedRunSegment] {
        var output: [ParsedRunSegment] = []

        for source in sourceSegments {
            let points = normalizedPoints(source.points)

            // Modern Slopes already classified this exact action as a Run.
            // Its smoothed GPS can contain short apparent rises that are not
            // lift boundaries. Preserve the provider boundary while still
            // sanitizing corrupt coordinates and impossible native stats.
            if source.boundary == .authoritativeDownhillRun {
                if let preserved = sanitized(source, points: points) {
                    output.append(preserved)
                }
                continue
            }

            guard points.count >= 2 else {
                if let preserved = sanitized(source, points: points) {
                    output.append(preserved)
                }
                continue
            }

            let motion = motionSegments(points)
            let downhill = motion.filter { $0.kind == .downhill }
            let hasUphill = motion.contains { $0.kind == .uphill }
            let stationaryOnly = !motion.isEmpty
                && motion.allSatisfy { $0.kind == .stationary }
            let uphillOnly = !motion.isEmpty
                && motion.allSatisfy {
                    $0.kind == .uphill || $0.kind == .stationary
                }

            if hasUphill || downhill.count > 1 {
                for candidate in downhill {
                    if let run = synthesizedRun(
                        points: candidate.points,
                        fallback: source
                    ) {
                        output.append(run)
                    }
                }
                continue
            }

            if stationaryOnly || uphillOnly {
                continue
            }

            if let preserved = sanitized(source, points: points) {
                output.append(preserved)
            }
        }

        return output.enumerated().map { index, segment in
            ParsedRunSegment(
                runNumber: index + 1,
                startTime: segment.startTime,
                endTime: segment.endTime,
                durationSeconds: segment.durationSeconds,
                topSpeedMS: segment.topSpeedMS,
                avgSpeedMS: segment.avgSpeedMS,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                points: segment.points,
                boundary: segment.boundary
            )
        }
    }

    /// Shared motion classifier used by imports, TrailMatcher compatibility,
    /// and live recording. Unknown/flat windows remain attached to the current
    /// phase so traverses and lift unload ramps do not fragment a run.
    static func motionSegments(_ rawPoints: [GPXTrackPoint]) -> [SkiMotionSegment] {
        let points = normalizedPoints(rawPoints)
        guard points.count >= 2 else { return [] }

        var output: [SkiMotionSegment] = []
        var group: [GPXTrackPoint] = []
        var currentKind: SkiMotionKind = .unknown
        var chunkStart = 0

        func flush() {
            guard group.count >= 2 else {
                group.removeAll(keepingCapacity: true)
                return
            }
            output.append(SkiMotionSegment(kind: currentKind, points: group))
            group.removeAll(keepingCapacity: true)
        }

        for index in points.indices {
            if index > 0, isHardGap(points[index - 1], points[index]) {
                flush()
                currentKind = .unknown
                chunkStart = index
            }

            let windowStart = max(chunkStart, index - observationWindowSize + 1)
            let observed = classifyWindow(Array(points[windowStart...index]))

            if currentKind == .unknown, observed != .unknown {
                // Reclassify the short warm-up prefix with the first physical
                // signal so the top of a run is not lost.
                currentKind = observed
            } else if observed != .unknown, observed != currentKind {
                flush()
                currentKind = observed
            }
            group.append(points[index])
        }
        flush()
        return output
    }

    static func isUphillWindow(_ points: [GPXTrackPoint]) -> Bool {
        classifyWindow(normalizedPoints(points)) == .uphill
    }

    static func normalizedPoints(_ rawPoints: [GPXTrackPoint]) -> [GPXTrackPoint] {
        var valid = rawPoints.filter {
            $0.latitude.isFinite
                && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
                && ($0.elevation?.isFinite ?? true)
                && ($0.speed?.isFinite ?? true)
        }
        if valid.allSatisfy({ $0.timestamp != nil }) {
            valid.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        }

        var normalized: [GPXTrackPoint] = []
        normalized.reserveCapacity(valid.count)
        for point in valid {
            if let previous = normalized.last {
                if previous.timestamp == point.timestamp,
                   previous.latitude == point.latitude,
                   previous.longitude == point.longitude {
                    continue
                }
                if let earlier = previous.timestamp,
                   let later = point.timestamp {
                    let dt = later.timeIntervalSince(earlier)
                    if dt > 0, dt <= maximumGapSeconds {
                        let speed = pointDistance(previous, point) / dt
                        if speed > maximumPlausiblePointSpeedMS {
                            continue
                        }
                    }
                }
            }
            normalized.append(point)
        }
        return normalized
    }

    static func classifyWindow(_ points: [GPXTrackPoint]) -> SkiMotionKind {
        guard points.count >= 2 else { return .unknown }
        let stationaryDuration = windowDuration(points)
        let stationaryGroundSpeed = stationaryDuration.flatMap { seconds in
            seconds > 0 ? pointDistance(points.first!, points.last!) / seconds : nil
        }

        if let stationaryGroundSpeed,
           let stationaryDuration,
           stationaryDuration >= stationaryWindowSeconds,
           stationaryGroundSpeed < stationarySpeedMS {
            return .stationary
        }

        // Keep phase transitions responsive even though stationarity needs a
        // longer observation window at the normal one-second GPS cadence.
        let phasePoints = Array(points.suffix(phaseWindowSize))
        let duration = windowDuration(phasePoints)
        let groundSpeed = duration.flatMap { seconds in
            seconds > 0
                ? pointDistance(phasePoints.first!, phasePoints.last!) / seconds
                : nil
        }
        let elevations = phasePoints.compactMap(\.elevation)
        guard elevations.count >= 2 else { return .unknown }
        let verticalChange = (elevations.last ?? 0) - (elevations.first ?? 0)
        let verticalRate = duration.flatMap {
            $0 > 0 ? verticalChange / $0 : nil
        }

        let risesEnough = verticalChange >= minimumPhaseVerticalChangeM
            && (verticalRate == nil || verticalRate! >= minimumPhaseVerticalRateMS)
        if risesEnough,
           groundSpeed == nil || groundSpeed! <= maximumUphillGroundSpeedMS {
            return .uphill
        }

        let descendsEnough = verticalChange <= -minimumPhaseVerticalChangeM
            && (verticalRate == nil || verticalRate! <= -minimumPhaseVerticalRateMS)
        if descendsEnough {
            return .downhill
        }
        return .unknown
    }

    private static func sanitized(
        _ source: ParsedRunSegment,
        points: [GPXTrackPoint]
    ) -> ParsedRunSegment? {
        let firstTimestamp = points.first?.timestamp
        let lastTimestamp = points.last?.timestamp
        let start = firstTimestamp ?? source.startTime
        let proposedEnd = lastTimestamp ?? source.endTime
        let end = proposedEnd >= start ? proposedEnd : start
        let pointDuration = end.timeIntervalSince(start)
        let duration = positiveFinite(source.durationSeconds)
            ?? (pointDuration > 0 ? pointDuration : nil)
        guard let duration else { return nil }

        return ParsedRunSegment(
            runNumber: source.runNumber,
            startTime: start,
            endTime: end,
            durationSeconds: duration,
            topSpeedMS: validSpeed(source.topSpeedMS),
            avgSpeedMS: validSpeed(source.avgSpeedMS),
            distanceMeters: validDistance(source.distanceMeters, duration: duration),
            verticalMeters: validVertical(source.verticalMeters),
            points: points,
            boundary: source.boundary
        )
    }

    private static func synthesizedRun(
        points rawPoints: [GPXTrackPoint],
        fallback: ParsedRunSegment
    ) -> ParsedRunSegment? {
        let points = normalizedPoints(rawPoints)
        guard points.count >= 3 else { return nil }
        let start = points.first?.timestamp ?? fallback.startTime
        let endCandidate = points.last?.timestamp ?? fallback.endTime
        let end = endCandidate >= start ? endCandidate : start
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        let speed = GPXSpeedStats.movingAverageSpeed(points)
        guard speed.isFinite, speed >= stationarySpeedMS,
              descentMeters(points) >= minimumPhaseVerticalChangeM else {
            return nil
        }
        return ParsedRunSegment(
            runNumber: 0,
            startTime: start,
            endTime: end,
            durationSeconds: duration,
            topSpeedMS: GPXSpeedStats.peakSpeed(points),
            avgSpeedMS: min(speed, GPXSpeedStats.peakSpeedCeiling),
            distanceMeters: totalDistanceMeters(points),
            verticalMeters: descentMeters(points),
            points: points
        )
    }

    private static func isHardGap(
        _ earlier: GPXTrackPoint,
        _ later: GPXTrackPoint
    ) -> Bool {
        guard let earlierTime = earlier.timestamp,
              let laterTime = later.timestamp else { return false }
        let gap = laterTime.timeIntervalSince(earlierTime)
        return gap <= 0 || gap > maximumGapSeconds
    }

    private static func windowDuration(
        _ points: [GPXTrackPoint]
    ) -> TimeInterval? {
        guard let first = points.first?.timestamp,
              let last = points.last?.timestamp else { return nil }
        let duration = last.timeIntervalSince(first)
        return duration > 0 ? duration : nil
    }

    private static func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func validSpeed(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0,
              value <= GPXSpeedStats.peakSpeedCeiling else { return nil }
        return value
    }

    private static func validDistance(
        _ value: Double?,
        duration: TimeInterval
    ) -> Double? {
        guard let value, value.isFinite, value > 0,
              value <= duration * GPXSpeedStats.peakSpeedCeiling * 1.25 else {
            return nil
        }
        return value
    }

    private static func validVertical(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 5_000 else {
            return nil
        }
        return value
    }

    static func totalDistanceMeters(_ points: [GPXTrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) {
            $0 + pointDistance($1.0, $1.1)
        }
    }

    static func descentMeters(_ points: [GPXTrackPoint]) -> Double {
        let elevations = points.compactMap(\.elevation)
        guard elevations.count >= 2 else { return 0 }
        return zip(elevations, elevations.dropFirst()).reduce(0) {
            let drop = $1.0 - $1.1
            return $0 + (drop > 1 ? drop : 0)
        }
    }

    private static func pointDistance(
        _ lhs: GPXTrackPoint,
        _ rhs: GPXTrackPoint
    ) -> Double {
        haversine(
            from: Coordinate(lat: lhs.latitude, lon: lhs.longitude),
            to: Coordinate(lat: rhs.latitude, lon: rhs.longitude)
        )
    }
}

/// One source of truth for the database uniqueness identity used by both file
/// imports and live recording. Source remains part of the identity on purpose:
/// cross-provider physical dedup needs real paired recordings before shipping.
nonisolated enum ImportedRunIdentity {
    static func dedupHash(for run: MatchedRun, resortID: String) -> String {
        dedupHash(
            source: run.source,
            timestamp: run.timestamp,
            duration: run.duration,
            resortID: resortID,
            edgeID: run.edgeId
        )
    }

    static func dedupHash(
        source: ImportSource,
        timestamp: Date,
        duration: TimeInterval,
        resortID: String,
        edgeID: String?
    ) -> String {
        let startBucket = Int(timestamp.timeIntervalSince1970 / 15)
        if let edgeID {
            return "\(source.rawValue)|\(startBucket)|\(resortID)|\(edgeID)"
        }
        let durationBucket = Int((duration / 10).rounded())
        return "\(source.rawValue)|\(startBucket)|\(resortID)|unmatched|d\(durationBucket)"
    }
}
