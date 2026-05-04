//
//  TrailMatcher.swift
//  PowderMeet
//
//  Matches GPS track segments to known trail edges in a MountainGraph.
//  Pipeline: resort ID → run segmentation → trail matching → speed stats.
//

import Foundation
import CoreLocation

// MARK: - Segmented Run

struct SegmentedRun {
    let points: [GPXTrackPoint]
    let isLift: Bool
}

// MARK: - Trail Matcher

nonisolated struct TrailMatcher {
    let graph: MountainGraph

    /// Match confidence — strict matches gate the per-edge skill memory
    /// path (algo signal); relaxed matches only attach a trail name for
    /// display. The viewer can surface a HI/MED badge per row.
    enum MatchTier: Sendable {
        /// Tight thresholds: low false-positive rate; what the per-edge
        /// skill memory loop should consume.
        case strict
        /// Wide thresholds: catches near-trail / parallel-trail / sparse-GPS
        /// runs that would otherwise show "Imported Run". Names only —
        /// never feeds skill memory.
        case relaxed
    }

    // Sliding-window size for lift/run detection
    private let windowSize = 6
    // Max average perpendicular distance (meters) to accept a strict trail match
    private let matchThreshold: Double = 60
    // Max bearing mismatch (degrees) between GPS track and edge for strict match
    private let bearingThreshold: Double = 45
    // Relaxed-tier thresholds — used for naming only, not algo input.
    // Wider in distance (parallel trails up to ~120m apart still resolve)
    // and bearing (skiers can carve 70° away from a trail's first→last
    // bearing — switchback runs especially). Empirically tuned to recover
    // most real-world Slopes mismatches without sweeping in lift rides.
    private let relaxedMatchThreshold: Double = 120
    private let relaxedBearingThreshold: Double = 70
    // Lift detection thresholds
    private let liftElevationGainThreshold: Double = 8    // meters per window
    private let liftMaxSpeedThreshold: Double = 5.5       // m/s
    // Pause detection: points with speed below this are considered stopped
    private let pauseSpeedThreshold: Double = 1.0         // m/s
    private let pauseMinDuration: TimeInterval = 10       // seconds
    // Peak-speed sanity ceiling. Recreational ski apps (Slopes, Strava) cap
    // around 30 m/s ≈ 67 mph; pros can exceed that, but a 67 mph reading from
    // a phone GPS in a recreational user's track is almost always a noise
    // spike (loss-of-fix snap to a far-away coordinate). Anything above this
    // gets thrown out before maxing.
    private let peakSpeedCeiling: Double = 30.0           // m/s

    // MARK: - Resort Identification

    static func identifyResort(from point: GPXTrackPoint) -> ResortEntry? {
        let coord = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return ResortEntry.catalog.first { $0.bounds.contains(coord) }
    }

    // MARK: - Run Segmentation

    /// Splits a GPS track into alternating ski runs and lift rides.
    func segmentTrack(_ points: [GPXTrackPoint]) -> [SegmentedRun] {
        guard points.count >= 3 else { return [] }

        var segments: [SegmentedRun] = []
        var currentGroup: [GPXTrackPoint] = []
        var currentIsLift: Bool? = nil

        for i in 0..<points.count {
            let start = max(0, i - windowSize + 1)
            let window = Array(points[start...i])
            let isLift = classifyWindow(window)

            if let existing = currentIsLift, existing != isLift {
                if currentGroup.count >= 4 {
                    segments.append(SegmentedRun(points: currentGroup, isLift: existing))
                }
                currentGroup = []
            }

            currentGroup.append(points[i])
            currentIsLift = isLift
        }

        if let finalType = currentIsLift, currentGroup.count >= 4 {
            segments.append(SegmentedRun(points: currentGroup, isLift: finalType))
        }

        return segments
    }

    /// Returns true if this window of points looks like a lift ride.
    private func classifyWindow(_ window: [GPXTrackPoint]) -> Bool {
        guard window.count >= 2 else { return false }

        let elevations = window.compactMap { $0.elevation }
        guard elevations.count >= 2 else { return false }

        let elevationGain = (elevations.last ?? 0) - (elevations.first ?? 0)

        var totalDistance = 0.0
        for i in 1..<window.count {
            let a = Coordinate(lat: window[i-1].latitude, lon: window[i-1].longitude)
            let b = Coordinate(lat: window[i].latitude, lon: window[i].longitude)
            totalDistance += haversine(from: a, to: b)
        }

        var speed = 0.0
        if let t1 = window.first?.timestamp, let t2 = window.last?.timestamp {
            let elapsed = t2.timeIntervalSince(t1)
            if elapsed > 0 { speed = totalDistance / elapsed }
        }

        // Lift: gaining elevation at low speed
        return elevationGain > liftElevationGainThreshold && speed < liftMaxSpeedThreshold
    }

    // MARK: - Trail Matching

    /// Strict match — used by the importer to drive per-edge skill memory.
    /// Returns nil unless the best-scoring edge is within 60m perpendicular
    /// AND within 45° of the GPS bearing.
    func matchRun(_ segment: SegmentedRun) -> (edge: GraphEdge, speed: Double, peakSpeed: Double)? {
        guard let result = bestEdge(for: segment, tier: .strict) else { return nil }
        let speed = movingSpeed(for: segment.points)
        guard speed > 0 else { return nil }
        let peak = max(peakSpeed(for: segment.points), speed)
        return (edge: result.edge, speed: speed, peakSpeed: peak)
    }

    /// Best-effort name resolution — returns the closest run-edge under
    /// relaxed thresholds (120m / 70°). Used by the importer's naming
    /// fallback. The edge here is NOT trustworthy for skill-memory
    /// purposes; use only for display.
    func bestEffortNameMatch(for segment: SegmentedRun) -> GraphEdge? {
        bestEdge(for: segment, tier: .relaxed)?.edge
    }

    /// Last-resort name resolution — closest run-edge to the segment's
    /// centroid, ignoring bearing entirely. Capped at 300m so we don't
    /// pick up an edge on the other side of a peak. Returns the edge
    /// even when the strict + relaxed tiers both rejected it; consumer
    /// uses this purely for naming when nothing else fits, never for
    /// algorithm input.
    func nearestRunEdgeByCentroid(for segment: SegmentedRun) -> GraphEdge? {
        guard !segment.isLift, segment.points.count >= 2 else { return nil }
        let runEdges = graph.runs
        guard !runEdges.isEmpty else { return nil }

        // Centroid of the segment (mean lat/lon — fine at resort scale,
        // mercator distortion is negligible inside a few-km bbox).
        var sumLat = 0.0
        var sumLon = 0.0
        for p in segment.points {
            sumLat += p.latitude
            sumLon += p.longitude
        }
        let n = Double(segment.points.count)
        let centroid = Coordinate(lat: sumLat / n, lon: sumLon / n)

        var bestEdge: GraphEdge?
        var bestDist = Double.infinity
        for edge in runEdges where !edge.geometry.isEmpty {
            // Distance from segment centroid to nearest point on the
            // edge polyline. Cheaper than full polyline-to-polyline
            // similarity and good enough for a centroid-only heuristic.
            var nearest = Double.infinity
            for ep in edge.geometry {
                let d = haversine(from: centroid, to: Coordinate(lat: ep.latitude, lon: ep.longitude))
                if d < nearest { nearest = d }
            }
            if nearest < bestDist {
                bestDist = nearest
                bestEdge = edge
            }
        }
        // Cap. Beyond 300m it's almost certainly the wrong trail
        // (different lift pod, opposite face, off-piste).
        guard let edge = bestEdge, bestDist < 300 else { return nil }
        return edge
    }

    /// Shared scorer for both tiers. Returns the best edge under the
    /// tier's distance + bearing thresholds, or nil if nothing fits.
    private func bestEdge(for segment: SegmentedRun, tier: MatchTier)
        -> (edge: GraphEdge, score: Double)?
    {
        guard !segment.isLift, segment.points.count >= 2 else { return nil }
        let runEdges = graph.runs
        guard !runEdges.isEmpty else { return nil }

        let distLimit: Double
        let bearLimit: Double
        switch tier {
        case .strict:  distLimit = matchThreshold;        bearLimit = bearingThreshold
        case .relaxed: distLimit = relaxedMatchThreshold; bearLimit = relaxedBearingThreshold
        }

        let gpsBearing = dominantBearing(segment.points)

        var bestEdge: GraphEdge?
        var bestScore = Double.infinity

        for edge in runEdges where !edge.geometry.isEmpty {
            if let gpsBrg = gpsBearing,
               let edgeBrg = self.edgeBearing(edge) {
                var bearingDiff = abs(gpsBrg - edgeBrg)
                if bearingDiff > 180 { bearingDiff = 360 - bearingDiff }
                // Allow uphill or downhill on the same trail.
                if bearingDiff > bearLimit && (180 - bearingDiff) > bearLimit {
                    continue
                }
            }
            let score = avgPerpendicularDistance(points: segment.points, to: edge)
            if score < bestScore {
                bestScore = score
                bestEdge = edge
            }
        }

        guard let edge = bestEdge, bestScore < distLimit else { return nil }
        return (edge, bestScore)
    }

    // MARK: - Geometry Helpers

    /// Average distance from each GPS point to the nearest point on the edge polyline.
    private func avgPerpendicularDistance(points: [GPXTrackPoint], to edge: GraphEdge) -> Double {
        var total = 0.0
        for pt in points {
            let coord = Coordinate(lat: pt.latitude, lon: pt.longitude)
            let nearest = edge.geometry.reduce(Double.infinity) { best, edgePt in
                min(best, haversine(from: coord, to: Coordinate(lat: edgePt.latitude, lon: edgePt.longitude)))
            }
            total += nearest
        }
        return total / Double(points.count)
    }

    /// Dominant bearing of a GPS segment (first → last point).
    private func dominantBearing(_ points: [GPXTrackPoint]) -> Double? {
        guard let first = points.first, let last = points.last,
              points.count >= 2 else { return nil }
        return bearing(
            from: Coordinate(lat: first.latitude, lon: first.longitude),
            to: Coordinate(lat: last.latitude, lon: last.longitude)
        )
    }

    /// Dominant bearing of a graph edge (first → last coordinate).
    private func edgeBearing(_ edge: GraphEdge) -> Double? {
        guard let first = edge.geometry.first, let last = edge.geometry.last,
              edge.geometry.count >= 2 else { return nil }
        return bearing(
            from: Coordinate(lat: first.latitude, lon: first.longitude),
            to: Coordinate(lat: last.latitude, lon: last.longitude)
        )
    }

    /// Bearing from point A to point B in degrees (0–360).
    private func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var brg = atan2(y, x) * 180 / .pi
        if brg < 0 { brg += 360 }
        return brg
    }

    /// Moving speed in m/s, excluding pauses (<1 m/s for >10s).
    /// This prevents idle time (waiting for friends, gear adjustment) from
    /// corrupting the speed profile.
    func movingSpeed(for points: [GPXTrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }

        var movingDistance = 0.0
        var movingTime: TimeInterval = 0

        var i = 0
        while i < points.count - 1 {
            let a = points[i]
            let b = points[i + 1]

            let dist = haversine(
                from: Coordinate(lat: a.latitude, lon: a.longitude),
                to: Coordinate(lat: b.latitude, lon: b.longitude)
            )

            guard let t1 = a.timestamp, let t2 = b.timestamp else {
                i += 1
                continue
            }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0 else {
                i += 1
                continue
            }

            let segSpeed = dist / dt

            if segSpeed < pauseSpeedThreshold {
                // Check if this is a sustained pause (>10s)
                var pauseEnd = i + 1
                var pauseDuration = dt
                while pauseEnd < points.count - 1 {
                    let nextDist = haversine(
                        from: Coordinate(lat: points[pauseEnd].latitude, lon: points[pauseEnd].longitude),
                        to: Coordinate(lat: points[pauseEnd + 1].latitude, lon: points[pauseEnd + 1].longitude)
                    )
                    guard let pt1 = points[pauseEnd].timestamp,
                          let pt2 = points[pauseEnd + 1].timestamp else { break }
                    let nextDt = pt2.timeIntervalSince(pt1)
                    guard nextDt > 0 else { break }
                    let nextSpeed = nextDist / nextDt
                    if nextSpeed >= pauseSpeedThreshold { break }
                    pauseDuration += nextDt
                    pauseEnd += 1
                }

                if pauseDuration >= pauseMinDuration {
                    // Skip the entire pause
                    i = pauseEnd
                    continue
                }
            }

            // This segment is moving — count it
            movingDistance += dist
            movingTime += dt
            i += 1
        }

        return movingTime > 0 ? movingDistance / movingTime : 0
    }

    /// Peak instantaneous speed in m/s within a run. Uses a rolling
    /// 3-sample window over the per-sample (haversine-distance / dt) speeds
    /// — single-sample peaks aren't trusted because phone GPS routinely
    /// produces 1-sample fix snaps that fake 100+ mph bursts.
    ///
    /// Samples with abnormal dt (≤ 0 or > 30s, e.g., paused recording or
    /// mid-run signal loss) are skipped — they make the haversine
    /// instantaneous-speed estimate meaningless. The return is clamped to
    /// `peakSpeedCeiling` to defang any remaining noise.
    func peakSpeed(for points: [GPXTrackPoint]) -> Double {
        guard points.count >= 4 else { return 0 }

        // Collect per-sample (dist, dt) for valid pairs.
        var samples: [(dist: Double, dt: TimeInterval)] = []
        samples.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            guard let t1 = a.timestamp, let t2 = b.timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0, dt <= 30 else { continue }
            let dist = haversine(
                from: Coordinate(lat: a.latitude, lon: a.longitude),
                to: Coordinate(lat: b.latitude, lon: b.longitude)
            )
            samples.append((dist, dt))
        }
        guard samples.count >= 3 else { return 0 }

        // Rolling 3-sample window: sum dist over 3 consecutive samples,
        // divide by their summed dt. This smooths a single bad fix without
        // erasing real bursts.
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
}
