import Foundation
import MountainCore

/// Pace measured on one edge from intervals that lie wholly on it.
struct EdgePace: Equatable {
    let edgeID: EdgeID
    let speedMS: Double
    let peakSpeedMS: Double
    let durationS: Double
    let distanceM: Double
}

/// The matcher's own result, before it is shaped into a `DescentMatch`.
struct TrailMatch {
    /// One stretch of consecutive frames in the same state.
    struct Visit: Equatable {
        /// Nil when the track is off the map.
        let edgeID: EdgeID?
        /// Index in the input points of the visit's first frame.
        let firstPoint: Int
        /// Metres advanced along the edge: how much of the trail was skied,
        /// which a stop or GPS jitter on the spot does not inflate.
        var progressM = 0.0
    }

    /// How the chosen path moved from one frame to the next, for audits.
    struct Transitions: Equatable {
        var sameEdge = 0
        /// Onto the next edge through a shared node.
        var successor = 0
        /// Onto an edge reached through one or more intermediate edges.
        var route = 0
        /// Onto an edge the graph does not connect (crossing or touching ways).
        var jump = 0
        var leaveMap = 0
        var rejoinMap = 0
    }

    let visits: [Visit]
    let edgePaces: [EdgePace]
    /// Share of the track's distance placed on the map, 0...1.
    let coverage: Double
    let confidence: Double
    let meanDistanceMeters: Double
    let transitions: Transitions
    /// Per frame: input point index, its state and distance to that state's edge.
    let frames: [(pointIndex: Int, edgeID: EdgeID?, distanceM: Double)]

    var segmentIDs: [EdgeID] { visits.compactMap(\.edgeID) }
}

/// Places a descent on the run and connection edges of a graph by hidden
/// Markov map matching: the track is resampled every 10 m, each sample gets
/// the edges within 50 m as candidate states plus an off-map state, and
/// Viterbi picks the most likely sequence. A state's cost is its distance
/// from the fix (GPS noise around a trail centreline) and its disagreement
/// with the travel direction; a transition's cost compares the distance along
/// the graph between the two placements with the distance the fixes moved.
/// Edges that touch or cross without a shared node (common in OSM pistes)
/// can still be joined, at a fixed penalty, so a missing connector costs a
/// little evidence instead of rejecting the whole descent.
public struct TrailMatcher: Sendable {
    public let graph: Graph
    let tuning: Tuning

    public init(graph: Graph) {
        self.init(graph: graph, tuning: Tuning())
    }

    init(graph: Graph, tuning: Tuning) {
        self.graph = graph
        self.tuning = tuning
    }

    /// The model's constants, chosen by scoring the corpus at the published
    /// resorts (`MatchQualityTests`). Costs are negative log-likelihoods.
    struct Tuning: Sendable {
        /// Resampling step along the track, metres.
        var sampleSpacingM = 10.0
        /// Most frames per descent; longer tracks are resampled more coarsely.
        var maximumFrames = 2_000
        /// Candidate search radius, metres.
        var searchRadiusM = 50.0
        /// Most candidate edges kept per frame.
        var maximumCandidates = 8
        /// GPS and centreline noise, metres.
        var sigmaM = 20.0
        /// Weight of `1 - cos(heading difference)`.
        var headingWeight = 2.5
        /// Travel more than this far from an edge's direction cannot be on it.
        var maximumHeadingDeltaDeg = 110.0
        /// Cost of a frame off the map (about a fix 60 m from every trail).
        var offMapCost = 4.5
        /// Cost of leaving or rejoining the map.
        var offMapSwitchCost = 1.5
        /// Cost of moving onto the next edge of the same trail through the
        /// graph: OSM splits one trail into many ways, which is not a choice.
        var edgeSwitchCost = 0.1
        /// Cost of moving onto another trail through the graph. Skiers change
        /// trail far less often than the map splits them, and this is what
        /// keeps GPS drift from walking the track onto a parallel trail and
        /// back.
        var trailSwitchCost = 2.0
        /// Cost of moving onto an edge the graph does not connect.
        var jumpCost = 4.0
        /// The same, onto another way of the same trail (a split with no
        /// shared node).
        var trailJumpCost = 1.0
        /// Scale of the route-versus-fix distance mismatch, metres (at least).
        var mismatchScaleM = 20.0
        /// Longest route searched between two placements, metres.
        var routeBoundM = 1_500.0
    }

