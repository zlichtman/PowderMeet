import Foundation
import MountainCore

/// The single place a raw track becomes average and peak ground speed, so the
/// noise ceiling and the "what counts as moving" rule cannot drift between
/// segmentation, live recording and trail matching.
public enum GPXSpeedStats {
    public struct MovementInterval: Sendable, Equatable {
        public let startIndex: Int
        public let endIndex: Int
        public let distanceM: Double
        public let durationS: TimeInterval

        public var speedMS: Double { distanceM / durationS }
    }

    /// Below this ground speed a point is treated as stopped.
    public static let pauseSpeedThreshold = 1.0
    /// A slow window is a pause only once it lasts this long; brief slow
    /// patches inside a run (a powder turn, a traverse) are kept.
    public static let pauseMinDuration: TimeInterval = 10
    /// About 67 mph. A reading above this from a phone track is almost always
    /// a loss-of-fix snap to a far-away coordinate, not a real burst.
    public static let peakSpeedCeiling = 30.0
    /// A single run may not span more than a day; longer observations are
    /// malformed whole-workout data.
    public static let maximumLearningDuration: TimeInterval = 24 * 60 * 60

    /// Average speed in m/s over `movingIntervals`: sustained pauses (a lift
    /// wait, lunch, a gear adjustment) do not drag it down.
    public static func movingAverageSpeed(_ points: [TrackPoint]) -> Double {
        let intervals = movingIntervals(points)
        let distance = intervals.reduce(0) { $0 + $1.distanceM }
        let time = intervals.reduce(0) { $0 + $1.durationS }
        return time > 0 ? distance / time : 0
    }

    /// Point-to-point intervals that survive the sustained-pause rule. Edge
    /// attribution consumes these, so whole-run and per-edge arithmetic agree.
    public static func movingIntervals(_ points: [TrackPoint]) -> [MovementInterval] {
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
            let distance = Geo.haversineM(a.coordinate, b.coordinate)

            if distance / dt < pauseSpeedThreshold {
                // Look ahead: skip only when the slow window is sustained.
                var pauseEnd = i + 1
                var pauseDuration = dt
                while pauseEnd < points.count - 1 {
                    let na = points[pauseEnd]
                    let nb = points[pauseEnd + 1]
                    guard let nt1 = na.timestamp, let nt2 = nb.timestamp else { break }
                    let nDt = nt2.timeIntervalSince(nt1)
                    guard nDt > 0 else { break }
                    if Geo.haversineM(na.coordinate, nb.coordinate) / nDt >= pauseSpeedThreshold { break }
                    pauseDuration += nDt
                    pauseEnd += 1
                }
                if pauseDuration >= pauseMinDuration {
                    i = pauseEnd
                    continue
                }
            }

            result.append(MovementInterval(startIndex: i, endIndex: i + 1, distanceM: distance, durationS: dt))
            i += 1
        }
        return result
    }

    /// Time-weighted average over every valid interval, pauses included.
    public static func simpleAverageSpeed(_ points: [TrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var distance = 0.0
        var time: TimeInterval = 0
        for i in 1..<points.count {
            guard let t1 = points[i - 1].timestamp, let t2 = points[i].timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0 else { continue }
            distance += Geo.haversineM(points[i - 1].coordinate, points[i].coordinate)
            time += dt
        }
        return time > 0 ? distance / time : 0
    }

    /// Seconds a phone-reported speed must be held to count toward top speed.
    public static let heldSpeedWindow: TimeInterval = 3
    /// Window for the straight-line fallback when a file has no speed values.
    public static let heldDistanceWindow: TimeInterval = 4
    /// How far above the held speed a speed the file itself claims may be
    /// before it is rejected as a spike.
    public static let claimedSpeedTolerance = 3.0

    /// A run's top speed in m/s: the highest speed held for at least
    /// `heldSpeedWindow`, that is the maximum over every window of the lowest
    /// phone-reported speed inside it. A single-fix spike cannot raise it,
    /// whereas the old three-interval distance average let a fix snap through
    /// (a run whose phone never reported more than 10.4 m/s showed 30 m/s).
    /// Files with no speed values use straight-line distance over
    /// `heldDistanceWindow` instead, and a window only counts when the window
    /// one fix later agrees, because a lone fix snap sits at the edge of
    /// every window that touches it. Never above `peakSpeedCeiling`.
    public static func peakSpeed(_ points: [TrackPoint]) -> Double {
        let timed = points.compactMap { point in point.timestamp.map { (point: point, time: $0) } }
        guard timed.count >= 2 else { return 0 }
        let hasSpeed = timed.contains { ($0.point.speedMS ?? 0) > 0 }
        let window = hasSpeed ? heldSpeedWindow : heldDistanceWindow

        var speeds = [Double?](repeating: nil, count: timed.count)
        var end = 0
        for start in 0..<(timed.count - 1) {
            end = max(end, start + 1)
            while end < timed.count - 1, timed[end].time.timeIntervalSince(timed[start].time) < window { end += 1 }
            let span = timed[end].time.timeIntervalSince(timed[start].time)
            guard span >= window else { continue }
            // A hole in the fixes means the speed was not observed there.
            guard (start..<end).allSatisfy({ timed[$0 + 1].time.timeIntervalSince(timed[$0].time) <= window }) else {
                continue
            }
            if hasSpeed {
                let inside = timed[start...end].map(\.point.speedMS)
                guard inside.allSatisfy({ ($0 ?? -1) >= 0 && $0!.isFinite }) else { continue }
                speeds[start] = inside.compactMap { $0 }.min()
            } else {
                speeds[start] = Geo.haversineM(timed[start].point.coordinate, timed[end].point.coordinate) / span
            }
        }

        var peak = 0.0
        for start in speeds.indices {
            guard let speed = speeds[start] else { continue }
            if hasSpeed {
                peak = max(peak, speed)
            } else if start + 1 < speeds.count, let next = speeds[start + 1] {
                peak = max(peak, min(speed, next))
            }
        }
        return min(peak, peakSpeedCeiling)
    }

    /// The top speed to store for a run whose file also states one: the
    /// file's figure when it is no more than `claimedSpeedTolerance` above the
    /// speed the track holds, otherwise the held speed. Nil when neither is
    /// usable.
    public static func topSpeed(points: [TrackPoint], claimed: Double?) -> Double? {
        let held = peakSpeed(points)
        if let claimed, claimed.isFinite, claimed > 0, claimed <= peakSpeedCeiling,
           claimed <= held + claimedSpeedTolerance {
            return claimed
        }
        return held > 0 ? held : nil
    }
}
