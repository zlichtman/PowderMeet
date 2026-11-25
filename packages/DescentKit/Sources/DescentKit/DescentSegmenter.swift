import Foundation
import MountainCore

/// Finds the ski runs in a recording, for imports and for live recording
/// (`specs/08-ACTIVITY.md` section 2). Parsers describe what their containers
/// say; this decides what physically is a ski run.
///
/// The method, in order:
/// 1. Points are cleaned (`normalizedPoints`) and missing elevations filled by
///    interpolation in time.
/// 2. The track is cut where the recorder lost the skier: a gap over ten
///    minutes, or over 90 s in which they moved more than 300 m.
/// 3. Elevation is smoothed over ±8 s and walked with a 20 m hysteresis, which
///    yields alternating climbs and descents. A pause never splits a descent,
///    because standing still does not climb 20 m; a lift always does.
/// 4. Each descent is trimmed to where the skier is actually moving and then
///    classified. A drive (fast on a shallow grade), a lift or gondola ridden
///    down (slow, steady, straight), a walk and GPS drift are not runs.
///
/// A provider's own run list (Slopes, Ski Tracks) is kept wherever the track
/// agrees with it. A listed run that is really a drive or a download is
/// dropped, one that hides a lift ride between laps is replaced by the laps,
/// and clear runs the provider filed under a lift are recovered.
///
/// The constants were tuned on the Slopes days in the test corpus, using
/// Slopes' run lists as the reference; `CorpusTests` holds the result.
public enum DescentSegmenter {
    // MARK: Tuning

    static let maximumPlausiblePointSpeedMS = 60.0
    static let spikeCheckMaximumGapS: TimeInterval = 90
    static let hardGapS: TimeInterval = 600
    static let movedGapS: TimeInterval = 90
    static let movedGapDistanceM = 300.0
    static let smoothingHalfWindowS: TimeInterval = 8
    static let reversalM = 20.0
    static let trimMinimumM = 3.0
    static let trimMaximumM = 10.0
    static let trimFraction = 0.03
    static let activeWindowS: TimeInterval = 20
    static let activeSpeedMS = 1.5
    /// A stop this long may separate a run from a drive in one descent.
    static let partingStopS: TimeInterval = 60
    static let minimumVerticalM = 15.0
    static let minimumDurationS: TimeInterval = 15
    static let minimumDistanceM = 60.0
    static let minimumFastSpeedMS = 3.0
    static let vehicleMaximumGrade = 0.07
    static let vehicleMinimumSpeedMS = 9.0
    static let minimumGrade = 0.03
    static let liftMaximumSpeedMS = 8.0
    static let liftStraightness = 0.93
    static let liftSpeedSpread = 1.15
    static let liftVeryStraight = 0.97
    static let liftVeryStraightSpread = 1.35
    static let liftBentStraightness = 0.8
    static let liftBentSpread = 1.12
    static let liftBentMinimumDurationS: TimeInterval = 180
    static let vehicleLongDistanceM = 6_000.0
    static let vehicleLongSpeedMS = 12.0
    static let vehicleFastMaximumGrade = 0.10
    /// A climb this large between two descents is a lift ride.
    static let liftClimbM = 60.0
    static let recoveredMinimumVerticalM = 75.0
    static let recoveredMaximumStraightness = 0.9
    static let recoveredMinimumGrade = 0.08
    static let recoveredMinimumFastSpeedMS = 6.0

    // MARK: Result

    /// Why a descending stretch of track is not a ski run.
    public enum Rejection: String, Sendable, Hashable, CaseIterable {
        /// Under 15 m of vertical, 15 s or 60 m: noise, not a run.
        case tooSmall
        /// Never faster than walking pace.
        case tooSlow
        /// Fast over a shallow grade: a car or a bus.
        case vehicle
        /// Almost no grade.
        case flat
        /// Slow, steady and straight: a lift or gondola ridden downhill.
        case liftDownhill
    }

