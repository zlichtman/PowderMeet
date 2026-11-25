import Foundation
import MountainCore
@testable import DescentKit

/// What `MatchQualityTests` gates on, per corpus log and overall. The logs do
/// not say which trail was skied (Slopes records lifts and runs, not trail
/// names), so trail identity is scored on simulated descents, and the real
/// logs are scored on signals that need no labels: how much of each run is
/// placed and named, off-map time split by whether a mapped trail was near
/// (the matcher's doing) or not (a map gap or real off-piste), and the
/// flicker a matcher shows when GPS drift pulls it between parallel trails.
struct MatchScorecard {
    struct LogRow {
        var file: String
        var descents = 0, placed = 0, matched = 0, named = 0
        /// Descents placed on an edge, left it and came back to it.
        var repeats = 0
        /// A-B-A section patterns whose B lasts under 30 s.
        var flickers = 0
        var seconds = 0.0, namedSeconds = 0.0, unnamedSeconds = 0.0
        /// Off the map within 40 m of a mapped run or connection.
        var offNearSeconds = 0.0
        var offFarSeconds = 0.0
        var distanceM = 0.0, sectionChanges = 0

        var unmatched: Int { placed - matched }
    }

    struct SyntheticScore {
        var descents = 0, mainExact = 0, mainWithinOne = 0, unmatched = 0
        var fixes = 0, fixesOnTrueTrail = 0
        var sequences = 0, sequenceExact = 0

        mutating func add(_ other: SyntheticScore) {
            descents += other.descents; mainExact += other.mainExact; mainWithinOne += other.mainWithinOne
            unmatched += other.unmatched; fixes += other.fixes; fixesOnTrueTrail += other.fixesOnTrueTrail
            sequences += other.sequences; sequenceExact += other.sequenceExact
        }

        func share(_ count: Int, of total: Int) -> Double { total > 0 ? Double(count) / Double(total) : 0 }
        var mainExactShare: Double { share(mainExact, of: descents) }
        var mainWithinOneShare: Double { share(mainWithinOne, of: descents) }
        var unmatchedShare: Double { share(unmatched, of: descents) }
        var fixShare: Double { share(fixesOnTrueTrail, of: fixes) }
        var sequenceShare: Double { share(sequenceExact, of: sequences) }
    }

    // MARK: Real logs

    static func row(for url: URL, descents: [Descent], bundles: [ResortBundle]) -> LogRow {
        var row = LogRow(file: url.deletingPathExtension().lastPathComponent)
        for descent in descents {
            row.descents += 1
            guard let bundle = MatchQualityTests.resort(for: descent.points, in: bundles) else { continue }
            row.placed += 1
            let match = TrailMatcher.match(descent: descent, in: bundle)
            if match.isMatched { row.matched += 1 }
            if match.sections.contains(where: { $0.kind != .offMap && $0.name != nil }) { row.named += 1 }
            let stored = match.matched.map(\.edgeID.stored)
            if Set(stored).count < stored.count { row.repeats += 1 }
            let identities = match.sections.map(MatchQualityTests.identity)
            for i in identities.indices.dropFirst().dropLast()
            where identities[i - 1] == identities[i + 1] && match.sections[i].durationS < 30 {
                row.flickers += 1
            }
            row.sectionChanges += max(0, match.sections.count - 1)
            row.seconds += descent.endedAt.timeIntervalSince(descent.startedAt)
            for section in match.sections {
                row.distanceM += section.distanceM
                if section.kind == .offMap {
                    let near = shareNearATrail(descent.points, from: section.enterAt, to: section.exitAt, in: bundle.graph)
                    row.offNearSeconds += section.durationS * near
                    row.offFarSeconds += section.durationS * (1 - near)
                } else if section.name != nil {
                    row.namedSeconds += section.durationS
                } else {
                    row.unnamedSeconds += section.durationS
                }
            }
        }
        return row
    }