    /// Least share of the track's distance on the map for a match.
    static let minimumCoverage = 0.5

    /// Least edge-local evidence for a pace measurement. Boundary slivers
    /// below these stay in the matched sequence but cannot train routing.
    private let minimumEdgeObservationDuration: TimeInterval = 5
    private let minimumEdgeObservationDistance = 15.0
    private let maximumEdgeIntervalDuration: TimeInterval = 30
    /// Limits for `approximateEdge`: a display name only, never a match.
    private let relaxedMatchThreshold = 120.0
    private let relaxedBearingThreshold = 70.0

    // MARK: - Public surface

    /// Matches a descent against a bundle's graph. The result is keyed by the
    /// bundle and `MatcherVersion`; it is a derivation and can be re-run.
    public static func match(descent: Descent, in bundle: ResortBundle) -> DescentMatch {
        match(descent: descent, in: bundle, tuning: Tuning())
    }

    static func match(descent: Descent, in bundle: ResortBundle, tuning: Tuning) -> DescentMatch {
        let matcher = TrailMatcher(graph: bundle.graph, tuning: tuning)
        let points = descent.points
        switch matcher.evaluate(points) {
        case .failure(let failure):
            return DescentMatch(bundleID: bundle.id, matched: [], coverage: 0, confidence: 0, failure: failure)
        case .success(let match):
            return shape(match, descent: descent, bundle: bundle)
        }
    }

    /// A run to name an unmatched descent after: the closest one overall
    /// within 120 m and 70° of the track's start-to-end bearing, else the one
    /// nearest the track's centroid within 300 m. For display only; it is not
    /// a match and must never feed pace learning.
    public func approximateEdge(for points: [TrackPoint]) -> Edge? {
        bestEffortNameMatch(for: points) ?? nearestRunEdgeByCentroid(for: points)
    }

    // MARK: - Shaping