    public struct Outcome: Sendable {
        public var descents: [Descent] = []
        /// Descending stretches that were not runs, by reason.
        public var rejected: [Rejection: Int] = [:]
        /// Runs in the provider's list that the track shows are not ski runs.
        public var providerRunsDropped = 0
        /// Provider runs replaced by the laps they contained.
        public var providerRunsSplit = 0
        /// Runs found outside the provider's list.
        public var providerRunsRecovered = 0
        /// Fixes dropped as corrupt, repeated or impossible.
        public var discardedPoints = 0
        /// Fixes with no timestamp, which cannot be placed in a run.
        public var untimedPoints = 0
        /// Share of fixes whose elevation had to be interpolated, 0...1.
        public var interpolatedElevationShare = 0.0
        /// No usable elevation anywhere, so runs could not be found physically.
        public var elevationMissing = false
        public var timedPointCount = 0
    }

    // MARK: Entry points

    /// The physical descents in an activity, in time order.
    public static func segments(_ activity: ParsedActivity) -> [Descent] {
        analyze(activity).descents
    }

    public static func analyze(_ activity: ParsedActivity) -> Outcome {
        var outcome = Outcome()
        let providerRuns = activity.segments.filter { $0.boundary == .authoritativeDownhillRun }
        let allPoints: [TrackPoint]
        if !activity.fullTrack.isEmpty {
            allPoints = activity.fullTrack
        } else {
            allPoints = activity.segments.flatMap(\.points)
        }

        let prepared = prepare(allPoints, into: &outcome)
        let detected = prepared.map { detect($0) } ?? []
        if prepared == nil, outcome.timedPointCount >= 2 { outcome.elevationMissing = true }
        for candidate in detected {
            if let rejection = candidate.rejection { outcome.rejected[rejection, default: 0] += 1 }
        }
        let detectedRuns = detected.filter { $0.rejection == nil }

        var runs: [(segment: ParsedSegment, measured: Candidate?)] = []
        if providerRuns.isEmpty {
            runs = detectedRuns.map { (segment(from: $0), $0) }
        } else {
            var used = Set<Int>()
            for provider in providerRuns {
                let points = normalizedPoints(provider.points).filter { $0.timestamp != nil }
                guard let start = points.first?.timestamp ?? provider.startTime,
                      let end = points.last?.timestamp ?? provider.endTime else { continue }
                let inside = detectedRuns.indices.filter { index in
                    let run = detectedRuns[index]
                    return overlap(run.start, run.end, start, end) >= 0.5 * run.end.timeIntervalSince(run.start)
                }
                let whole = prepare(points).flatMap { measure($0) }
                let isNotARun = whole?.rejection == .vehicle || whole?.rejection == .liftDownhill
                let hidesALift = zip(inside, inside.dropFirst()).contains { earlier, later in
                    detectedRuns[later].topM - detectedRuns[earlier].bottomM >= liftClimbM
                }
                if prepared != nil, isNotARun || hidesALift {
                    if isNotARun, inside.isEmpty {
                        outcome.providerRunsDropped += 1
                    } else {
                        outcome.providerRunsSplit += 1
                    }
                    for index in inside where !used.contains(index) {
                        runs.append((segment(from: detectedRuns[index]), detectedRuns[index]))
                    }
                } else if let prepared, let firstInside = inside.first, let lastInside = inside.last,
                          let trimmed = stretch(
                              of: prepared, from: detectedRuns[firstInside].start, to: detectedRuns[lastInside].end
                          ) {
                    // The provider says this is one run; the track says where
                    // the skiing in it starts and stops. Using the measured
                    // ends gives the same descent whichever app the day comes
                    // from.
                    var merged = trimmed
                    merged.verticalM = max(
                        trimmed.verticalM, inside.reduce(0) { $0 + detectedRuns[$1].verticalM }
                    )
                    runs.append((segment(from: merged), merged))
                } else if let kept = sanitized(provider, points: points) {
                    runs.append((kept, nil))
                }
                used.formUnion(inside)
                // Anything else that mostly lies in this provider run is spoken for.
                for index in detectedRuns.indices where !used.contains(index) {
                    let run = detectedRuns[index]
                    if overlap(run.start, run.end, start, end) >= 0.2 * run.end.timeIntervalSince(run.start) {
                        used.insert(index)
                    }
                }
            }
            for index in detectedRuns.indices where !used.contains(index) {
                let run = detectedRuns[index]
                guard run.verticalM >= recoveredMinimumVerticalM, run.grade >= recoveredMinimumGrade,
                      run.fastSpeedMS >= recoveredMinimumFastSpeedMS,
                      run.straightness < recoveredMaximumStraightness else { continue }
                outcome.providerRunsRecovered += 1
                runs.append((segment(from: run), run))
            }
        }

        outcome.descents = runs.compactMap { run -> Descent? in
            let points = run.segment.points.filter { $0.timestamp != nil }
            guard points.count >= 2, let start = points.first?.timestamp,
                  let end = points.last?.timestamp, end > start else { return nil }
            return Descent(
                source: activity.source, startedAt: start, endedAt: end, points: points,
                stats: DescentStats(
                    topSpeedMS: run.segment.topSpeedMS, avgSpeedMS: run.segment.avgSpeedMS,
                    distanceM: run.segment.distanceM, verticalM: run.segment.verticalM
                )
            )
        }.sorted { $0.startedAt < $1.startedAt }
        return outcome
    }

