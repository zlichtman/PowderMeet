//
//  GPXSpeedStats.swift
//  PowderMeet
//
//  Single source of truth for turning a raw `[GPXTrackPoint]` track into
//  average / peak ground speed.
//
//  TrailMatcher, ActivityImporter, and LiveRunRecorder each used to carry
//  their own byte-identical copies of this arithmetic — including re-declared
//  pause/ceiling constants — which is exactly how the noise ceiling and the
//  "what counts as moving" rule silently drift between the import path, the
//  live-recording path, and trail matching. They all route through here now.
//

import Foundation

nonisolated enum GPXSpeedStats {
    struct MovementInterval: Sendable, Equatable {
        let startIndex: Int
        let endIndex: Int
        let distanceM: Double
        let durationS: TimeInterval

        var speedMs: Double { distanceM / durationS }
    }

    /// Points below this ground speed are treated as stopped.
    static let pauseSpeedThreshold: Double = 1.0    // m/s
    /// A slow window only counts as a pause once it lasts at least this long —
    /// brief slow patches inside a run (powder turn, traverse) are kept.
    static let pauseMinDuration: TimeInterval = 10  // seconds
    /// Peak-speed sanity ceiling. ~30 m/s ≈ 67 mph; a reading above this from a
    /// recreational phone-GPS track is almost always a loss-of-fix snap to a
    /// far-away coordinate, not a real burst.
    static let peakSpeedCeiling: Double = 30.0      // m/s
    /// A single persisted ski run may not span more than one day. Longer
    /// observations are malformed whole-workout/container data, not one run.
    static let maximumLearningDuration: TimeInterval = 24 * 60 * 60

    /// Moving-average speed in m/s, excluding sustained pauses (below
    /// `pauseSpeedThreshold` for at least `pauseMinDuration`). Keeps idle time
    /// (lift wait, lunch, gear adjust) from dragging the average ski speed down.
    static func movingAverageSpeed(_ points: [GPXTrackPoint]) -> Double {
        let intervals = movingIntervals(points)
        let movingDistance = intervals.reduce(0) { $0 + $1.distanceM }
        let movingTime = intervals.reduce(0) { $0 + $1.durationS }
        return movingTime > 0 ? movingDistance / movingTime : 0
    }

    /// Valid point-to-point intervals after applying the exact same sustained-
    /// pause rule as `movingAverageSpeed`. Edge attribution consumes these so
    /// whole-run and per-edge speed arithmetic cannot drift apart.
    static func movingIntervals(_ points: [GPXTrackPoint]) -> [MovementInterval] {
        guard points.count >= 2 else { return [] }

        var result: [MovementInterval] = []
        result.reserveCapacity(points.count - 1)

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

            let dist = segmentDistance(a, b)
            let segSpeed = dist / dt

            if segSpeed < pauseSpeedThreshold {
                // Look ahead — only skip if the slow window is sustained.
                var pauseEnd = i + 1
                var pauseDuration = dt
                while pauseEnd < points.count - 1 {
                    let na = points[pauseEnd]
                    let nb = points[pauseEnd + 1]
                    guard let nt1 = na.timestamp, let nt2 = nb.timestamp else { break }
                    let nDt = nt2.timeIntervalSince(nt1)
                    guard nDt > 0 else { break }
                    if segmentDistance(na, nb) / nDt >= pauseSpeedThreshold { break }
                    pauseDuration += nDt
                    pauseEnd += 1
                }
                if pauseDuration >= pauseMinDuration {
                    i = pauseEnd
                    continue
                }
            }

            result.append(MovementInterval(
                startIndex: i,
                endIndex: i + 1,
                distanceM: dist,
                durationS: dt
            ))
            i += 1
        }
        return result
    }

    /// Plain time-weighted average over every valid segment — no pause
    /// skipping. Used by the live recorder's graph-less fallback.
    static func simpleAverageSpeed(_ points: [GPXTrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var dist = 0.0
        var dt: TimeInterval = 0
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            guard let t1 = a.timestamp, let t2 = b.timestamp else { continue }
            let segDt = t2.timeIntervalSince(t1)
            guard segDt > 0 else { continue }
            dist += segmentDistance(a, b)
            dt += segDt
        }
        return dt > 0 ? dist / dt : 0
    }

    /// Peak instantaneous speed in m/s. Rolling 3-sample window over per-sample
    /// (haversine-distance / dt) speeds — single-sample peaks aren't trusted
    /// because phone GPS routinely fakes 100+ mph bursts on a 1-sample fix
    /// snap. Samples with abnormal dt (≤ 0 or > 30 s) are skipped; the result
    /// is clamped to `peakSpeedCeiling`.
    static func peakSpeed(_ points: [GPXTrackPoint]) -> Double {
        guard points.count >= 4 else { return 0 }

        var samples: [(dist: Double, dt: TimeInterval)] = []
        samples.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            guard let t1 = a.timestamp, let t2 = b.timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0, dt <= 30 else { continue }
            samples.append((segmentDistance(a, b), dt))
        }
        guard samples.count >= 3 else { return 0 }

        var peak = 0.0
        for i in 2..<samples.count {
            let totalDist = samples[i - 2].dist + samples[i - 1].dist + samples[i].dist
            let totalDt = samples[i - 2].dt + samples[i - 1].dt + samples[i].dt
            guard totalDt > 0 else { continue }
            let s = totalDist / totalDt
            if s > peak { peak = s }
        }
        return min(peak, peakSpeedCeiling)
    }

    private static func segmentDistance(_ a: GPXTrackPoint, _ b: GPXTrackPoint) -> Double {
        haversine(
            from: Coordinate(lat: a.latitude, lon: a.longitude),
            to: Coordinate(lat: b.latitude, lon: b.longitude)
        )
    }
}
