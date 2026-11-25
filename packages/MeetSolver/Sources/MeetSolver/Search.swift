import Foundation
import MountainCore

/// A routing origin checked against the graph. An interior origin keeps its
/// directed approach edge and charges only the remainder (I-12).
struct ResolvedOrigin {
    let startNode: NodeID
    let approachEdge: Edge?
    let remainingFraction: Double
    let positionUncertaintyM: Double

    /// Share of the approach edge already behind the skier.
    var startFraction: Double { approachEdge == nil ? 0 : 1 - remainingFraction }

    init?(_ origin: RoutingOrigin, graph: Graph) {
        let accuracy = origin.fixAccuracyM
        positionUncertaintyM = accuracy.isFinite ? max(0, min(150, accuracy.rounded())) : 0
        switch origin.kind {
        case .node(let id):
            guard graph.nodes[id] != nil else { return nil }
            startNode = id
            approachEdge = nil
            remainingFraction = 1
        case .onEdge(let id, let fraction):
            guard let edge = graph.edge(id), fraction.isFinite else { return nil }
            startNode = edge.from
            approachEdge = edge
            // Quantized to a thousandth and never zero: the skier is on the edge.
            let along = max(0, min(1, fraction))
            remainingFraction = Double(max(1, min(1_000, Int(((1 - along) * 1_000).rounded())))) / 1_000
        }
    }

    func startFraction(forFirstEdge id: EdgeID?) -> Double {
        approachEdge?.id == id ? startFraction : 0
    }
}

/// One non-dominated way of reaching a node.
struct Label {
    let id: Int
    let node: NodeID
    let time: Double
    let uncertainty: RouteTimeUncertainty
    /// User-visible trail and lift changes so far; kept apart from time so ETAs
    /// stay physical.
    let transitions: Int
    let previous: Int?
    let via: EdgeID?
    /// Whole metres of run above the skier's own level so far. Always 0 except in
    /// an easiest-way-down search, where it is the first thing compared.
    var aboveLimitM: Double = 0

    var variance: Double { uncertainty.varianceTime }
    var lastActionIdentity: String? { uncertainty.lastActionIdentity }
    /// Whether an outgoing lift edge would continue a ride already boarded; kept
    /// distinct per physical edge.
    var liftArrivalState: EdgeID? {
        lastActionIdentity?.hasPrefix("lift:") == true ? via : nil
    }
    var simplicityPenaltyS: Double { RouteSimplicity.penaltyS(forTransitionCount: transitions) }
    var reliabilityScore: Double {
        time + Scoring.cvarBeta * variance.squareRoot() + simplicityPenaltyS
    }

    func dominates(_ other: Label) -> Bool {
        aboveLimitM <= other.aboveLimitM
            && lastActionIdentity == other.lastActionIdentity
            && liftArrivalState == other.liftArrivalState
            && time <= other.time && variance <= other.variance
            && uncertainty.currentActionStdS <= other.uncertainty.currentActionStdS
            && transitions <= other.transitions
    }

    static func preferred(_ lhs: Label, _ rhs: Label) -> Bool {
        if lhs.aboveLimitM != rhs.aboveLimitM { return lhs.aboveLimitM < rhs.aboveLimitM }
        if lhs.reliabilityScore != rhs.reliabilityScore {
            return lhs.reliabilityScore < rhs.reliabilityScore
        }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.variance != rhs.variance { return lhs.variance < rhs.variance }
        if lhs.transitions != rhs.transitions { return lhs.transitions < rhs.transitions }
        let l = lhs.via?.rawValue ?? "", r = rhs.via?.rawValue ?? ""
        if l != r { return l < r }
        return lhs.id < rhs.id
    }
}

/// The outcome of one skier's search: for every reached node a bounded Pareto
/// frontier, best first, with every label's parent chain intact.
struct SearchResult {
    let frontier: [NodeID: [Label]]
    let labels: [Label]

    func best(at node: NodeID) -> Label? { frontier[node]?.first }
    func labels(at node: NodeID) -> [Label] { frontier[node] ?? [] }
    func reaches(_ node: NodeID) -> Bool { frontier[node] != nil }

    /// Edges from the origin to `label`, in travel order.
    func path(to label: Label, graph: Graph) -> [Edge] {
        var path: [Edge] = []
        var current: Label? = label
        while let entry = current, let via = entry.via {
            if let edge = graph.edge(via) { path.append(edge) }
            current = entry.previous.map { labels[$0] }
        }
        return path.reversed()
    }
}

enum Search {
    private struct Queued {
        let label: Int
        let node: NodeID
        let aboveLimitM: Double
        let score: Double
        let time: Double
        let variance: Double
        let via: String
    }

