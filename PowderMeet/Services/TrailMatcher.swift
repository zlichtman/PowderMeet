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

/// All-or-nothing topology match for one observed downhill run. The full
/// stable segment sequence is retained for provenance and learning; the
/// primary edge exists only for legacy UI/schema compatibility.
nonisolated struct TrailMatch: Sendable {
    let primaryEdge: GraphEdge
    let segmentIDs: [String]
    let edgePaceObservations: [EdgePaceObservation]
    let confidence: Double
    let meanDistanceMeters: Double
}

// MARK: - Trail Matcher

/// Rejection evidence is available to audits without relaxing production
/// matching. The optional-match facade and diagnostics execute the same code.
nonisolated enum TrailMatchFailure: Error, Sendable {
    case invalidDescent
    case noTrailGeometry
    case insufficientCoverage(matched: Int, sampled: Int)
    case unmatchedTerminalStop(matched: Int, sampled: Int)
    case disconnectedSequence([String])
    case noConnectedTransition(frame: Int, previous: [String], next: [String])
    case missingPrimaryEdge
    case ambiguousConnectedRoutes(best: [String], alternative: [String])
}

/// Opt-in local audit evidence from the actual production candidate search.
/// No trace is allocated or persisted unless a caller explicitly records it.
nonisolated struct TrailMatchSampleEvidence: Codable, Sendable {
    struct Candidate: Codable, Sendable {
        let edgeID: String
        let distanceMeters: Double
        let alongMeters: Double
    }
    let sampleIndex: Int
    let candidateFrameIndex: Int?
    let latitude: Double
    let longitude: Double
    let timestamp: Double?
    let heading: Double?
    /// A repeated terminal fix has position evidence, but no travel direction.
    let isTerminalStationary: Bool
    let candidates: [Candidate]
}