    private static func shape(_ match: TrailMatch, descent: Descent, bundle: ResortBundle) -> DescentMatch {
        let points = descent.points
        let graph = bundle.graph
        // A point without a clock takes its share of the descent's span.
        func time(_ index: Int) -> Date {
            if let timestamp = points[index].timestamp { return timestamp }
            let span = descent.endedAt.timeIntervalSince(descent.startedAt)
            let fraction = points.count > 1 ? Double(index) / Double(points.count - 1) : 0
            return descent.startedAt.addingTimeInterval(span * fraction)
        }
        func distance(_ from: Int, _ to: Int) -> Double {
            guard to > from else { return 0 }
            var total = 0.0
            for i in (from + 1)...to { total += Geo.haversineM(points[i - 1].coordinate, points[i].coordinate) }
            return total
        }

        // Visit spans: [first point, next visit's first point).
        struct Span {
            let edgeID: EdgeID?; let start: Int; let end: Int; let enterAt: Date; let exitAt: Date
            let progressM: Double
        }
        var spans: [Span] = []
        for (index, visit) in match.visits.enumerated() {
            let end = index + 1 < match.visits.count ? match.visits[index + 1].firstPoint : points.count - 1
            let enterAt = index == 0 ? descent.startedAt : time(visit.firstPoint)
            let exitAt = index + 1 < match.visits.count ? time(end) : descent.endedAt
            spans.append(Span(edgeID: visit.edgeID, start: visit.firstPoint, end: end,
                              enterAt: enterAt, exitAt: max(enterAt, exitAt), progressM: visit.progressM))
        }

        var paces: [EdgeID: EdgePace] = [:]
        for pace in match.edgePaces { paces[pace.edgeID] = pace }
        var observations: [MatchObservation] = []
        for span in spans {
            guard let edgeID = span.edgeID else { continue }
            // An edge visited twice keeps its pace on the first visit.
            let pace = paces.removeValue(forKey: edgeID)
            let moving = pace?.durationS ?? 0
            observations.append(MatchObservation(
                edgeID: edgeID, enterAt: span.enterAt, exitAt: span.exitAt, movingS: moving,
                stoppedS: max(0, span.exitAt.timeIntervalSince(span.enterAt) - moving),
                lengthM: pace?.distanceM ?? 0, peakSpeedMS: pace?.peakSpeedMS
            ))
        }

        // Sections: consecutive spans of one trail identity.
        var sections: [RunSection] = []
        for span in spans {
            let edge = span.edgeID.flatMap { graph.edge($0) }
            let group = edge?.group.flatMap { bundle.group($0) }
            let kind: RunSection.Kind = switch edge?.kind {
            case .run: .run
            case .connection: .connection
            default: .offMap
            }
            let name = [edge?.name, group?.name].compactMap { $0 }.first { !$0.isEmpty }
            var section = RunSection(
                kind: kind, name: name, groupID: edge?.group,
                difficulty: edge?.difficulty ?? group?.difficulty,
                edgeIDs: span.edgeID.map { [$0] } ?? [],
                enterAt: span.enterAt, exitAt: span.exitAt,
                distanceM: distance(span.start, span.end)
            )
            if let last = sections.last, last.sameTrail(as: section) {
                section = last.extended(over: section)
                sections.removeLast()
            }
            sections.append(section)
        }
        sections = RunSection.tidied(sections)

        let isMatched = match.coverage >= minimumCoverage && !observations.isEmpty
        guard isMatched else {
            let onMap = match.frames.filter { $0.edgeID != nil }.count
            return DescentMatch(
                bundleID: bundle.id, matched: [], coverage: match.coverage, confidence: 0,
                sections: sections,
                failure: .insufficientCoverage(matched: onMap, sampled: match.frames.count)
            )
        }

        // The label: the trail skied furthest, measured along the trail so
        // neither a long stop nor GPS jitter on the spot decides it, named
        // trails before unnamed, then its edge holding the most of it.
        var primaryEdgeID: EdgeID?
        let runs = sections.filter { $0.kind == .run }
        let labelled = runs.contains { $0.name != nil } ? runs.filter { $0.name != nil } : runs
        var byTrail: [String: Set<EdgeID>] = [:]
        var trailOrder: [String] = []
        var byEdge: [EdgeID: Double] = [:]
        for span in spans {
            if let id = span.edgeID { byEdge[id, default: 0] += span.progressM }
        }
        for section in labelled {
            let key = section.groupID.map { "g:" + $0.rawValue } ?? "n:" + (section.name ?? "")
            if byTrail[key] == nil { trailOrder.append(key) }
            byTrail[key, default: []].formUnion(section.edgeIDs)
        }
        func progress(_ key: String) -> Double { (byTrail[key] ?? []).reduce(0) { $0 + (byEdge[$1] ?? 0) } }
        if let main = trailOrder.max(by: { progress($0) < progress($1) }), let edges = byTrail[main] {
            primaryEdgeID = byEdge.filter { edges.contains($0.key) }
                .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        return DescentMatch(
            bundleID: bundle.id, matched: observations, coverage: match.coverage,
            confidence: match.confidence, primaryEdgeID: primaryEdgeID ?? observations.first?.edgeID,
            meanDistanceM: match.meanDistanceMeters, sections: sections
        )
    }

    // MARK: - Matching

    private struct Polyline {
        let edge: Edge
        let points: [SIMD2<Double>]
        /// Length before each vertex.
        let cumulative: [Double]
        var length: Double { cumulative[cumulative.count - 1] }
    }

    private struct Candidate {
        let line: Int
        let distance: Double
        let along: Double
        let position: SIMD2<Double>
        let headingQuality: Double
        let cost: Double
    }

    func evaluate(_ points: [TrackPoint]) -> Result<TrailMatch, TrailMatchFailure> {
        guard points.count >= 2, isDownhillOrElevationUnknown(points) else {
            return .failure(.invalidDescent)
        }
        // A local plane around the track is accurate to well under a metre at resort scale.
        let origin = points[0]
        let ky = 111_132.0, kx = 111_320.0 * cos(origin.lat * .pi / 180)
        func xy(_ lat: Double, _ lon: Double) -> SIMD2<Double> {
            SIMD2((lon - origin.lon) * kx, (lat - origin.lat) * ky)
        }
        let track = points.map { xy($0.lat, $0.lon) }
        var minimum = track[0], maximum = track[0]
        for p in track { minimum = pointwiseMin(minimum, p); maximum = pointwiseMax(maximum, p) }
        let margin = tuning.routeBoundM / 2
        minimum -= SIMD2(repeating: margin)
        maximum += SIMD2(repeating: margin)

        // Every directed traversal a skier can descend: runs and both ways of
        // a two-way connection. Lifts never carry a descent.
        var lines: [Polyline] = []
        var hasRun = false
        let traversals = graph.nodes.keys.flatMap { graph.outgoing(from: $0) }
            .filter { $0.kind != .lift && $0.geometry.count >= 2 }
            .sorted { $0.id < $1.id }
        for edge in traversals {
            hasRun = hasRun || edge.kind == .run
            let vertices = edge.geometry.map { xy($0.lat, $0.lon) }
            guard vertices.contains(where: { all($0 .>= minimum) && all($0 .<= maximum) }) else { continue }
            var cumulative = [0.0]
            for i in 1..<vertices.count { cumulative.append(cumulative[i - 1] + length(vertices[i] - vertices[i - 1])) }
            guard cumulative[cumulative.count - 1] > 0 else { continue }
            lines.append(Polyline(edge: edge, points: vertices, cumulative: cumulative))
        }
        guard hasRun else { return .failure(.noTrailGeometry) }
        // One number per trail as the activity log names it (`RunSection`):
        // the bundle's group, which carries its name merges, else name and kind.
        var trailIndex: [String: Int] = [:]
        let trails = lines.map { line in
            let key = line.edge.group.map { "g:" + $0.rawValue }
                ?? "n:\(line.edge.name ?? ""):\(line.edge.kind.rawValue)"
            if let known = trailIndex[key] { return known }
            trailIndex[key] = trailIndex.count
            return trailIndex.count - 1
        }

        // Frames: a fix every `sampleSpacingM` of travel, plus the last.
        var travelled = [0.0]
        for i in 1..<track.count { travelled.append(travelled[i - 1] + length(track[i] - track[i - 1])) }
        let spacing = max(tuning.sampleSpacingM, travelled[travelled.count - 1] / Double(tuning.maximumFrames))
        var frameIndices = [0]
        for i in 1..<track.count where length(track[i] - track[frameIndices[frameIndices.count - 1]]) >= spacing {
            frameIndices.append(i)
        }
        if frameIndices.count > 1, frameIndices[frameIndices.count - 1] != track.count - 1,
           length(track[track.count - 1] - track[frameIndices[frameIndices.count - 1]]) > 1 {
            frameIndices.append(track.count - 1)
        }

        let grid = SegmentGrid(lines: lines.map(\.points), radius: tuning.searchRadiusM)
        let frames: [[Candidate]] = frameIndices.map { index in
            let headings = travelHeadings(at: index, track: track, travelled: travelled)
            return candidates(at: track[index], headings: headings, lines: lines, grid: grid)
        }

        // Shortest distances between nodes over the descendable network, memoized per source.
        var nodeIndex: [NodeID: Int] = [:]
        for line in lines {
            if nodeIndex[line.edge.from] == nil { nodeIndex[line.edge.from] = nodeIndex.count }
            if nodeIndex[line.edge.to] == nil { nodeIndex[line.edge.to] = nodeIndex.count }
        }
        var adjacency = Array(repeating: [(to: Int, length: Double)](), count: nodeIndex.count)
        for line in lines {
            if let a = nodeIndex[line.edge.from], let b = nodeIndex[line.edge.to] {
                adjacency[a].append((b, line.length))
            }
        }
        var routes: [Int: [Int: Double]] = [:]
        func routeDistance(_ from: NodeID, _ to: NodeID) -> Double? {
            guard let a = nodeIndex[from], let b = nodeIndex[to] else { return nil }
            if a == b { return 0 }
            if routes[a] == nil { routes[a] = Self.boundedDijkstra(from: a, adjacency: adjacency, bound: tuning.routeBoundM) }
            return routes[a]?[b]
        }

        // Viterbi. State `count` of a frame is off the map.
        var cost: [Double] = frames[0].map(\.cost) + [tuning.offMapCost]
        var back: [[Int]] = [Array(repeating: -1, count: cost.count)]
        var kinds: [[UInt8]] = [Array(repeating: 0, count: cost.count)]
        for t in 1..<frames.count {
            let previous = frames[t - 1], current = frames[t]
            let step = length(track[frameIndices[t]] - track[frameIndices[t - 1]])
            let scale = max(tuning.mismatchScaleM, 0.3 * step)
            var next = Array(repeating: Double.infinity, count: current.count + 1)
            var pointer = Array(repeating: -1, count: current.count + 1)
            var kind = Array(repeating: UInt8(0), count: current.count + 1)
            let offPrevious = previous.count
            for (j, b) in current.enumerated() {
                let lineB = lines[b.line]
                for (i, a) in previous.enumerated() where cost[i].isFinite {
                    let lineA = lines[a.line]
                    var transition: Double
                    var how: UInt8
                    if a.line == b.line {
                        transition = abs(b.along - a.along - step) / scale
                        how = 1
                    } else {
                        let sameTrail = trails[a.line] == trails[b.line]
                        let jump = (sameTrail ? tuning.trailJumpCost : tuning.jumpCost)
                            + abs(length(b.position - a.position) - step) / scale
                        transition = jump
                        how = 4
                        if let between = routeDistance(lineA.edge.to, lineB.edge.from) {
                            let route = (lineA.length - a.along) + between + b.along
                            let viaGraph = (sameTrail ? tuning.edgeSwitchCost : tuning.trailSwitchCost)
                                + abs(route - step) / scale
                            if viaGraph <= jump {
                                transition = viaGraph
                                how = between == 0 ? 2 : 3
                            }
                        }
                    }
                    let total = cost[i] + transition
                    if total < next[j] { next[j] = total; pointer[j] = i; kind[j] = how }
                }
                let rejoin = cost[offPrevious] + tuning.offMapSwitchCost
                if rejoin < next[j] { next[j] = rejoin; pointer[j] = offPrevious; kind[j] = 6 }
                next[j] += b.cost
            }
            let off = current.count
            for i in 0...previous.count where cost[i].isFinite {
                let total = cost[i] + (i == offPrevious ? 0 : tuning.offMapSwitchCost)
                if total < next[off] { next[off] = total; pointer[off] = i; kind[off] = i == offPrevious ? 0 : 5 }
            }
            next[off] += tuning.offMapCost
            cost = next
            back.append(pointer)
            kinds.append(kind)
        }

        var state = cost.indices.min { cost[$0] != cost[$1] ? cost[$0] < cost[$1] : $0 < $1 } ?? 0
        var states = Array(repeating: 0, count: frames.count)
        var transitions = TrailMatch.Transitions()
        for t in stride(from: frames.count - 1, through: 0, by: -1) {
            states[t] = state
            if t > 0 {
                switch kinds[t][state] {
                case 1: transitions.sameEdge += 1
                case 2: transitions.successor += 1
                case 3: transitions.route += 1
                case 4: transitions.jump += 1
                case 5: transitions.leaveMap += 1
                case 6: transitions.rejoinMap += 1
                default: break
                }
                state = back[t][state]
            }
        }

        var assigned: [(pointIndex: Int, edgeID: EdgeID?, distanceM: Double)] = []
        var visits: [TrailMatch.Visit] = []
        var onMapDistance = 0.0, totalDistance = 0.0, distanceSum = 0.0, headingSum = 0.0, onMapFrames = 0
        for (t, s) in states.enumerated() {
            let candidate = s < frames[t].count ? frames[t][s] : nil
            let edgeID = candidate.map { lines[$0.line].edge.id }
            assigned.append((frameIndices[t], edgeID, candidate?.distance ?? .infinity))
            if visits.last?.edgeID != edgeID || visits.isEmpty {
                visits.append(.init(edgeID: edgeID, firstPoint: frameIndices[t]))
                // Arriving from another edge, the skier has already covered
                // the start of this one (up to the step the fixes moved).
                if let candidate, t > 0, states[t - 1] < frames[t - 1].count {
                    let step = length(track[frameIndices[t]] - track[frameIndices[t - 1]])
                    visits[visits.count - 1].progressM = min(candidate.along, step)
                }
            } else if let candidate, t > 0, states[t - 1] < frames[t - 1].count {
                visits[visits.count - 1].progressM += max(0, candidate.along - frames[t - 1][states[t - 1]].along)
            }
            if t > 0 {
                let step = length(track[frameIndices[t]] - track[frameIndices[t - 1]])
                totalDistance += step
                if candidate != nil { onMapDistance += step }
            }
            if let candidate {
                onMapFrames += 1
                distanceSum += candidate.distance
                headingSum += candidate.headingQuality
            }
        }
        let coverage = totalDistance > 0 ? onMapDistance / totalDistance : (onMapFrames > 0 ? 1 : 0)
        let meanDistance = onMapFrames > 0 ? distanceSum / Double(onMapFrames) : 0
        let distanceQuality = max(0, 1 - meanDistance / tuning.searchRadiusM)
        let headingQuality = onMapFrames > 0 ? headingSum / Double(onMapFrames) : 0
        let confidence = onMapFrames > 0
            ? min(1, 0.55 * coverage + 0.35 * distanceQuality + 0.10 * headingQuality) : 0

        // Every input point takes the state of the frame at or before it.
        var pointLines: [Int?] = Array(repeating: nil, count: points.count)
        for (t, s) in states.enumerated() {
            let end = t + 1 < frameIndices.count ? frameIndices[t + 1] : points.count
            let line = s < frames[t].count ? frames[t][s].line : nil
            for i in frameIndices[t]..<end { pointLines[i] = line }
        }
        let paces = edgePaces(points: points, track: track, pointLines: pointLines, lines: lines,
                              order: visits.compactMap(\.edgeID))

        return .success(TrailMatch(
            visits: visits, edgePaces: paces, coverage: coverage, confidence: confidence,
            meanDistanceMeters: meanDistance, transitions: transitions, frames: assigned
        ))
    }

    private func candidates(
        at point: SIMD2<Double>, headings: [SIMD2<Double>], lines: [Polyline], grid: SegmentGrid
    ) -> [Candidate] {
        var best: [Int: (distance: Double, along: Double, position: SIMD2<Double>, direction: SIMD2<Double>)] = [:]
        for (lineIndex, segment) in grid.segments(near: point) {
            let line = lines[lineIndex]
            let a = line.points[segment], b = line.points[segment + 1]
            let d = b - a
            let lengthSquared = dot(d, d)
            guard lengthSquared > 0 else { continue }
            let t = max(0, min(1, dot(point - a, d) / lengthSquared))
            let position = a + t * d
            let distance = length(point - position)
            guard distance <= tuning.searchRadiusM else { continue }
            if let current = best[lineIndex], current.distance <= distance { continue }
            let segmentLength = lengthSquared.squareRoot()
            best[lineIndex] = (distance, line.cumulative[segment] + t * segmentLength, position, d / segmentLength)
        }
        var result: [Candidate] = []
        for (lineIndex, projection) in best {
            var cost = 0.5 * (projection.distance / tuning.sigmaM) * (projection.distance / tuning.sigmaM)
            var quality = 0.8
            if !headings.isEmpty {
                let cosine = headings.map { dot($0, projection.direction) }.max() ?? 1
                guard cosine >= cos(tuning.maximumHeadingDeltaDeg * .pi / 180) else { continue }
                cost += tuning.headingWeight * (1 - cosine)
                quality = max(0, cosine)
            }
            result.append(Candidate(
                line: lineIndex, distance: projection.distance, along: projection.along,
                position: projection.position, headingQuality: quality, cost: cost
            ))
        }
        result.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.line < $1.line }
        return Array(result.prefix(tuning.maximumCandidates))
    }

