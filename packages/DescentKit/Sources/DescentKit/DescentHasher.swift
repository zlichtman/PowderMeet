import Foundation
import MountainCore

/// The identity of a descent: a SHA-256 of its normalized track
/// (`specs/08-ACTIVITY.md` section 2), unique per owner on the server.
///
/// Normalization, in order:
/// 1. Points without a timestamp are dropped and the rest put in time order.
/// 2. The track is resampled to 1 Hz at whole Unix seconds by linear
///    interpolation. Gaps over 90 s are not filled.
/// 3. Coordinates are rounded to 1e-5 degrees and elevations to 1 m.
/// 4. A stationary head and tail are trimmed: leading samples that stay within
///    3e-5 degrees of the first one are dropped except the last of them, and
///    the same from the end.
///
/// The hash covers only time, position and elevation, so the same track read
/// from two files, or re-exported, hashes the same; the source and the
/// provider's statistics do not enter it. Two devices that recorded the same
/// run produce different samples and usually different hashes; the server's
/// time-overlap rule catches those.
///
/// Everything after the interpolation is integer arithmetic, and no
/// trigonometry is involved, so the result is identical on every platform.
public enum DescentHasher {
    /// Bumped if the normalization ever changes, so old and new hashes cannot
    /// be confused.
    static let version = 1
    private static let maximumGapSeconds = 90
    private static let stationaryCells = 3

    struct Sample: Equatable {
        var second: Int
        /// Degrees × 1e5, rounded.
        var lat: Int
        var lon: Int
        /// Metres, rounded; nil when the source has no elevation here.
        var elevation: Int?
    }

    /// 64 lowercase hex characters.
    public static func contentHash(_ descent: Descent) -> String {
        var text = "powdermeet-descent-v\(version)\n"
        for sample in normalizedSamples(descent.points) {
            text += "\(sample.second),\(sample.lat),\(sample.lon),"
            if let elevation = sample.elevation { text += "\(elevation)" }
            text += "\n"
        }
        return SHA256.hex(Data(text.utf8))
    }

    static func normalizedSamples(_ points: [TrackPoint]) -> [Sample] {
        var timed: [(time: Double, point: TrackPoint)] = []
        for point in points {
            guard let timestamp = point.timestamp, point.lat.isFinite, point.lon.isFinite else { continue }
            let time = timestamp.timeIntervalSince1970
            guard time.isFinite, abs(time) < 1e11 else { continue }
            timed.append((time, point))
        }
        // Stable, so equal timestamps keep their order everywhere.
        timed = timed.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
        guard let first = timed.first else { return [] }

        var samples: [Sample] = []
        func append(second: Int, lat: Double, lon: Double, elevation: Double?) {
            guard samples.last?.second != second else { return }
            samples.append(Sample(
                second: second,
                lat: Int((lat * 1e5).rounded()),
                lon: Int((lon * 1e5).rounded()),
                elevation: elevation.flatMap { $0.isFinite ? Int($0.rounded()) : nil }
            ))
        }

        if first.time == first.time.rounded(.up) {
            append(second: Int(first.time), lat: first.point.lat, lon: first.point.lon,
                   elevation: first.point.elevationM)
        }
        for index in 1..<max(1, timed.count) {
            let a = timed[index - 1]
            let b = timed[index]
            let span = b.time - a.time
            guard span > 0 else { continue }
            let from = Int(a.time.rounded(.down)) + 1
            let to = Int(b.time.rounded(.down))
            guard from <= to else { continue }
            if span > Double(maximumGapSeconds) {
                // Do not invent a path across a recording gap; keep only a
                // sample that falls exactly on the later fix.
                if b.time == Double(to) {
                    append(second: to, lat: b.point.lat, lon: b.point.lon, elevation: b.point.elevationM)
                }
                continue
            }
            for second in from...to {
                let t = (Double(second) - a.time) / span
                var elevation: Double?
                if let ea = a.point.elevationM, let eb = b.point.elevationM {
                    elevation = ea + (eb - ea) * t
                }
                append(
                    second: second,
                    lat: a.point.lat + (b.point.lat - a.point.lat) * t,
                    lon: a.point.lon + (b.point.lon - a.point.lon) * t,
                    elevation: elevation
                )
            }
        }
        return trimmed(samples)
    }

    private static func trimmed(_ samples: [Sample]) -> [Sample] {
        guard samples.count > 2 else { return samples }
        func near(_ a: Sample, _ b: Sample) -> Bool {
            abs(a.lat - b.lat) <= stationaryCells && abs(a.lon - b.lon) <= stationaryCells
        }
        var start = 0
        while start + 1 < samples.count, near(samples[start + 1], samples[0]) { start += 1 }
        var end = samples.count - 1
        while end - 1 > start, near(samples[end - 1], samples[samples.count - 1]) { end -= 1 }
        return Array(samples[start...end])
    }
}
