import Foundation

/// A run's height along its length, for the run card's profile: distance
/// from the top against elevation, at evenly spaced points.
public enum ElevationProfile {
    public struct Point: Hashable, Sendable {
        /// Horizontal distance from the top.
        public var distanceM: Double
        public var eleM: Double

        public init(distanceM: Double, eleM: Double) {
            self.distanceM = distanceM
            self.eleM = eleM
        }
    }

    /// The profile of the longest way down a run's edges, top first, at
    /// `samples` evenly spaced points; empty when the edges hold no line.
    ///
    /// A run's edges are not always one chain in order: a run that splits
    /// round a tree island or has a side branch is several. The profile
    /// follows the longest path through them by their from→to links, so it is
    /// one line a skier could take, never two branches drawn end to end.
    /// When that line is under half the run (pieces of one name the map does
    /// not join), there is no profile: it would show a part as the whole.
    public static func points(along edges: [Edge], samples: Int = 48) -> [Point] {
        let (line, lengthM) = longestLine(edges)
        let totalM = edges.filter { $0.geometry.count > 1 }.reduce(0) { $0 + $1.lengthM }
        guard line.count > 1, samples > 1, totalM > 0, lengthM >= totalM / 2 else { return [] }
        // Top first, whichever way the edges were drawn.
        let ordered = line[0].eleM >= line[line.count - 1].eleM ? line : line.reversed()

        var along = [0.0]
        along.reserveCapacity(ordered.count)
        for i in 1..<ordered.count {
            along.append(along[i - 1] + Geo.haversineM(ordered[i - 1].coordinate, ordered[i].coordinate))
        }
        guard let total = along.last, total > 0 else { return [] }

        var result: [Point] = []
        result.reserveCapacity(samples)
        var segment = 1
        for k in 0..<samples {
            let distance = total * Double(k) / Double(samples - 1)
            while segment < ordered.count - 1, along[segment] < distance { segment += 1 }
            let start = along[segment - 1], end = along[segment]
            let t = end > start ? min(1, max(0, (distance - start) / (end - start))) : 0
            let ele = ordered[segment - 1].eleM + (ordered[segment].eleM - ordered[segment - 1].eleM) * t
            result.append(Point(distanceM: distance, eleM: ele))
        }
        return result
    }

    /// The geometry of the longest from→to path through the edges, joined,
    /// and that path's length.
    static func longestLine(_ edges: [Edge]) -> (line: [GeoPoint], lengthM: Double) {
        let usable = edges.filter { $0.geometry.count > 1 }
        guard !usable.isEmpty else { return ([], 0) }
        let leaving = Dictionary(grouping: usable.indices, by: { usable[$0].from })

        var best: [NodeID: (length: Double, next: Int?)] = [:]
        var visiting: Set<NodeID> = []
        // Depth is bounded by the run's own edges; a loop (never expected on
        // a run) ends the path where it closes instead of recursing for ever.
        func longest(from node: NodeID) -> Double {
            if let known = best[node] { return known.length }
            guard !visiting.contains(node) else { return 0 }
            visiting.insert(node)
            var pick: (length: Double, next: Int?) = (0, nil)
            for index in leaving[node] ?? [] {
                let length = usable[index].lengthM + longest(from: usable[index].to)
                if length > pick.length { pick = (length, index) }
            }
            visiting.remove(node)
            best[node] = pick
            return pick.length
        }

        let starts = Set(usable.map(\.from))
        guard var node = starts.max(by: { longest(from: $0) < longest(from: $1) }) else { return ([], 0) }
        let lengthM = best[node]?.length ?? 0
        var line: [GeoPoint] = []
        var used: Set<Int> = []
        while let index = best[node]?.next, used.insert(index).inserted {
            let geometry = usable[index].geometry
            line.append(contentsOf: line.isEmpty ? geometry[...] : geometry.dropFirst())
            node = usable[index].to
        }
        return (line, lengthM)
    }
}