    /// Directions of travel at a fix, as unit vectors: over about 20 m before
    /// it, after it, and across it. The window follows the trend of a carve
    /// rather than each sideways turn; offering each half keeps a fix where
    /// the skier stopped and turned back placed on the way it arrived. Empty
    /// when the track moves less than 8 m in every window.
    private func travelHeadings(at index: Int, track: [SIMD2<Double>], travelled: [Double]) -> [SIMD2<Double>] {
        var lower = index, upper = index
        while lower > 0, travelled[index] - travelled[lower - 1] <= 20 { lower -= 1 }
        while upper + 1 < track.count, travelled[upper + 1] - travelled[index] <= 20 { upper += 1 }
        if lower == index, index > 0 { lower -= 1 }
        if upper == index, index + 1 < track.count { upper += 1 }
        return [(lower, index), (index, upper), (lower, upper)].compactMap { from, to in
            let displacement = track[to] - track[from]
            let distance = length(displacement)
            return distance >= 8 ? displacement / distance : nil
        }
    }

    private static func boundedDijkstra(
        from source: Int, adjacency: [[(to: Int, length: Double)]], bound: Double
    ) -> [Int: Double] {
        var settled: [Int: Double] = [:]
        var heap = MinHeap()
        heap.push(0, source)
        while let (distance, node) = heap.pop() {
            guard settled[node] == nil else { continue }
            settled[node] = distance
            for (to, length) in adjacency[node] where settled[to] == nil {
                let next = distance + length
                if next <= bound { heap.push(next, to) }
            }
        }
        return settled
    }