    // MARK: Cleaning

    /// Drops non-finite and out-of-range samples, orders a fully timed track
    /// by time, and removes repeats, fixes that go back in time and fixes that
    /// imply more than 60 m/s from their predecessor.
    public static func normalizedPoints(_ rawPoints: [TrackPoint]) -> [TrackPoint] {
        var valid = rawPoints.filter {
            $0.lat.isFinite && $0.lon.isFinite
                && (-90...90).contains($0.lat) && (-180...180).contains($0.lon)
                && !($0.lat == 0 && $0.lon == 0)
                && ($0.elevationM?.isFinite ?? true) && ($0.speedMS?.isFinite ?? true)
        }
        // A height no skier can be at is a logger's placeholder: the position
        // still counts, the height is filled in like a missing one.
        for index in valid.indices {
            if let height = valid[index].elevationM, !plausibleElevationM.contains(height) {
                valid[index].elevationM = nil
            }
        }
        let fullyTimed = valid.allSatisfy { $0.timestamp != nil }
        if fullyTimed {
            // Stable: equal timestamps keep file order on every platform.
            valid = valid.enumerated().sorted { a, b in
                let ta = a.element.timestamp ?? .distantPast
                let tb = b.element.timestamp ?? .distantPast
                return ta != tb ? ta < tb : a.offset < b.offset
            }.map(\.element)
        }

        var normalized: [TrackPoint] = []
        normalized.reserveCapacity(valid.count)
        // A fix kept without a speed check (the first, or the first after a
        // gap) may itself be the bad one: a cold start a few km off. Every
        // good fix after it would then fail against it for 90 s. Fixes that
        // fail against such an anchor but agree with one another replace it.
        var anchorIsUnchecked = false
        var rejected: [TrackPoint] = []
        for point in valid {
            var checked = false
            if let previous = normalized.last {
                if previous.timestamp == point.timestamp, previous.lat == point.lat,
                   previous.lon == point.lon {
                    continue
                }
                if let earlier = previous.timestamp, let later = point.timestamp {
                    let dt = later.timeIntervalSince(earlier)
                    // Two fixes for one instant: the first one stands.
                    if fullyTimed, dt <= 0 { continue }
                    if dt > 0, dt <= spikeCheckMaximumGapS {
                        guard isPlausibleStep(from: previous, to: point) else {
                            if let last = rejected.last, !isPlausibleStep(from: last, to: point) { rejected = [] }
                            rejected.append(point)
                            if anchorIsUnchecked, rejected.count >= anchorOutvotingFixes {
                                normalized.removeLast()
                                normalized += rejected
                                rejected = []
                                // The replacements were checked only against each other.
                                anchorIsUnchecked = false
                            }
                            continue
                        }
                        checked = true
                    }
                }
            }
            normalized.append(point)
            anchorIsUnchecked = !checked
            rejected = []
        }
        return normalized
    }

