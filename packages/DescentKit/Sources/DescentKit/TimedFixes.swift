import Foundation

/// A track's timed fixes in time order, cut into the windows of a provider's
/// run list (Slopes actions, Ski Tracks segments).
struct TimedFixes {
    /// Real run lists do not overlap, so their windows together hold each fix
    /// about once. A list whose windows hold the track many times over is
    /// damaged or hostile, and slicing it would copy the track once per run.
    static let maximumSlicedShare = 2

    private let times: [Date]
    private let points: [TrackPoint]

    init(_ track: [TrackPoint]) {
        let timed = track
            .compactMap { point in point.timestamp.map { (time: $0, point: point) } }
            .sorted { $0.time < $1.time }
        times = timed.map(\.time)
        points = timed.map(\.point)
    }

    /// The fixes inside each `[start, end]`, inclusive at both ends because
    /// run boundaries sit at fix granularity. Each window is found by binary
    /// search, so a long list costs a log per run, not a pass over the track.
    func slices(_ windows: [(start: Date, end: Date)]) throws(ActivityParseError) -> [[TrackPoint]] {
        let ranges = windows.map { window -> Range<Int> in
            let lower = firstIndex { $0 >= window.start }
            return lower..<max(lower, firstIndex { $0 > window.end })
        }
        // Shared boundary fixes let adjacent windows each hold one fix twice.
        let allowed = Self.maximumSlicedShare * (points.count + windows.count)
        guard ranges.reduce(0, { $0 + $1.count }) <= allowed else {
            throw .malformed("the run list covers the track \(Self.maximumSlicedShare) times over or more")
        }
        return ranges.map { Array(points[$0]) }
    }

    /// The first index whose time passes `test`, which must be false then true
    /// along the sorted times.
    private func firstIndex(where test: (Date) -> Bool) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if test(times[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
