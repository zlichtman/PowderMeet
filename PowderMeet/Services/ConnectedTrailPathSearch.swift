import Foundation

/// The two best distinct edge sequences, not two assignments of the same
/// route. Geometry qualification belongs to TrailMatcher; this pure search
/// enforces directed connectivity and exposes indistinguishable alternatives.
nonisolated enum ConnectedTrailPathSearch {
    struct Candidate {
        let edgeID: String
        let sourceID: String
        let targetID: String
        let alongMeters: Double
        let cost: Double
        let isTerminalStationary: Bool
    }

    private struct Reference {
        let candidate: Int
        let rank: Int
    }

    private struct Label {
        let cost: Double
        let route: Int
        let parent: Reference?
    }

    private struct RouteKey: Hashable {
        let parent: Int
        let edgeID: String
    }

    static func resolve(_ frames: [[Candidate]]) -> Result<[Int], TrailMatchFailure> {
        guard let first = frames.first, !first.isEmpty else { return .failure(.invalidDescent) }
        var routeKeys: [RouteKey] = []
        var routeIDs: [RouteKey: Int] = [:]
        func extending(_ parent: Int = -1, with edgeID: String) -> Int {
            if parent >= 0, routeKeys[parent].edgeID == edgeID { return parent }
            let key = RouteKey(parent: parent, edgeID: edgeID)
            if let id = routeIDs[key] { return id }
            let id = routeKeys.count
            routeKeys.append(key)
            routeIDs[key] = id
            return id
        }
        func sequence(_ id: Int) -> [String] {
            var result: [String] = []
            var cursor = id
            while cursor >= 0 {
                result.append(routeKeys[cursor].edgeID)
                cursor = routeKeys[cursor].parent
            }
            return result.reversed()
        }

        var history: [[[Label]]] = [first.map {
            [Label(cost: $0.cost, route: extending(with: $0.edgeID), parent: nil)]
        }]
        for frameIndex in 1..<frames.count {
            let previous = frames[frameIndex - 1]
            let labels = history[frameIndex - 1]
            func precedes(_ a: Reference, _ b: Reference) -> Bool {
                let ac = labels[a.candidate][a.rank].cost
                let bc = labels[b.candidate][b.rank].cost
                if ac != bc { return ac < bc }
                if a.candidate != b.candidate { return a.candidate < b.candidate }
                return a.rank < b.rank
            }
            var sameEdge: [String: Int] = [:]
            var arrivals: [String: [Reference]] = [:]
            for i in previous.indices where !labels[i].isEmpty {
                sameEdge[previous[i].edgeID] = i
                let node = previous[i].targetID
                var best = arrivals[node, default: []]
                best += labels[i].indices.map { Reference(candidate: i, rank: $0) }
                // At most two labels belong to the current edge and must be
                // excluded from a junction transfer (especially a self-loop).
                // Four arrivals therefore retain the two best other routes.
                arrivals[node] = Array(best.sorted(by: precedes).prefix(4))
            }

            let current = frames[frameIndex]
            var next = Array(repeating: [Label](), count: current.count)
            for (i, candidate) in current.enumerated() {
                var parents: [Reference] = []
                if let p = sameEdge[candidate.edgeID],
                   candidate.alongMeters >= previous[p].alongMeters - 15 {
                    parents += labels[p].indices.map { Reference(candidate: p, rank: $0) }
                }
                if !candidate.isTerminalStationary {
                    parents += (arrivals[candidate.sourceID] ?? []).filter {
                        previous[$0.candidate].edgeID != candidate.edgeID
                    }.prefix(2)
                }
                var seen: Set<Int> = []
                for parent in parents.sorted(by: precedes) {
                    let prior = labels[parent.candidate][parent.rank]
                    let route = extending(prior.route, with: candidate.edgeID)
                    guard seen.insert(route).inserted else { continue }
                    next[i].append(Label(
                        cost: prior.cost + (candidate.isTerminalStationary ? 0 : candidate.cost),
                        route: route, parent: parent))
                    if next[i].count == 2 { break }
                }
            }
            guard next.contains(where: { !$0.isEmpty }) else {
                return .failure(.noConnectedTransition(frame: frameIndex,
                    previous: previous.indices.filter { !labels[$0].isEmpty }.map { previous[$0].edgeID },
                    next: current.map(\.edgeID)))
            }
            history.append(next)
        }

        let final = history[history.count - 1]
        let candidates = final.indices.flatMap { i in
            final[i].indices.map { Reference(candidate: i, rank: $0) }
        }.sorted { a, b in
            let ac = final[a.candidate][a.rank].cost
            let bc = final[b.candidate][b.rank].cost
            if ac != bc { return ac < bc }
            if a.candidate != b.candidate { return a.candidate < b.candidate }
            return a.rank < b.rank
        }
        guard let best = candidates.first else { return .failure(.missingPrimaryEdge) }
        let winner = final[best.candidate][best.rank]
        if let alternative = candidates.dropFirst().first(where: {
            final[$0.candidate][$0.rank].route != winner.route
        }) {
            let other = final[alternative.candidate][alternative.rank]
            // Floating-point equality tolerance only, NOT a calibrated GPS
            // error radius or a claim that other small margins are reliable.
            let tolerance = 1e-9 * max(1, abs(winner.cost), abs(other.cost))
            if other.cost - winner.cost <= tolerance {
                return .failure(.ambiguousConnectedRoutes(
                    best: sequence(winner.route), alternative: sequence(other.route)))
            }
        }

        var selected: [Int] = []
        var reference = best
        for frameIndex in frames.indices.reversed() {
            selected.append(reference.candidate)
            if frameIndex > 0 {
                guard let parent = history[frameIndex][reference.candidate][reference.rank].parent else {
                    return .failure(.missingPrimaryEdge)
                }
                reference = parent
            }
        }
        return .success(selected.reversed())
    }
}