    /// Fixes that must agree with one another, and not with an unchecked
    /// anchor, before the anchor is taken to be the bad fix.
    static let anchorOutvotingFixes = 3

    /// Within the spike-check window and no faster than any skier moves.
    private static func isPlausibleStep(from earlier: TrackPoint, to later: TrackPoint) -> Bool {
        guard let start = earlier.timestamp, let end = later.timestamp else { return true }
        let dt = end.timeIntervalSince(start)
        guard dt > 0 else { return false }
        guard dt <= spikeCheckMaximumGapS else { return true }
        return Geo.haversineM(earlier.coordinate, later.coordinate) / dt <= maximumPlausiblePointSpeedMS
    }

    /// A cleaned, timed track with an elevation for every fix.
    struct Prepared: Equatable {
        var points: [TrackPoint]
        var times: [Double]
        var elevations: [Double]
    }

    /// Nil when fewer than two timed fixes remain or none carries a usable
    /// elevation.
    static func prepare(_ rawPoints: [TrackPoint]) -> Prepared? {
        var scratch = Outcome()
        return prepare(rawPoints, into: &scratch)
    }

    private static func prepare(_ rawPoints: [TrackPoint], into outcome: inout Outcome) -> Prepared? {
        let timed = rawPoints.filter { $0.timestamp != nil }
        outcome.untimedPoints = rawPoints.count - timed.count
        var points = normalizedPoints(timed)
        outcome.discardedPoints = timed.count - points.count
        outcome.timedPointCount = points.count
        guard points.count >= 2 else { return nil }
        let times = points.map { $0.timestamp?.timeIntervalSince1970 ?? 0 }
        for index in elevationOutliers(points, times: times) { points[index].elevationM = nil }

        // Some loggers write 0 (or one constant) for every elevation when they
        // have none. A track that moves but never changes height has none.
        let known = points.indices.filter { points[$0].elevationM != nil }
        guard known.count >= 2 else { return nil }
        var low = Double.infinity
        var high = -Double.infinity
        for index in known {
            let value = points[index].elevationM ?? 0
            low = min(low, value)
            high = max(high, value)
        }
        guard high - low >= 1 else { return nil }

        var elevations = [Double](repeating: 0, count: points.count)
        var cursor = 0
        for index in points.indices {
            if let value = points[index].elevationM {
                elevations[index] = value
                continue
            }
            while cursor + 1 < known.count, known[cursor + 1] < index { cursor += 1 }
            let before = known[cursor] < index ? known[cursor] : nil
            let after = before == nil ? known[cursor] : (cursor + 1 < known.count ? known[cursor + 1] : nil)
            switch (before, after) {
            case let (b?, a?):
                let span = times[a] - times[b]
                let t = span > 0 ? (times[index] - times[b]) / span : 0
                elevations[index] = (points[b].elevationM ?? 0) + ((points[a].elevationM ?? 0) - (points[b].elevationM ?? 0)) * t
            case let (b?, nil):
                elevations[index] = points[b].elevationM ?? 0
            case let (nil, a?):
                elevations[index] = points[a].elevationM ?? 0
            default:
                break
            }
        }
        outcome.interpolatedElevationShare = Double(points.count - known.count) / Double(points.count)
        return Prepared(points: points, times: times, elevations: elevations)
    }

    /// Heights outside this band are placeholders, not readings.
    static let plausibleElevationM: ClosedRange<Double> = -500...9_000
    /// A height this far from its neighbours' median is a glitch...
    static let elevationOutlierM = 50.0
    /// ...unless the neighbours are far enough away in time to have climbed
    /// or dropped that much at this rate, which no skier or lift exceeds.
    static let elevationOutlierRateMS = 15.0
    /// Known heights on each side a height is judged against.
    static let elevationOutlierNeighbours = 4