    /// Attributes only intervals whose two endpoints were placed on the same
    /// edge and move forward along it. An interval that crosses a boundary is
    /// left out rather than guessed, so a sparse multi-edge track may yield no
    /// pace at all while its route is still reported.
    private func edgePaces(
        points: [TrackPoint], track: [SIMD2<Double>], pointLines: [Int?], lines: [Polyline], order: [EdgeID]
    ) -> [EdgePace] {
        func along(_ index: Int, _ line: Polyline) -> Double {
            var best = Double.infinity, bestAlong = 0.0
            let p = track[index]
            for s in 0..<(line.points.count - 1) {
                let a = line.points[s], d = line.points[s + 1] - a
                let lengthSquared = dot(d, d)
                guard lengthSquared > 0 else { continue }
                let t = max(0, min(1, dot(p - a, d) / lengthSquared))
                let distance = length(p - (a + t * d))
                if distance < best { best = distance; bestAlong = line.cumulative[s] + t * lengthSquared.squareRoot() }
            }
            return bestAlong
        }

        var distanceByEdge: [EdgeID: Double] = [:]
        var durationByEdge: [EdgeID: TimeInterval] = [:]
        var samplesByEdge: [EdgeID: [(distance: Double, duration: TimeInterval)]] = [:]
        for interval in GPXSpeedStats.movingIntervals(points) {
            // A valid descent can still contain reverse movement or GPS
            // backtracking; those intervals must not train forward pace. Nor
            // can a fix creeping at walking pace or jitter at a stop.
            guard interval.durationS <= maximumEdgeIntervalDuration,
                  interval.speedMS.isFinite, interval.speedMS >= GPXSpeedStats.pauseSpeedThreshold,
                  interval.speedMS <= GPXSpeedStats.peakSpeedCeiling,
                  let lineIndex = pointLines[interval.startIndex],
                  pointLines[interval.endIndex] == lineIndex else { continue }
            let line = lines[lineIndex]
            guard along(interval.endIndex, line) > along(interval.startIndex, line) else { continue }
            let id = line.edge.id
            distanceByEdge[id, default: 0] += interval.distanceM
            durationByEdge[id, default: 0] += interval.durationS
            samplesByEdge[id, default: []].append((interval.distanceM, interval.durationS))
        }

        var emitted: Set<EdgeID> = []
        return order.compactMap { edgeID in
            guard emitted.insert(edgeID).inserted,
                  let distance = distanceByEdge[edgeID], let duration = durationByEdge[edgeID],
                  distance >= minimumEdgeObservationDistance,
                  duration >= minimumEdgeObservationDuration else { return nil }
            let speed = distance / duration
            guard speed.isFinite, speed > 0, speed <= GPXSpeedStats.peakSpeedCeiling else { return nil }

            let samples = samplesByEdge[edgeID] ?? []
            var rollingPeak = speed
            if samples.count >= 3 {
                for index in 2..<samples.count {
                    let window = samples[(index - 2)...index]
                    let windowDuration = window.reduce(0) { $0 + $1.duration }
                    if windowDuration > 0 {
                        rollingPeak = max(rollingPeak, window.reduce(0) { $0 + $1.distance } / windowDuration)
                    }
                }
            }
            return EdgePace(
                edgeID: edgeID, speedMS: speed,
                peakSpeedMS: min(rollingPeak, GPXSpeedStats.peakSpeedCeiling),
                durationS: duration, distanceM: distance
            )
        }
    }