nonisolated struct TrailMatcher {
    let graph: MountainGraph

    private struct MatchCandidate {
        let edge: GraphEdge
        let distance: Double
        let bearingQuality: Double
        let alongMeters: Double
        let isTerminalStationary: Bool

        var cost: Double { distance / 60 + 0.1 * (1 - bearingQuality) }
    }

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
    /// Minimum edge-local evidence before one physical run can contribute a
    /// pace observation. Boundary slivers below these floors remain in the
    /// matched sequence but cannot train routing.
    private let minimumEdgeObservationDuration: TimeInterval = 5
    private let minimumEdgeObservationDistance: Double = 15
    private let maximumEdgeIntervalDuration: TimeInterval = 30
    // Pause/peak-speed thresholds now live in `GPXSpeedStats` so imports,
    // live recordings, and trail matching can't drift apart.

    // MARK: - Resort Identification

    static func identifyResort(from point: GPXTrackPoint) -> ResortEntry? {
        ActivityResortResolver.identifyResort(for: [point])
    }

    // MARK: - Run Segmentation

    /// Splits a GPS track into alternating ski runs and lift rides.
    func segmentTrack(_ points: [GPXTrackPoint]) -> [SegmentedRun] {
        SkiActivitySegmenter.motionSegments(points).map {
            SegmentedRun(
                points: $0.points,
                isLift: $0.kind == .uphill || $0.kind == .stationary
            )
        }
    }

    // MARK: - Trail Matching

    /// Strict match — used by the importer to drive per-edge skill memory.
    /// Returns nil unless the best-scoring edge is within 60m perpendicular
    /// AND within 45° of the GPS bearing.
    func matchRun(_ segment: SegmentedRun) -> (edge: GraphEdge, speed: Double, peakSpeed: Double)? {
        guard let result = matchRunTopology(segment) else { return nil }
        let speed = movingSpeed(for: segment.points)
        guard speed > 0 else { return nil }
        let peak = max(peakSpeed(for: segment.points), speed)
        return (edge: result.primaryEdge, speed: speed, peakSpeed: peak)
    }

    /// Projects fixes onto directed polylines, selects a connected candidate
    /// sequence jointly, and returns a geometry-derived confidence score.
    /// Disconnected observations are rejected rather than attributed to
    /// unrelated trails; this score is not an empirically calibrated probability.
    func matchRunTopology(_ segment: SegmentedRun) -> TrailMatch? {
        try? evaluateRunTopology(segment).get()
    }

    func evaluateRunTopology(
        _ segment: SegmentedRun,
        recordSample: ((TrailMatchSampleEvidence) -> Void)? = nil
    ) -> Result<TrailMatch, TrailMatchFailure> {
        guard !segment.isLift,
              segment.points.count >= 2,
              isDownhillOrElevationUnknown(segment.points) else { return .failure(.invalidDescent) }
        let runEdges = graph.runs
            .filter { $0.geometry.count >= 2 }
            .sorted { $0.id < $1.id }
        guard !runEdges.isEmpty else { return .failure(.noTrailGeometry) }

        // Detect repeated terminal fixes before downsampling: a long lift
        // wait must not invent headings or dominate the run's evidence.
        let stationaryStart = terminalStationaryStart(in: segment.points)
        let sampleIndices: [Int]
        if segment.points.count > 240, stationaryStart < segment.points.count {
            // Spend the budget on skiing, not hundreds of repeated fixes.
            sampleIndices = sampledIndices(count: stationaryStart, maximumCount: 238)
                + [stationaryStart, segment.points.count - 1]
        } else {
            sampleIndices = sampledIndices(count: segment.points.count, maximumCount: 240)
        }
        let sampledPoints = sampleIndices.map { segment.points[$0] }
        let movingSampleCount = sampleIndices.filter { $0 < stationaryStart }.count
        var frames: [[MatchCandidate]] = []
        frames.reserveCapacity(sampledPoints.count)

        for (index, point) in sampledPoints.enumerated() {
            let stationary = sampleIndices[index] >= stationaryStart
            let heading = stationary ? nil : localBearing(at: index, in: sampledPoints)
            var candidates: [MatchCandidate] = []
            if heading != nil || stationary {
                for edge in runEdges {
                    let projection = polylineProjection(point: point, to: edge, heading: heading)
                    if projection.distance < matchThreshold {
                        candidates.append(MatchCandidate(edge: edge,
                            distance: projection.distance, bearingQuality: projection.bearingQuality,
                            alongMeters: projection.alongMeters, isTerminalStationary: stationary))
                    }
                }
            }
            candidates.sort {
                if $0.cost != $1.cost { return $0.cost < $1.cost }
                return $0.edge.id < $1.edge.id
            }
            // A locally ninth-ranked trail may be the only globally connected
            // route. Keep every candidate inside the unchanged geometry gates;
            // the indexed dynamic program below avoids an all-pairs search.
            let selected = candidates
            let frameIndex = selected.isEmpty ? nil : frames.count
            if !selected.isEmpty {
                frames.append(selected)
            }
            if let recordSample {
                recordSample(TrailMatchSampleEvidence(
                    sampleIndex: index, candidateFrameIndex: frameIndex,
                    latitude: point.latitude, longitude: point.longitude,
                    timestamp: point.timestamp?.timeIntervalSince1970, heading: heading,
                    isTerminalStationary: stationary,
                    candidates: selected.map { .init(edgeID: $0.edge.id,
                        distanceMeters: $0.distance, alongMeters: $0.alongMeters) }
                ))
            }
        }

        let movingFrameCount = frames.filter { !$0[0].isTerminalStationary }.count
        let coverage = movingSampleCount > 0 ? Double(movingFrameCount) / Double(movingSampleCount) : 0
        // A stop cannot dilute unmatched moving samples. Its position must
        // also remain covered, and the DP below must retain the same edge.
        let stationaryFrameCount = frames.count - movingFrameCount
        guard movingFrameCount >= 2, coverage >= 0.7 else {
            return .failure(.insufficientCoverage(matched: movingFrameCount, sampled: movingSampleCount))
        }
        guard stationaryFrameCount == sampledPoints.count - movingSampleCount else {
            return .failure(.unmatchedTerminalStop(matched: stationaryFrameCount,
                sampled: sampledPoints.count - movingSampleCount))
        }

        let assignments: [MatchCandidate]
        switch connectedAssignments(in: frames) {
        case .success(let selected): assignments = selected
        case .failure(let reason): return .failure(reason)
        }
        var sequence: [String] = []
        for candidate in assignments where sequence.last != candidate.edge.id {
            sequence.append(candidate.edge.id)
        }
        guard !sequence.isEmpty, isDirectedContiguous(sequence) else {
            return .failure(.disconnectedSequence(sequence))
        }

        let movingAssignments = assignments.filter { !$0.isTerminalStationary }
        let counts = Dictionary(grouping: movingAssignments, by: { $0.edge.id }).mapValues(\.count)
        let primaryID = sequence.sorted { lhs, rhs in
            let lhsCount = counts[lhs, default: 0]
            let rhsCount = counts[rhs, default: 0]
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs < rhs
        }.first
        guard let primaryID,
              let primaryEdge = graph.edge(byID: primaryID) else { return .failure(.missingPrimaryEdge) }

        let meanDistance = movingAssignments.reduce(0) { $0 + $1.distance } / Double(movingAssignments.count)
        let distanceQuality = max(0, 1 - meanDistance / matchThreshold)
        let bearingQuality = movingAssignments.reduce(0) { $0 + $1.bearingQuality } / Double(movingAssignments.count)
        let confidence = min(1, 0.55 * coverage + 0.35 * distanceQuality + 0.10 * bearingQuality)

        return .success(TrailMatch(
            primaryEdge: primaryEdge,
            segmentIDs: sequence,
            edgePaceObservations: edgePaceObservations(
                points: segment.points,
                segmentIDs: sequence,
                terminalStationaryStart: stationaryStart
            ),
            confidence: confidence,
            meanDistanceMeters: meanDistance
        ))
    }

    /// Geometry stays in this matcher; the pure indexed search retains the
    /// two best distinct routes so a tie cannot manufacture pace evidence.
    private func connectedAssignments(in frames: [[MatchCandidate]]) -> Result<[MatchCandidate], TrailMatchFailure> {
        let candidates = frames.map { frame in
            frame.map { candidate in
                ConnectedTrailPathSearch.Candidate(
                    edgeID: candidate.edge.id, sourceID: candidate.edge.sourceID,
                    targetID: candidate.edge.targetID, alongMeters: candidate.alongMeters,
                    cost: candidate.cost, isTerminalStationary: candidate.isTerminalStationary)
            }
        }
        return ConnectedTrailPathSearch.resolve(candidates).map { indices in
            indices.enumerated().map { frame, index in frames[frame][index] }
        }
    }

    /// Attribute only intervals whose two endpoints project to the same edge
    /// in the accepted directed sequence. A boundary-crossing interval is
    /// deliberately omitted instead of guessed. This means sparse multi-edge
    /// tracks may produce no training rows, while their run and full topology
    /// provenance still persist unchanged.
    private func edgePaceObservations(
        points: [GPXTrackPoint],
        segmentIDs: [String],
        terminalStationaryStart: Int
    ) -> [EdgePaceObservation] {
        let orderedEdges = segmentIDs.compactMap(graph.edge(byID:))
        guard !orderedEdges.isEmpty else { return [] }

        let assignments: [(edgeID: String, alongMeters: Double)?] = points.map { point in
            var best: (edgeID: String, alongMeters: Double)?
            var bestDistance = Double.infinity
            for edge in orderedEdges {
                let projection = polylineProjection(point: point, to: edge, heading: nil)
                if projection.distance < bestDistance {
                    bestDistance = projection.distance
                    best = (edge.id, projection.alongMeters)
                }
            }
            return bestDistance < matchThreshold ? best : nil
        }

        var distanceByEdge: [String: Double] = [:]
        var durationByEdge: [String: TimeInterval] = [:]
        var samplesByEdge: [String: [(distance: Double, duration: TimeInterval)]] = [:]

        for interval in GPXSpeedStats.movingIntervals(points) {
            guard interval.startIndex < terminalStationaryStart,
                  interval.durationS <= maximumEdgeIntervalDuration,
                  interval.speedMs.isFinite,
                  interval.speedMs > 0,
                  interval.speedMs <= GPXSpeedStats.peakSpeedCeiling,
                  assignments.indices.contains(interval.startIndex),
                  assignments.indices.contains(interval.endIndex),
                  let start = assignments[interval.startIndex],
                  let end = assignments[interval.endIndex],
                  start.edgeID == end.edgeID,
                  end.alongMeters > start.alongMeters else { continue }

            // A valid overall descent can still contain reverse movement or
            // GPS backtracking. Those intervals must not train forward pace.
            distanceByEdge[start.edgeID, default: 0] += interval.distanceM
            durationByEdge[start.edgeID, default: 0] += interval.durationS
            samplesByEdge[start.edgeID, default: []].append((
                distance: interval.distanceM,
                duration: interval.durationS
            ))
        }

        var emitted: Set<String> = []
        return segmentIDs.compactMap { edgeID in
            guard emitted.insert(edgeID).inserted,
                  let distance = distanceByEdge[edgeID],
                  let duration = durationByEdge[edgeID],
                  distance >= minimumEdgeObservationDistance,
                  duration >= minimumEdgeObservationDuration else { return nil }
            let speed = distance / duration
            guard speed.isFinite,
                  speed > 0,
                  speed <= GPXSpeedStats.peakSpeedCeiling else { return nil }

            let samples = samplesByEdge[edgeID] ?? []
            var rollingPeak = speed
            if samples.count >= 3 {
                for index in 2..<samples.count {
                    let window = samples[(index - 2)...index]
                    let windowDistance = window.reduce(0) { $0 + $1.distance }
                    let windowDuration = window.reduce(0) { $0 + $1.duration }
                    if windowDuration > 0 {
                        rollingPeak = max(rollingPeak, windowDistance / windowDuration)
                    }
                }
            }

            return EdgePaceObservation(
                edgeId: edgeID,
                speedMs: speed,
                peakSpeedMs: min(rollingPeak, GPXSpeedStats.peakSpeedCeiling),
                durationS: duration,
                distanceM: distance
            )
        }
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
        guard !segment.isLift,
              segment.points.count >= 2,
              isDownhillOrElevationUnknown(segment.points) else { return nil }
        let runEdges = graph.runs.sorted { $0.id < $1.id }
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
        let centroid = GPXTrackPoint(
            latitude: sumLat / n,
            longitude: sumLon / n
        )

        var bestEdge: GraphEdge?
        var bestDist = Double.infinity
        for edge in runEdges where edge.geometry.count >= 2 {
            // Distance from segment centroid to nearest point on the
            // edge's true polyline segments. Vertex-only distance rejected a
            // GPS centroid sitting in the middle of a long straight run when
            // both sparse canonical endpoints were more than 300 m away.
            let distance = perpendicularDistance(point: centroid, to: edge)
            if distance < bestDist {
                bestDist = distance
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
        guard !segment.isLift,
              segment.points.count >= 2,
              isDownhillOrElevationUnknown(segment.points) else { return nil }
        let runEdges = graph.runs.sorted { $0.id < $1.id }
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
                // Canonical run edges are directed downhill. Accepting the
                // reverse bearing attributes lifts/uphill tracks to runs.
                if bearingDiff > bearLimit {
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

    /// Average point-to-polyline distance. Unlike the former vertex-only
    /// calculation, a fix in the middle of a long straight segment projects
    /// to that segment instead of appearing hundreds of metres off trail.
    private func avgPerpendicularDistance(points: [GPXTrackPoint], to edge: GraphEdge) -> Double {
        let total = points.reduce(0) { $0 + perpendicularDistance(point: $1, to: edge) }
        return total / Double(points.count)
    }

    private func perpendicularDistance(point: GPXTrackPoint, to edge: GraphEdge) -> Double {
        polylineProjection(point: point, to: edge, heading: nil).distance
    }

    /// Compare the observed local direction with the actual directed segment,
    /// not the chord between an entire trail's endpoints. Choose the nearest
    /// geometric projection before checking its direction: filtering first
    /// can manufacture forward travel on a farther hairpin leg while the GPS
    /// is actually moving against the nearest one. Exact-distance ties may
    /// use the better-aligned tangent at a shared vertex. Strict distance and
    /// angular limits stay unchanged; relaxed naming remains display-only.
    private func polylineProjection(
        point: GPXTrackPoint, to edge: GraphEdge, heading: Double?
    ) -> (distance: Double, bearingQuality: Double, alongMeters: Double) {
        guard edge.geometry.count >= 2 else { return (.infinity, 0, 0) }
        let originLat = point.latitude * .pi / 180
        let metersPerDegreeLat = 111_132.0
        let metersPerDegreeLon = 111_320.0 * cos(originLat)
        func local(_ coordinate: Coordinate) -> (x: Double, y: Double) {
            (
                (coordinate.lon - point.longitude) * metersPerDegreeLon,
                (coordinate.lat - point.latitude) * metersPerDegreeLat
            )
        }

        var best = Double.infinity
        var bestBearingQuality = 0.8
        var bestBearingDelta = 0.0
        var bestAlong = 0.0
        var lengthBefore = 0.0
        for index in 1..<edge.geometry.count {
            let a = local(Coordinate(
                lat: edge.geometry[index - 1].latitude,
                lon: edge.geometry[index - 1].longitude
            ))
            let b = local(Coordinate(
                lat: edge.geometry[index].latitude,
                lon: edge.geometry[index].longitude
            ))
            let dx = b.x - a.x
            let dy = b.y - a.y
            let denominator = dx * dx + dy * dy
            guard denominator > 0 else { continue }
            let length = sqrt(denominator)
            let before = lengthBefore
            lengthBefore += length
            var quality = 0.8
            var delta = 0.0
            if let heading {
                let segmentBearing = atan2(dx, dy) * 180 / .pi
                delta = bearingDelta(heading, (segmentBearing + 360).truncatingRemainder(dividingBy: 360))
                quality = max(0, 1 - delta / bearingThreshold)
            }
            let t = denominator > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / denominator)) : 0
            let x = a.x + t * dx
            let y = a.y + t * dy
            let distance = hypot(x, y)
            if distance < best || (distance == best && quality > bestBearingQuality) {
                best = distance
                bestBearingQuality = quality
                bestBearingDelta = delta
                bestAlong = before + t * length
            }
        }
        guard heading == nil || bestBearingDelta <= bearingThreshold else {
            return (.infinity, 0, bestAlong)
        }
        return (best, bestBearingQuality, bestAlong)
    }

    /// Estimate the local travel trend, not the instantaneous sideways motion
    /// of a carve. A bounded weighted fit uses at most 40 m / 8 s on either
    /// side; sparse tracks retain the centered-chord fallback. Neither path
    /// establishes that a skier is moving; verified terminal repeated fixes
    /// are handled separately before calling this estimator.
    private func localBearing(at index: Int, in points: [GPXTrackPoint]) -> Double? {
        if let trend = localTrendBearing(at: index, in: points) { return trend }
        for radius in 1..<points.count {
            let a = points[max(0, index - radius)]
            let b = points[min(points.count - 1, index + radius)]
            let longitudeScale = 111_320.0 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
            let distance = hypot((b.latitude - a.latitude) * 111_132.0,
                                 (b.longitude - a.longitude) * longitudeScale)
            // Widen across repeated or tightly sampled fixes, rather than
            // letting a missing heading bypass the directed-match gate.
            if distance >= 5 {
                return bearing(from: Coordinate(lat: a.latitude, lon: a.longitude),
                               to: Coordinate(lat: b.latitude, lon: b.longitude))
            }
        }
        return nil
    }

    private func localTrendBearing(at index: Int, in points: [GPXTrackPoint]) -> Double? {
        let center = points[index]
        let longitudeScale = 111_320.0 * cos(center.latitude * .pi / 180)
        func position(_ point: GPXTrackPoint) -> (x: Double, y: Double) {
            ((point.longitude - center.longitude) * longitudeScale,
             (point.latitude - center.latitude) * 111_132.0)
        }
        func isLocal(_ point: GPXTrackPoint) -> Bool {
            let p = position(point)
            guard hypot(p.x, p.y) < 40 else { return false }
            if let time = point.timestamp, let origin = center.timestamp {
                return abs(time.timeIntervalSince(origin)) <= 8
            }
            return true
        }
        var lower = index
        var upper = index
        while lower > 0, isLocal(points[lower - 1]) { lower -= 1 }
        while upper + 1 < points.count, isLocal(points[upper + 1]) { upper += 1 }
        guard upper - lower >= 2 else { return nil }

        // Timestamp regression respects uneven recorder intervals. If a
        // provider has no complete monotonic clock, sample order still gives
        // the direction of its local trajectory without fabricating times.
        let times = (lower...upper).compactMap { points[$0].timestamp }
        let useTimes = times.count == upper - lower + 1
            && zip(times, times.dropFirst()).allSatisfy { $1 > $0 }
        let origin = points[lower].timestamp
        let samples = (lower...upper).map { i -> (t: Double, x: Double, y: Double, w: Double) in
            let p = position(points[i])
            let t = useTimes ? points[i].timestamp!.timeIntervalSince(origin!) : Double(i - lower)
            return (t, p.x, p.y, 1 - hypot(p.x, p.y) / 40)
        }
        let weight = samples.reduce(0) { $0 + $1.w }
        guard weight > 0 else { return nil }
        let meanT = samples.reduce(0) { $0 + $1.w * $1.t } / weight
        let meanX = samples.reduce(0) { $0 + $1.w * $1.x } / weight
        let meanY = samples.reduce(0) { $0 + $1.w * $1.y } / weight
        let denominator = samples.reduce(0) { $0 + $1.w * pow($1.t - meanT, 2) }
        guard denominator > 0 else { return nil }
        let dx = samples.reduce(0) { $0 + $1.w * ($1.t - meanT) * ($1.x - meanX) } / denominator
        let dy = samples.reduce(0) { $0 + $1.w * ($1.t - meanT) * ($1.y - meanY) } / denominator
        let span = samples.last!.t - samples.first!.t
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) * span >= 5 else { return nil }
        return (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Conservatively recognize a recorder's stationary terminal plateau,
    /// not all slow skiing. At least three fixes over five seconds must stay
    /// within 25 cm of the final fix with a complete increasing clock and no
    /// gap over 30 seconds. Raw points and source statistics are preserved;
    /// these directionless intervals cannot train per-edge pace.
    /// Missing clocks and sustained slow progress retain directional gates.
    private func terminalStationaryStart(in points: [GPXTrackPoint]) -> Int {
        guard let last = points.last, let endTime = last.timestamp else { return points.count }
        var start = points.count - 1
        while start > 0 {
            let previous = points[start - 1]
            guard let previousTime = previous.timestamp, let nextTime = points[start].timestamp else { break }
            let dt = nextTime.timeIntervalSince(previousTime)
            guard dt > 0, dt <= 30,
                  haversine(from: .init(lat: previous.latitude, lon: previous.longitude),
                            to: .init(lat: last.latitude, lon: last.longitude)) <= 0.25 else { break }
            start -= 1
        }
        guard points.count - start >= 3,
              let startTime = points[start].timestamp,
              endTime.timeIntervalSince(startTime) >= 5 else { return points.count }
        return start
    }

    private func sampledIndices(count: Int, maximumCount: Int) -> [Int] {
        guard count > maximumCount else { return Array(0..<count) }
        let stride = Double(count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { Int((Double($0) * stride).rounded()) }
    }

    private func isDirectedContiguous(_ ids: [String]) -> Bool {
        guard ids.count > 1 else { return true }
        for index in 1..<ids.count {
            guard let previous = graph.edge(byID: ids[index - 1]),
                  let current = graph.edge(byID: ids[index]),
                  previous.targetID == current.sourceID else { return false }
        }
        return true
    }

    private func bearingDelta(_ lhs: Double, _ rhs: Double) -> Double {
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    private func bearingsAlign(_ lhs: Double, _ rhs: Double, limit: Double) -> Bool {
        let delta = bearingDelta(lhs, rhs)
        return delta <= limit
    }

    private func isDownhillOrElevationUnknown(
        _ points: [GPXTrackPoint]
    ) -> Bool {
        let elevations = points.compactMap(\.elevation)
        guard let first = elevations.first,
              let last = elevations.last else { return true }
        return last - first <= 3
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

    /// Moving speed in m/s, excluding sustained pauses. Delegates to the
    /// shared `GPXSpeedStats` so imports and live recordings agree.
    func movingSpeed(for points: [GPXTrackPoint]) -> Double {
        GPXSpeedStats.movingAverageSpeed(points)
    }

    /// 3-sample-smoothed peak instantaneous speed, clamped to the recreational
    /// ceiling. Delegates to the shared `GPXSpeedStats`.
    func peakSpeed(for points: [GPXTrackPoint]) -> Double {
        GPXSpeedStats.peakSpeed(points)
    }
}