    /// Indices whose height disagrees with the heights around it: one fix
    /// reading 0 m mid-run would otherwise dip the smoothed profile far
    /// enough to split the run and add phantom vertical. A steady climb or
    /// descent sits on its neighbours' median, so only a lone spike stands out.
    static func elevationOutliers(_ points: [TrackPoint], times: [Double]) -> [Int] {
        let known = points.indices.filter { points[$0].elevationM != nil }
        guard known.count > 2 else { return [] }
        var outliers: [Int] = []
        for position in known.indices {
            let index = known[position]
            guard let height = points[index].elevationM else { continue }
            let lower = max(0, position - elevationOutlierNeighbours)
            let upper = min(known.count - 1, position + elevationOutlierNeighbours)
            let neighbours = (lower...upper).filter { $0 != position }.map { known[$0] }
            guard neighbours.count >= 2 else { continue }
            let heights = neighbours.compactMap { points[$0].elevationM }.sorted()
            let middle = heights.count / 2
            let median = heights.count % 2 == 0 ? (heights[middle - 1] + heights[middle]) / 2 : heights[middle]
            let span = neighbours.map { abs(times[$0] - times[index]) }.max() ?? 0
            if abs(height - median) > max(elevationOutlierM, elevationOutlierRateMS * span) {
                outliers.append(index)
            }
        }
        return outliers
    }

    // MARK: Detection

    /// A descending stretch of track and what was measured on it.
    struct Candidate: Equatable {
        var points: [TrackPoint]
        var start: Date
        var end: Date
        var topM: Double
        var bottomM: Double
        /// Sum of drops in the smoothed elevation.
        var verticalM: Double
        var distanceM: Double
        var durationS: Double
        /// Mean and 90th percentile of ten-second speeds while moving.
        var movingSpeedMS: Double
        var fastSpeedMS: Double
        var medianSpeedMS: Double
        /// Straight-line distance over path length, 0...1.
        var straightness: Double
        var grade: Double
        var rejection: Rejection?
    }

    /// Every descending stretch in the track, runs and rejects alike.
    static func detect(_ track: Prepared) -> [Candidate] {
        var output: [Candidate] = []
        var chunkStart = 0
        let count = track.points.count
        for index in 1...count {
            let isBreak: Bool
            if index == count {
                isBreak = true
            } else {
                let dt = track.times[index] - track.times[index - 1]
                isBreak = dt > hardGapS || (dt > movedGapS && Geo.haversineM(
                    track.points[index - 1].coordinate, track.points[index].coordinate
                ) > movedGapDistanceM)
            }
            guard isBreak else { continue }
            if index - chunkStart >= 3 {
                output += detect(chunk: chunkStart..<index, of: track)
            }
            chunkStart = index
        }
        return output
    }