    /// Label-setting search over arrival time. Each node keeps up to
    /// `maxLabels` labels that no other label beats on mean, variance,
    /// current-action uncertainty and action count together (I-02). Edges are
    /// expanded in sorted id order and ties broken by id, so the result does not
    /// depend on input order (I-13). `startTimeS` starts the clock later than the
    /// solve instant and `deadlineS` drops anything arriving after it; both exist
    /// for the lap suggestion, which searches a short window after an arrival.
    static func run(
        from origin: ResolvedOrigin, model: CostModel, maxLabels: Int,
        earlyExitTarget: NodeID? = nil, ignoreAbility: Bool = false,
        ignoreLiftDeadlineRisk: Bool = false, startTimeS: Double = 0, deadlineS: Double? = nil
    ) -> SearchResult {
        let graph = model.graph
        var labels: [Label] = []
        var frontier: [NodeID: [Int]] = [:]
        var heap = BinaryHeap<Queued> { a, b in
            if a.aboveLimitM != b.aboveLimitM { return a.aboveLimitM < b.aboveLimitM }
            if a.score != b.score { return a.score < b.score }
            if a.time != b.time { return a.time < b.time }
            if a.variance != b.variance { return a.variance < b.variance }
            if a.node != b.node { return a.node < b.node }
            if a.via != b.via { return a.via < b.via }
            return a.label < b.label
        }

        let positionStd = origin.positionUncertaintyM / Scoring.positionUncertaintySpeedMS
        let start = Label(
            id: 0, node: origin.startNode, time: startTimeS,
            uncertainty: RouteTimeUncertainty(initialVariance: positionStd * positionStd),
            transitions: 0, previous: nil, via: nil
        )
        labels.append(start)
        frontier[origin.startNode] = [0]
        heap.insert(Queued(
            label: 0, node: origin.startNode, aboveLimitM: 0, score: start.reliabilityScore, time: startTimeS,
            variance: start.variance, via: ""
        ))
        let limit = max(1, maxLabels)
        func aboveLimitM(_ edge: Edge, _ remaining: Double) -> Double {
            guard model.difficultyCeilingRank != nil, edge.kind == .run, !model.isWithinLevel(edge)
            else { return 0 }
            return max(1, (edge.lengthM * remaining).rounded())
        }

        while let queued = heap.extractMin() {
            // Lazy deletion: a label dropped by dominance or the cap stays queued.
            guard frontier[queued.node]?.contains(queued.label) == true else { continue }
            let current = labels[queued.label]
            if current.node == earlyExitTarget { break }
            let previousEdge = current.via.flatMap { graph.edge($0) }

            for edge in graph.outgoing(from: current.node) {
                var remaining = 1.0
                if current.previous == nil, let approach = origin.approachEdge {
                    guard edge.id == approach.id else { continue }
                    remaining = origin.remainingFraction
                }
                guard let cost = model.evaluate(
                    edge, elapsedS: current.time, approachVariance: current.variance,
                    remainingFraction: remaining, previous: previousEdge,
                    ignoreAbility: ignoreAbility, ignoreLiftDeadlineRisk: ignoreLiftDeadlineRisk
                ) else { continue }
                if let deadlineS, current.time + cost.seconds > deadlineS { continue }

                var uncertainty = current.uncertainty
                uncertainty.append(edge: edge, variance: cost.variance)
                let identity = RouteSimplicity.actionIdentity(for: edge)
                let candidate = Label(
                    id: labels.count, node: edge.to, time: current.time + cost.seconds,
                    uncertainty: uncertainty,
                    transitions: current.transitions
                        + (current.lastActionIdentity.map { $0 == identity ? 0 : 1 } ?? 0),
                    previous: current.id, via: edge.id,
                    aboveLimitM: current.aboveLimitM + aboveLimitM(edge, remaining)
                )

                let existing = (frontier[edge.to] ?? []).map { labels[$0] }
                if existing.contains(where: { $0.dominates(candidate) }) { continue }
                labels.append(candidate)
                var kept = existing.filter { !candidate.dominates($0) } + [candidate]
                kept.sort(by: Label.preferred)
                if kept.count > limit {
                    // The detour limit is anchored to the fastest mean arrival, so
                    // the cap must never drop that label.
                    let fastest = kept.min {
                        $0.time != $1.time ? $0.time < $1.time : Label.preferred($0, $1)
                    }!
                    let head = Array(kept.prefix(limit))
                    kept = head.contains { $0.id == fastest.id } ? head : head.dropLast() + [fastest]
                }
                frontier[edge.to] = kept.map(\.id)
                if kept.contains(where: { $0.id == candidate.id }) {
                    heap.insert(Queued(
                        label: candidate.id, node: edge.to,
                        aboveLimitM: candidate.aboveLimitM, score: candidate.reliabilityScore,
                        time: candidate.time, variance: candidate.variance, via: edge.id.rawValue
                    ))
                }
            }
        }

        var resolved: [NodeID: [Label]] = [:]
        for (node, ids) in frontier {
            // A skier part-way along an edge is past its source node; that node is
            // never offered as a zero-second rendezvous behind them.
            if origin.approachEdge != nil, node == origin.startNode { continue }
            var kept = ids.map { labels[$0] }.sorted(by: Label.preferred)
            // Easiest way down: only the least metres above the level reach a
            // node, so no later pick trades them for time.
            if let least = kept.first?.aboveLimitM, least > 0 {
                kept = kept.filter { $0.aboveLimitM == least }
            }
            resolved[node] = kept
        }
        return SearchResult(frontier: resolved, labels: labels)
    }
}