    // MARK: - Naming fallbacks

    /// The closest run under the relaxed limits (120 m mean distance, 70° from
    /// the track's start-to-end bearing). Canonical run edges are directed
    /// downhill, so the reverse bearing is not accepted.
    func bestEffortNameMatch(for points: [TrackPoint]) -> Edge? {
        guard points.count >= 2, isDownhillOrElevationUnknown(points),
              let first = points.first, let last = points.last else { return nil }
        let trackBearing = Geo.bearingDeg(from: first.coordinate, to: last.coordinate)

        var bestEdge: Edge?
        var bestScore = Double.infinity
        for edge in graph.edges where edge.kind == .run && edge.geometry.count >= 2 {
            if let a = edge.geometry.first, let b = edge.geometry.last,
               bearingDelta(trackBearing, Geo.bearingDeg(from: a.coordinate, to: b.coordinate))
                > relaxedBearingThreshold {
                continue
            }
            let total = points.reduce(0) { $0 + perpendicularDistance(point: $1, to: edge) }
            let score = total / Double(points.count)
            if score < bestScore {
                bestScore = score
                bestEdge = edge
            }
        }
        return bestScore < relaxedMatchThreshold ? bestEdge : nil
    }

    /// The run nearest the track's centroid, ignoring bearing, capped at 300 m
    /// so an edge on the other side of a peak is not picked up.
    func nearestRunEdgeByCentroid(for points: [TrackPoint]) -> Edge? {
        guard points.count >= 2, isDownhillOrElevationUnknown(points) else { return nil }
        // A mean of latitudes and longitudes is fine at resort scale.
        let count = Double(points.count)
        let centroid = TrackPoint(
            lat: points.reduce(0) { $0 + $1.lat } / count,
            lon: points.reduce(0) { $0 + $1.lon } / count
        )
        var bestEdge: Edge?
        var bestDistance = Double.infinity
        for edge in graph.edges where edge.kind == .run && edge.geometry.count >= 2 {
            let distance = perpendicularDistance(point: centroid, to: edge)
            if distance < bestDistance {
                bestDistance = distance
                bestEdge = edge
            }
        }
        return bestDistance < 300 ? bestEdge : nil
    }