    private static func detect(chunk: Range<Int>, of track: Prepared) -> [Candidate] {
        let points = Array(track.points[chunk])
        let times = Array(track.times[chunk])
        let smooth = smoothed(Array(track.elevations[chunk]), times: times)
        let count = points.count

        var cumulative = [Double](repeating: 0, count: count)
        for index in 1..<count {
            cumulative[index] = cumulative[index - 1]
                + Geo.haversineM(points[index - 1].coordinate, points[index].coordinate)
        }
        // A fix is active when the skier covers ground over the next 20 s.
        var active = [Bool](repeating: false, count: count)
        var ahead = 0
        for index in 0..<count {
            ahead = max(ahead, index)
            while ahead < count - 1, times[ahead] - times[index] < activeWindowS { ahead += 1 }
            let dt = times[ahead] - times[index]
            active[index] = dt > 0 && dt <= 3 * activeWindowS
                && (cumulative[ahead] - cumulative[index]) / dt >= activeSpeedMS
        }

        var output: [Candidate] = []
        for leg in descendingLegs(smooth) {
            var first = leg.lowerBound
            var last = leg.upperBound
            let top = smooth[first]
            let bottom = smooth[last]
            // The top and bottom few metres are usually standing about.
            let margin = max(trimMinimumM, min(trimMaximumM, trimFraction * (top - bottom)))
            while first + 1 < last, top - smooth[first + 1] < margin { first += 1 }
            while last - 1 > first, smooth[last - 1] - bottom < margin { last -= 1 }
            guard let firstActive = (first...last).first(where: { active[$0] }),
                  let lastActive = (first...last).last(where: { active[$0] }) else { continue }
            let from = firstActive
            let to = min(lastActive + 1, last)
            guard to - from >= 2 else { continue }
            var candidate = measure(
                points: Array(points[from...to]), times: Array(times[from...to]),
                smooth: Array(smooth[from...to])
            )
            // The few metres trimmed at each end were still descended.
            candidate.verticalM = zip(smooth[leg], smooth[leg].dropFirst()).reduce(0) { $0 + max(0, $1.0 - $1.1) }

            // Skiing to the car and driving down the canyon is one unbroken
            // descent. When the whole is not a run, the parts between long
            // stops are judged on their own.
            if candidate.rejection == .vehicle || candidate.rejection == .flat {
                var parts: [Candidate] = []
                var partStart = from
                var previousActive = from
                for index in from...to where active[index] || index == to {
                    if index == to || times[index] - times[previousActive] > partingStopS {
                        let partEnd = index == to ? to : min(previousActive + 1, to)
                        if partEnd - partStart >= 2 {
                            parts.append(measure(
                                points: Array(points[partStart...partEnd]), times: Array(times[partStart...partEnd]),
                                smooth: Array(smooth[partStart...partEnd])
                            ))
                        }
                        partStart = index
                    }
                    previousActive = index
                }
                // Once in the car the skier stays in it: nothing after the
                // first driven part can be a run.
                if let firstDriven = parts.firstIndex(where: { $0.rejection == .vehicle }) {
                    for index in parts.indices where index > firstDriven && parts[index].rejection == nil {
                        parts[index].rejection = .vehicle
                    }
                }
                if parts.count > 1, parts.contains(where: { $0.rejection == nil }) {
                    // A stop only separates skiing from driving; the skied
                    // parts on either side of a stop are still one run.
                    var index = 0
                    while index < parts.count {
                        var last = index
                        while parts[index].rejection == nil, last + 1 < parts.count,
                              parts[last + 1].rejection == nil { last += 1 }
                        if last > index, let low = times.firstIndex(of: parts[index].start.timeIntervalSince1970),
                           let high = times.lastIndex(of: parts[last].end.timeIntervalSince1970), high - low >= 2 {
                            var merged = measure(
                                points: Array(points[low...high]), times: Array(times[low...high]),
                                smooth: Array(smooth[low...high])
                            )
                            merged.rejection = nil
                            output.append(merged)
                        } else {
                            output += parts[index...last]
                        }
                        index = last + 1
                    }
                    continue
                }
            }
            output.append(candidate)
        }
        return output
    }

    /// The part of a prepared track between two times, measured as one stretch.
    private static func stretch(of track: Prepared, from start: Date, to end: Date) -> Candidate? {
        let low = start.timeIntervalSince1970
        let high = end.timeIntervalSince1970
        guard let first = track.times.firstIndex(where: { $0 >= low }),
              let last = track.times.lastIndex(where: { $0 <= high }), last - first >= 2 else { return nil }
        let times = Array(track.times[first...last])
        // Smoothed over the whole track, as detection saw it, so the ends do
        // not shift with where the slice is cut.
        let smooth = Array(smoothed(track.elevations, times: track.times)[first...last])
        var candidate = measure(points: Array(track.points[first...last]), times: times, smooth: smooth)
        candidate.rejection = nil
        return candidate
    }

    /// Measures a whole track as one stretch (used on a provider's run).
    static func measure(_ track: Prepared) -> Candidate? {
        guard track.points.count >= 3 else { return nil }
        return measure(
            points: track.points, times: track.times,
            smooth: smoothed(track.elevations, times: track.times)
        )
    }

