import Foundation
import MountainCore

public enum Polyline {
    /// Chaikin corner cutting: each pass replaces every segment with points at 25 %
    /// and 75 %, keeping the two ends where they are.
    public static func chaikinSmooth(_ line: [Coordinate], iterations: Int = 2) -> [Coordinate] {
        guard line.count > 2 else { return line }
        var result = line
        for _ in 0..<max(0, iterations) {
            var smoothed: [Coordinate] = [result[0]]
            smoothed.reserveCapacity(result.count * 2)
            for i in 0..<(result.count - 1) {
                let a = result[i], b = result[i + 1]
                smoothed.append(Coordinate(
                    lon: a.lon * 0.75 + b.lon * 0.25, lat: a.lat * 0.75 + b.lat * 0.25))
                smoothed.append(Coordinate(
                    lon: a.lon * 0.25 + b.lon * 0.75, lat: a.lat * 0.25 + b.lat * 0.75))
            }
            smoothed.append(result[result.count - 1])
            result = smoothed
        }
        return result
    }

    /// Drops the first `fraction` of a line by distance, leaving an interpolated
    /// vertex exactly where the remainder starts.
    public static func trimPolylineStart(_ line: [Coordinate], fraction: Double) -> [Coordinate] {
        guard line.count > 1, fraction > 0 else { return line }
        if fraction >= 1 { return Array(line.suffix(1)) }

        var lengths: [Double] = []
        lengths.reserveCapacity(line.count - 1)
        var total = 0.0
        for i in 1..<line.count {
            let length = Geo.haversineM(line[i - 1], line[i])
            lengths.append(length)
            total += length
        }
        guard total > 0 else { return line }

        let target = total * fraction
        var consumed = 0.0
        for (i, length) in lengths.enumerated() where length > 0 {
            guard consumed + length >= target else {
                consumed += length
                continue
            }
            let t = (target - consumed) / length
            let a = line[i], b = line[i + 1]
            let start = Coordinate(lon: a.lon + (b.lon - a.lon) * t, lat: a.lat + (b.lat - a.lat) * t)
            return [start] + Array(line.dropFirst(i + 1))
        }
        return Array(line.suffix(1))
    }

    static func coincide(_ a: Coordinate, _ b: Coordinate) -> Bool {
        abs(a.lon - b.lon) < 1e-6 && abs(a.lat - b.lat) < 1e-6
    }
}

/// Orders a group's edges into connected chains and joins their geometry.
public enum TrailChainGeometry {
    /// Edges in walking order. Deterministic for any input order: the walk starts at
    /// a terminal node (the top of a run when there is one), prefers the smallest
    /// edge id at every step and never turns round.
    public static func orderEdgeChain(_ edges: [Edge]) -> [Edge] {
        walk(edges).flatMap { $0.map(\.edge) }
    }

    /// One polyline per connected chain, shared vertices written once. A group whose
    /// edges do not all connect yields several lines rather than a line that jumps.
    public static func chains(_ edges: [Edge]) -> [[Coordinate]] {
        walk(edges).compactMap { chain in
            var line: [Coordinate] = []
            for step in chain {
                let coordinates = step.forward ? step.edge.coordinates : step.edge.coordinates.reversed()
                append(coordinates, to: &line)
            }
            return line.count >= 2 ? line : nil
        }
    }

    private static func append(_ coordinates: [Coordinate], to line: inout [Coordinate]) {
        if let last = line.last, let first = coordinates.first, Polyline.coincide(last, first) {
            line.append(contentsOf: coordinates.dropFirst())
        } else {
            line.append(contentsOf: coordinates)
        }
    }

    private static func walk(_ edges: [Edge]) -> [[(edge: Edge, forward: Bool)]] {
        let stable = edges.sorted { $0.id < $1.id }
        var byNode: [NodeID: [Edge]] = [:]
        for edge in stable {
            byNode[edge.from, default: []].append(edge)
            byNode[edge.to, default: []].append(edge)
        }

        var used: Set<EdgeID> = []
        var chains: [[(edge: Edge, forward: Bool)]] = []
        while used.count < stable.count {
            let remaining = stable.filter { !used.contains($0.id) }
            var degree: [NodeID: Int] = [:]
            var startsHere: Set<NodeID> = []
            for edge in remaining {
                degree[edge.from, default: 0] += 1
                degree[edge.to, default: 0] += 1
                startsHere.insert(edge.from)
            }
            let terminals = degree.filter { $0.value == 1 }.keys.sorted()
            // A terminal an edge leaves from is a top; a cycle has no terminal.
            guard let start = terminals.first(where: startsHere.contains) ?? terminals.first
                ?? degree.keys.sorted().first else { break }

            // A chain keeps the direction of its first step. Where a run splits
            // into two arms that meet again, a walk free to turn round went down
            // one arm and back up the other, and smoothing rounded that fold away
            // from the junction, leaving a gap before the run below it.
            var chain: [(edge: Edge, forward: Bool)] = []
            var node = start
            let unused = byNode[node]?.filter { !used.contains($0.id) } ?? []
            let forward = unused.contains { $0.from == node }
            while let next = byNode[node]?.first(where: {
                !used.contains($0.id) && (forward ? $0.from : $0.to) == node
            }) {
                used.insert(next.id)
                chain.append((next, forward))
                node = forward ? next.to : next.from
            }
            chains.append(chain)
        }
        return chains
    }
}