    private func perpendicularDistance(point: TrackPoint, to edge: Edge) -> Double {
        let ky = 111_132.0, kx = 111_320.0 * cos(point.lat * .pi / 180)
        var best = Double.infinity
        for index in 1..<edge.geometry.count {
            let a = SIMD2((edge.geometry[index - 1].lon - point.lon) * kx, (edge.geometry[index - 1].lat - point.lat) * ky)
            let b = SIMD2((edge.geometry[index].lon - point.lon) * kx, (edge.geometry[index].lat - point.lat) * ky)
            let d = b - a
            let lengthSquared = dot(d, d)
            let t = lengthSquared > 0 ? max(0, min(1, -dot(a, d) / lengthSquared)) : 0
            best = min(best, length(a + t * d))
        }
        return best
    }

    private func bearingDelta(_ lhs: Double, _ rhs: Double) -> Double {
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    private func isDownhillOrElevationUnknown(_ points: [TrackPoint]) -> Bool {
        let elevations = points.compactMap(\.elevationM)
        guard let first = elevations.first, let last = elevations.last else { return true }
        return last - first <= 3
    }
}

// MARK: - Plane geometry and heap

// The `simd` module is Apple-only; these keep the package building on Linux.
private func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
private func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

private struct MinHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ key: Double, _ value: Int) {
        items.append((key, value))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].0 < items[parent].0 else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
                if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
                if smallest == parent { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return top
    }
}
