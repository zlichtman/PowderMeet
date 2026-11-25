import Foundation
import MountainCore

/// Recognises a ski day that is already in the skier's history, so importing
/// the same day from a second app adds nothing.
///
/// `DescentHasher` only matches a byte-for-byte re-import: a second app
/// re-samples the fixes, rounds the times and cuts the runs at slightly
/// different points, and the hash changes with any of those. What survives
/// every export is when and where the skier was, so two descents are the same
/// run when they cover the same time and the same ground.
public enum DescentDeduplicator {
    /// Two descents are the same run when the time both cover is more than
    /// this share of the shorter one. The shorter one is the measure because
    /// apps disagree most about how much standing at the top belongs to a run.
    public static let minimumSharedShare = 0.6
    /// And when their tracks, compared at the same instants, are typically no
    /// further apart than this. Two phones in one jacket differ by a few
    /// metres; two skiers who rode the same lift do not stay this close.
    public static let maximumMedianSeparationM = 60.0

    /// Share of the shorter descent's duration that both cover, 0...1.
    public static func sharedShare(_ a: Descent, _ b: Descent) -> Double {
        let shared = min(a.endedAt, b.endedAt).timeIntervalSince(max(a.startedAt, b.startedAt))
        let shorter = min(a.endedAt.timeIntervalSince(a.startedAt), b.endedAt.timeIntervalSince(b.startedAt))
        guard shared > 0, shorter > 0 else { return 0 }
        return min(1, shared / shorter)
    }

    public static func isSameDescent(_ a: Descent, _ b: Descent) -> Bool {
        guard sharedShare(a, b) > minimumSharedShare else { return false }
        guard let separation = medianSeparationM(a, b) else {
            // No instants in common to compare (very sparse tracks): the time
            // alone has to decide.
            return true
        }
        return separation <= maximumMedianSeparationM
    }

    /// For each new descent, the index of the existing descent it repeats, or
    /// nil when it is new. `existing` may be the skier's whole history.
    public static func duplicates(of new: [Descent], in existing: [Descent]) -> [Int?] {
        let ordered = existing.indices.sorted { existing[$0].startedAt < existing[$1].startedAt }
        return new.map { candidate in
            for index in ordered {
                let other = existing[index]
                if other.startedAt >= candidate.endedAt { break }
                if other.endedAt <= candidate.startedAt { continue }
                if isSameDescent(candidate, other) { return index }
            }
            return nil
        }
    }

    /// Share of the new descents already present, 0...1. An import is the
    /// same day as one in the history when this is high.
    public static func repeatedShare(of new: [Descent], in existing: [Descent]) -> Double {
        guard !new.isEmpty else { return 0 }
        let found = duplicates(of: new, in: existing).filter { $0 != nil }.count
        return Double(found) / Double(new.count)
    }

    /// Median distance between the two tracks at up to 30 instants spread
    /// over the time they share, each track interpolated to the instant.
    static func medianSeparationM(_ a: Descent, _ b: Descent) -> Double? {
        let start = max(a.startedAt, b.startedAt).timeIntervalSince1970
        let end = min(a.endedAt, b.endedAt).timeIntervalSince1970
        guard end > start else { return nil }
        var distances: [Double] = []
        let steps = 30
        for step in 0...steps {
            let instant = start + (end - start) * Double(step) / Double(steps)
            guard let pa = position(in: a.points, at: instant),
                  let pb = position(in: b.points, at: instant) else { continue }
            distances.append(Geo.haversineM(pa, pb))
        }
        guard distances.count >= 3 else { return nil }
        distances.sort()
        return distances[distances.count / 2]
    }

    /// Where the track was at an instant, or nil when the nearest fixes are
    /// more than 30 s away on either side.
    private static func position(in points: [TrackPoint], at instant: Double) -> Coordinate? {
        var low = 0
        var high = points.count - 1
        guard high >= 1 else { return nil }
        func time(_ index: Int) -> Double { points[index].timestamp?.timeIntervalSince1970 ?? 0 }
        guard instant >= time(low), instant <= time(high) else { return nil }
        while high - low > 1 {
            let middle = (low + high) / 2
            if time(middle) <= instant { low = middle } else { high = middle }
        }
        let span = time(high) - time(low)
        guard span <= 60, instant - time(low) <= 30 || time(high) - instant <= 30 else { return nil }
        let t = span > 0 ? (instant - time(low)) / span : 0
        return Coordinate(
            lon: points[low].lon + (points[high].lon - points[low].lon) * t,
            lat: points[low].lat + (points[high].lat - points[low].lat) * t
        )
    }
}