    private static func measure(points: [TrackPoint], times: [Double], smooth: [Double]) -> Candidate {
        let count = points.count
        var cumulative = [Double](repeating: 0, count: count)
        var vertical = 0.0
        for index in 1..<count {
            cumulative[index] = cumulative[index - 1]
                + Geo.haversineM(points[index - 1].coordinate, points[index].coordinate)
            vertical += max(0, smooth[index - 1] - smooth[index])
        }
        let distance = cumulative[count - 1]
        let duration = times[count - 1] - times[0]

        // Ten-second speeds, keeping only those where the skier is moving.
        var speeds: [Double] = []
        var ahead = 0
        for index in 0..<count {
            ahead = max(ahead, index)
            while ahead < count - 1, times[ahead] - times[index] < 10 { ahead += 1 }
            let dt = times[ahead] - times[index]
            guard dt >= 5 else { continue }
            let speed = (cumulative[ahead] - cumulative[index]) / dt
            if speed >= 1 { speeds.append(speed) }
        }
        speeds.sort()
        let mean = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        let fast = speeds.isEmpty ? 0 : speeds[min(speeds.count - 1, Int(Double(speeds.count) * 0.9))]
        let median = speeds.isEmpty ? 0 : speeds[speeds.count / 2]
        let chord = Geo.haversineM(points[0].coordinate, points[count - 1].coordinate)
        let net = smooth[0] - smooth[count - 1]

        var candidate = Candidate(
            points: points,
            start: Date(timeIntervalSince1970: times[0]),
            end: Date(timeIntervalSince1970: times[count - 1]),
            topM: smooth[0], bottomM: smooth[count - 1], verticalM: vertical,
            distanceM: distance, durationS: duration,
            movingSpeedMS: mean, fastSpeedMS: fast, medianSpeedMS: median,
            straightness: distance > 0 ? chord / distance : 0,
            grade: distance > 0 ? net / distance : 0,
            rejection: nil
        )
        candidate.rejection = rejection(for: candidate, netVerticalM: net)
        return candidate
    }

    private static func rejection(for c: Candidate, netVerticalM: Double) -> Rejection? {
        if netVerticalM < minimumVerticalM || c.durationS < minimumDurationS || c.distanceM < minimumDistanceM {
            return .tooSmall
        }
        if c.fastSpeedMS < minimumFastSpeedMS { return .tooSlow }
        if c.grade < vehicleMaximumGrade, c.movingSpeedMS >= vehicleMinimumSpeedMS { return .vehicle }
        // A canyon road can be as steep as a green run, but nobody averages
        // 12 m/s on skis for six kilometres.
        if c.distanceM >= vehicleLongDistanceM, c.movingSpeedMS >= vehicleLongSpeedMS { return .vehicle }
        if c.grade < vehicleFastMaximumGrade, c.movingSpeedMS >= vehicleLongSpeedMS { return .vehicle }
        if c.grade < minimumGrade { return .flat }
        // A lift moves at one speed in a straight line; a skier does neither.
        // Fast straight-lining on a small hill is not a lift: lifts are slow.
        if c.fastSpeedMS <= liftMaximumSpeedMS {
            let spread = c.fastSpeedMS / max(c.medianSpeedMS, 0.1)
            if c.straightness > liftStraightness, spread < liftSpeedSpread { return .liftDownhill }
            if c.straightness >= liftVeryStraight, spread < liftVeryStraightSpread { return .liftDownhill }
            // A gondola with an angle station is not straight, but its speed
            // is steadier than any skier's.
            if c.durationS >= liftBentMinimumDurationS, c.straightness > liftBentStraightness,
               spread < liftBentSpread { return .liftDownhill }
        }
        return nil
    }

    /// Mean elevation over ±8 s around each fix.
    static func smoothed(_ elevations: [Double], times: [Double]) -> [Double] {
        let count = elevations.count
        var output = [Double](repeating: 0, count: count)
        var low = 0
        var high = 0
        var sum = 0.0
        for index in 0..<count {
            while high < count, times[high] <= times[index] + smoothingHalfWindowS {
                sum += elevations[high]
                high += 1
            }
            while times[low] < times[index] - smoothingHalfWindowS {
                sum -= elevations[low]
                low += 1
            }
            output[index] = sum / Double(high - low)
        }
        return output
    }

