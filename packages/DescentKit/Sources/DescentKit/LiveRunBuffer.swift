import Foundation

/// The rolling buffer behind live recording (`specs/08-ACTIVITY.md` section 2):
/// fixes go in as they arrive, and `DescentSegmenter`, the same function
/// imports use, finds the runs in it. A run comes out only once it is closed,
/// so it is never uploaded twice in two lengths:
///
/// - a climb of `closingClimbM` after its end held for `closingClimbFixes`
///   fixes in a row (a lift ride), or
/// - a gap of `DescentSegmenter.hardGapS` without fixes after its end, where
///   the segmenter cuts the track anyway, or
/// - `flush()`, when recording stops or the skier leaves the resort.
///
/// A pause at the bottom of a run, however long, closes nothing: the skier may
/// carry on down, and a pause never splits a run. The buffer is a value, so
/// the recorder can write it to disk after every change and pick up where it
/// left off after the app is relaunched.
public struct LiveRunBuffer: Codable, Sendable, Hashable {
    /// Raw GPS altitude wanders by ±10 m; a lift climbs much more than this.
    public static let closingClimbM = 30.0
    /// Consecutive fixes that must sit `closingClimbM` above the run's bottom.
    static let closingClimbFixes = 3
    /// How often the segmenter runs over the buffer, in seconds of track.
    public static let evaluationIntervalS: TimeInterval = 30
    /// Fixes kept before an emitted run's end, so smoothing has context.
    static let contextS: TimeInterval = 60
    /// Worse fixes than this are not recorded.
    public static let maximumAccuracyM = 50.0
    /// Bounds memory if the segmenter never closes a run (a day of hiking).
    static let maximumPoints = 30_000

    public private(set) var points: [TrackPoint] = []
    /// The end of the last run handed out; nothing that starts before it is
    /// handed out again.
    public private(set) var emittedThrough: Date?
    private var lastEvaluatedAt: Date?

    public init() {}

    public var isEmpty: Bool { points.isEmpty }

    /// Adds a fix. Fixes out of order, repeated within a second, or too
    /// inaccurate are dropped. Returns the runs this fix closed, if it was time
    /// to look.
    public mutating func append(_ point: TrackPoint, accuracyM: Double) -> [Descent] {
        guard let time = point.timestamp, accuracyM >= 0, accuracyM <= Self.maximumAccuracyM else { return [] }
        if let last = points.last?.timestamp, time.timeIntervalSince(last) < 1 { return [] }
        if let emittedThrough, time <= emittedThrough { return [] }
        points.append(point)
        if points.count > Self.maximumPoints {
            points.removeFirst(points.count - Self.maximumPoints * 9 / 10)
        }
        if let lastEvaluatedAt, time.timeIntervalSince(lastEvaluatedAt) < Self.evaluationIntervalS { return [] }
        lastEvaluatedAt = time
        return take(closedOnly: true)
    }

    /// Every run still in the buffer, closed or not, and an empty buffer.
    public mutating func flush() -> [Descent] {
        let runs = take(closedOnly: false)
        points = []
        lastEvaluatedAt = nil
        return runs
    }

    private mutating func take(closedOnly: Bool) -> [Descent] {
        guard points.count >= 2 else { return [] }
        let activity = ParsedActivity(
            source: .live,
            segments: [ParsedSegment(
                number: 0, startTime: points.first?.timestamp, endTime: points.last?.timestamp,
                durationS: nil, points: points
            )]
        )
        var runs: [Descent] = []
        for descent in DescentSegmenter.segments(activity) {
            if let emittedThrough, descent.startedAt < emittedThrough { continue }
            guard !closedOnly || isClosed(descent) else { break }
            runs.append(descent)
            emittedThrough = descent.endedAt
        }
        if let emittedThrough {
            let keepFrom = emittedThrough.addingTimeInterval(-Self.contextS)
            points.removeAll { ($0.timestamp ?? .distantPast) < keepFrom }
        }
        return runs
    }

    private func isClosed(_ descent: Descent) -> Bool {
        let after = points.filter { ($0.timestamp ?? .distantPast) > descent.endedAt }
        guard !after.isEmpty else { return false }
        // One raw altitude glitch climbs as far as a lift; a lift keeps climbing.
        if let bottom = descent.points.last(where: { $0.elevationM != nil })?.elevationM {
            var above = 0
            for height in after.compactMap(\.elevationM) {
                above = height - bottom >= Self.closingClimbM ? above + 1 : 0
                if above >= Self.closingClimbFixes { return true }
            }
        }
        var previous = descent.endedAt
        for point in after {
            guard let time = point.timestamp else { continue }
            if time.timeIntervalSince(previous) >= DescentSegmenter.hardGapS { return true }
            previous = time
        }
        return false
    }
}