    /// Share of the fixes in a time window within 40 m of a run or connection.
    static func shareNearATrail(_ points: [TrackPoint], from start: Date, to end: Date, in graph: Graph) -> Double {
        let inside = points.filter { ($0.timestamp.map { $0 >= start && $0 < end }) ?? false }
        guard !inside.isEmpty else { return 0 }
        let stride = max(1, inside.count / 20)
        var near = 0, total = 0
        for index in Swift.stride(from: 0, to: inside.count, by: stride) {
            total += 1
            if nearestTrailM(inside[index], in: graph) <= 40 { near += 1 }
        }
        return Double(near) / Double(total)
    }

    static func nearestTrailM(_ point: TrackPoint, in graph: Graph) -> Double {
        let ky = 111_132.0, kx = 111_320.0 * cos(point.lat * .pi / 180)
        var best = Double.infinity
        for edge in graph.edges where edge.kind != .lift && edge.geometry.count >= 2 {
            for (a, b) in zip(edge.geometry, edge.geometry.dropFirst()) {
                let ax = (a.lon - point.lon) * kx, ay = (a.lat - point.lat) * ky
                let dx = (b.lon - a.lon) * kx, dy = (b.lat - a.lat) * ky
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
                let x = ax + t * dx, y = ay + t * dy
                best = min(best, (x * x + y * y).squareRoot())
            }
        }
        return best
    }

    // MARK: Simulated descents

    /// Descents a skier could really make on each bundle: from the top of a
    /// lift (standing there first), down a random chain of runs and
    /// connections to the next lift bottom or the end of the network, at 1 Hz,
    /// with speed changes, a stop, 2 m of fix noise and a slowly wandering
    /// GPS bias of up to 25 m, which is what pulls a matcher onto a parallel
    /// trail. Truth is the trail each fix was drawn on.
    static func simulated(_ bundle: ResortBundle, count: Int, seed: UInt64) -> SyntheticScore {
        var random = MatchQualityTests.Random(state: seed)
        var score = SyntheticScore()
        let graph = bundle.graph
        let tops = graph.edges.filter { edge in
            edge.kind == .run && edge.geometry.count >= 2 && graph.nodes[edge.from]?.kind == .liftTop
        }
        let starts = tops.isEmpty
            ? graph.edges.filter { $0.kind == .run && $0.lengthM > 150 && $0.geometry.count >= 2 } : tops
        guard !starts.isEmpty else { return score }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<count {
            var edge = starts[random.index(starts.count)]
            var path = [edge], length = edge.lengthM
            while length < 2_500 {
                if graph.nodes[edge.to]?.kind == .liftBottom, length > 600, random.next() < 0.7 { break }
                let next = graph.outgoing(from: edge.to).filter { $0.kind != .lift && $0.geometry.count >= 2 }
                guard !next.isEmpty else { break }
                edge = next[random.index(next.count)]
                path.append(edge)
                length += edge.lengthM
            }
            guard length >= 300 else { continue }

            var points: [TrackPoint] = [], truth: [String] = []
            var bias = (x: 0.0, y: 0.0), clock = 0.0
            var speed = 6 + random.next() * 8
            let stopAt = random.next() < 0.5 ? random.next() * length : -1
            var travelled = 0.0, stopped = false
            func emit(lat: Double, lon: Double, ele: Double, identity: String) {
                let ky = 111_132.0, kx = 111_320.0 * cos(lat * .pi / 180)
                bias.x = max(-25, min(25, bias.x * 0.995 + random.gaussian() * 1.5))
                bias.y = max(-25, min(25, bias.y * 0.995 + random.gaussian() * 1.5))
                let ex = bias.x + random.gaussian() * 2, ey = bias.y + random.gaussian() * 2
                points.append(TrackPoint(
                    lat: lat + ey / ky, lon: lon + ex / kx, elevationM: ele + random.gaussian() * 2,
                    timestamp: start.addingTimeInterval(clock)
                ))
                truth.append(identity)
                clock += 1
            }
            let first = path[0].geometry[0]
            for _ in 0..<6 { emit(lat: first.lat, lon: first.lon, ele: first.eleM, identity: MatchQualityTests.identity(path[0])) }
            var carry = 0.0
            for edge in path {
                let identity = MatchQualityTests.identity(edge)
                for (a, b) in zip(edge.geometry, edge.geometry.dropFirst()) {
                    let segment = Geo.haversineM(a.coordinate, b.coordinate)
                    guard segment > 0 else { continue }
                    var s = carry
                    while s < segment {
                        let f = s / segment
                        let lat = a.lat + (b.lat - a.lat) * f, lon = a.lon + (b.lon - a.lon) * f
                        let ele = a.eleM + (b.eleM - a.eleM) * f
                        if !stopped, stopAt >= 0, travelled + s >= stopAt {
                            stopped = true
                            for _ in 0..<25 { emit(lat: lat, lon: lon, ele: ele, identity: identity) }
                        }
                        emit(lat: lat, lon: lon, ele: ele, identity: identity)
                        speed = max(3, min(18, speed + random.gaussian() * 0.5))
                        s += speed
                    }
                    carry = s - segment
                    travelled += segment
                }
            }
            if let last = path.last?.geometry.last {
                for _ in 0..<6 { emit(lat: last.lat, lon: last.lon, ele: last.eleM, identity: MatchQualityTests.identity(path[path.count - 1])) }
            }
            // A path whose bundle elevations do not fall is still a descent.
            if let top = points.first?.elevationM, let bottom = points.last?.elevationM, bottom > top - 5 {
                for i in points.indices { points[i].elevationM = nil }
            }
            let descent = Descent(
                source: .gpx, startedAt: start, endedAt: start.addingTimeInterval(clock - 1), points: points
            )
            score.add(judge(TrailMatcher.match(descent: descent, in: bundle), points: points, truth: truth,
                            path: path, graph: graph))
        }
        return score
    }