    /// Index ranges, peak to valley, of every fall of at least `reversalM`
    /// that is not interrupted by a rise of the same size.
    static func descendingLegs(_ elevations: [Double]) -> [ClosedRange<Int>] {
        guard elevations.count >= 2 else { return [] }
        var legs: [ClosedRange<Int>] = []
        var direction = 0
        var highest = 0
        var lowest = 0
        var legStart = 0
        var extreme = 0
        for index in 1..<elevations.count {
            let value = elevations[index]
            switch direction {
            case 0:
                if value > elevations[highest] { highest = index }
                if value < elevations[lowest] { lowest = index }
                if elevations[highest] - value >= reversalM {
                    direction = -1
                    legStart = highest
                    extreme = index
                } else if value - elevations[lowest] >= reversalM {
                    direction = 1
                    legStart = lowest
                    extreme = index
                }
            case -1:
                if value < elevations[extreme] {
                    extreme = index
                } else if value - elevations[extreme] >= reversalM {
                    legs.append(legStart...extreme)
                    direction = 1
                    legStart = extreme
                    extreme = index
                }
            default:
                if value > elevations[extreme] {
                    extreme = index
                } else if elevations[extreme] - value >= reversalM {
                    direction = -1
                    legStart = extreme
                    extreme = index
                }
            }
        }
        if direction == -1, extreme > legStart { legs.append(legStart...extreme) }
        return legs
    }

    // MARK: Segments

    private static func segment(from run: Candidate) -> ParsedSegment {
        ParsedSegment(
            number: 0,
            startTime: run.start,
            endTime: run.end,
            durationS: run.durationS,
            topSpeedMS: validSpeed(GPXSpeedStats.peakSpeed(run.points)),
            avgSpeedMS: validSpeed(run.movingSpeedMS),
            distanceM: run.distanceM,
            verticalM: run.verticalM,
            points: run.points
        )
    }

    /// A provider's run with its boundaries taken from its own points and
    /// implausible native statistics removed. Nil when it has no duration.
    private static func sanitized(_ source: ParsedSegment, points: [TrackPoint]) -> ParsedSegment? {
        guard points.count >= 2, let start = points.first?.timestamp,
              let end = points.last?.timestamp, end > start else { return nil }
        let duration = positiveFinite(source.durationS) ?? end.timeIntervalSince(start)

        var result = source
        result.startTime = start
        result.endTime = end
        result.durationS = duration
        result.topSpeedMS = GPXSpeedStats.topSpeed(points: points, claimed: source.topSpeedMS)
        result.avgSpeedMS = validSpeed(source.avgSpeedMS)
        result.distanceM = source.distanceM.flatMap { value in
            value.isFinite && value > 0 && value <= duration * GPXSpeedStats.peakSpeedCeiling * 1.25
                ? value : nil
        }
        result.verticalM = source.verticalM.flatMap { $0.isFinite && $0 >= 0 && $0 <= 5_000 ? $0 : nil }
        result.points = points
        return result
    }

    private static func overlap(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)))
    }

    private static func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func validSpeed(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= GPXSpeedStats.peakSpeedCeiling else {
            return nil
        }
        return value
    }

    public static func totalDistanceMeters(_ points: [TrackPoint]) -> Double {
        Geo.lengthM(points.map(\.coordinate))
    }

    /// Sum of drops larger than a metre between consecutive elevations.
    public static func descentMeters(_ points: [TrackPoint]) -> Double {
        let elevations = points.compactMap(\.elevationM)
        guard elevations.count >= 2 else { return 0 }
        return zip(elevations, elevations.dropFirst()).reduce(0) { total, pair in
            let drop = pair.0 - pair.1
            return total + (drop > 1 ? drop : 0)
        }
    }
}