    static func judge(
        _ match: DescentMatch, points: [TrackPoint], truth: [String], path: [Edge], graph: Graph
    ) -> SyntheticScore {
        var score = SyntheticScore(descents: 1)
        for (i, point) in points.enumerated() {
            guard let t = point.timestamp else { continue }
            score.fixes += 1
            if let section = match.sections.first(where: { $0.enterAt <= t && t < $0.exitAt }) ?? match.sections.last,
               MatchQualityTests.identity(section) == truth[i] {
                score.fixesOnTrueTrail += 1
            }
        }
        // The true main trail: the run identity drawn furthest.
        var lengths: [String: Double] = [:]
        for edge in path where edge.kind == .run { lengths[MatchQualityTests.identity(edge), default: 0] += edge.lengthM }
        guard match.isMatched else { score.unmatched = 1; return score }
        let main = lengths.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        let reported = match.primaryEdgeID.flatMap { graph.edge($0) }.map(MatchQualityTests.identity)
        if let main, reported == main { score.mainExact = 1 }
        // Within one: a trail the path really used, or one that meets the true
        // main trail at a node.
        if let reported, let main {
            let used = Set(path.map(MatchQualityTests.identity))
            let mainNodes = Set(path.filter { MatchQualityTests.identity($0) == main }.flatMap { [$0.from, $0.to] })
            let reportedNodes = graph.edges.filter { MatchQualityTests.identity($0) == reported }.flatMap { [$0.from, $0.to] }
            if used.contains(reported) || !mainNodes.isDisjoint(with: reportedNodes) { score.mainWithinOne = 1 }
        }
        // The ordered runs a skier would list: stretches of one trail lasting
        // at least 15 s, from each fix's truth and from the sections.
        func runs(_ stretches: [(identity: String, seconds: Double)]) -> [String] {
            var merged: [(identity: String, seconds: Double)] = []
            for stretch in stretches {
                if merged.last?.identity == stretch.identity { merged[merged.count - 1].seconds += stretch.seconds }
                else { merged.append(stretch) }
            }
            var result: [String] = []
            for stretch in merged where stretch.seconds >= 15 && stretch.identity != "off"
                && !stretch.identity.hasSuffix(":connection") {
                if result.last != stretch.identity { result.append(stretch.identity) }
            }
            return result
        }
        let truthRuns = runs(truth.map { ($0, 1) })
        let reportedRuns = runs(match.sections.map { (MatchQualityTests.identity($0), $0.durationS) })
        score.sequences = 1
        if truthRuns == reportedRuns { score.sequenceExact = 1 }
        return score
    }
}
