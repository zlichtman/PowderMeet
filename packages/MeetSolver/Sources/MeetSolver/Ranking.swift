import Foundation
import MountainCore

/// The order rendezvous are ranked in (invariant I-03). One score in seconds,
/// lower is better: when the pair is together, plus the time one of them
/// stands idle (a lap skied while waiting is charged far less than standing),
/// plus more for any gap past five minutes, plus what it costs them to start skiing together from there,
/// with bounded terms for uncertainty, a harder-to-follow approach and a stop
/// that is poorly identified or a poor place to wait; exact tie-breaks follow.
struct RendezvousRank: Comparable, Sendable {
    let reliabilityScoreS: Double
    let latestArrivalS: Double
    /// |tA − tB|: how long the earlier skier is at the stop before the other.
    let waitSpreadS: Double
    /// The part of that gap the earlier skier spends on a lap instead of standing.
    let lapS: Double
    let uncertaintyS: Double
    let waitPenaltyAlpha: Double
    let approachSimplicityPenaltyS: Double
    /// 0...`Scoring.onwardMaximumS`; see `Ranking.onwardCostS`.
    let onwardCostS: Double
    /// Subtracted: a lodge late in the day or in bad weather.
    let stopCreditS: Double
    let confidencePenalty: Double
    let qualityPenalty: Double
    let stableID: RendezvousID

    init(
        latestArrivalS: Double, waitSpreadS: Double, lapS: Double = 0, uncertaintyS: Double,
        waitPenaltyAlpha: Double = Scoring.waitPenaltyAlpha,
        approachSimplicityPenaltyS: Double = 0, onwardCostS: Double = 0, stopCreditS: Double = 0,
        confidencePenalty: Double, qualityPenalty: Double, stableID: RendezvousID
    ) {
        self.latestArrivalS = latestArrivalS
        self.waitSpreadS = waitSpreadS
        self.lapS = max(0, min(waitSpreadS, lapS))
        self.waitPenaltyAlpha = waitPenaltyAlpha
        self.uncertaintyS = uncertaintyS
        self.approachSimplicityPenaltyS = approachSimplicityPenaltyS
        self.onwardCostS = onwardCostS
        self.stopCreditS = stopCreditS
        self.confidencePenalty = confidencePenalty
        self.qualityPenalty = qualityPenalty
        self.stableID = stableID
        reliabilityScoreS = latestArrivalS
            + waitPenaltyAlpha * (waitSpreadS - self.lapS)
            // Never dearer than standing, whatever alpha a caller overrides.
            + min(Scoring.lapWhileWaitingRate, waitPenaltyAlpha) * self.lapS
            // On the whole gap, so the lap's lower bound on the score still holds.
            + Scoring.unevenWaitRate * max(0, waitSpreadS - Scoring.waitLapMinimumWaitS)
            + Scoring.cvarBeta * uncertaintyS
            + approachSimplicityPenaltyS
            + onwardCostS
            - stopCreditS
            + Scoring.rendezvousConfidencePenaltyS * confidencePenalty
            + Scoring.rendezvousQualityPenaltyS * qualityPenalty
    }

    /// Seconds the earlier skier stands at the stop: the gap less their lap.
    var idleS: Double { waitSpreadS - lapS }

    /// The same stop with a different lap in the wait.
    func with(lapS: Double) -> RendezvousRank {
        with(lapS: lapS, onwardCostS: onwardCostS)
    }

    /// The same stop with a different onward cost.
    func with(onwardCostS: Double) -> RendezvousRank {
        with(lapS: lapS, onwardCostS: onwardCostS)
    }

    private func with(lapS: Double, onwardCostS: Double) -> RendezvousRank {
        RendezvousRank(
            latestArrivalS: latestArrivalS, waitSpreadS: waitSpreadS, lapS: lapS,
            uncertaintyS: uncertaintyS, waitPenaltyAlpha: waitPenaltyAlpha,
            approachSimplicityPenaltyS: approachSimplicityPenaltyS, onwardCostS: onwardCostS,
            stopCreditS: stopCreditS, confidencePenalty: confidencePenalty,
            qualityPenalty: qualityPenalty, stableID: stableID
        )
    }

    /// The longest lap a wait could hold: none under the minimum wait, else all
    /// of it but the return margin. Ranking with it gives a lower bound on the
    /// score, which lets the solver search for real laps only where they matter.
    static func longestPossibleLapS(waitSpreadS: Double) -> Double {
        waitSpreadS >= Scoring.waitLapMinimumWaitS
            ? max(0, waitSpreadS - Scoring.waitLapReturnMarginS) : 0
    }

    static func < (lhs: RendezvousRank, rhs: RendezvousRank) -> Bool {
        if lhs.reliabilityScoreS != rhs.reliabilityScoreS {
            return lhs.reliabilityScoreS < rhs.reliabilityScoreS
        }
        if lhs.latestArrivalS != rhs.latestArrivalS { return lhs.latestArrivalS < rhs.latestArrivalS }
        if lhs.idleS != rhs.idleS { return lhs.idleS < rhs.idleS }
        if lhs.waitSpreadS != rhs.waitSpreadS { return lhs.waitSpreadS < rhs.waitSpreadS }
        if lhs.uncertaintyS != rhs.uncertaintyS { return lhs.uncertaintyS < rhs.uncertaintyS }
        if lhs.approachSimplicityPenaltyS != rhs.approachSimplicityPenaltyS {
            return lhs.approachSimplicityPenaltyS < rhs.approachSimplicityPenaltyS
        }
        if lhs.onwardCostS != rhs.onwardCostS { return lhs.onwardCostS < rhs.onwardCostS }
        if lhs.confidencePenalty != rhs.confidencePenalty {
            return lhs.confidencePenalty < rhs.confidencePenalty
        }
        if lhs.qualityPenalty != rhs.qualityPenalty { return lhs.qualityPenalty < rhs.qualityPenalty }
        return lhs.stableID < rhs.stableID
    }
}

/// Bounded scoring for the skiing available after a rendezvous.
enum SharedLapUtility {
    static func scoreWithVariety(baseScore: Double, optionCount: Int) -> Double {
        let additional = min(2, max(0, optionCount - 1))
        return min(1, min(1, max(0, baseScore))
            + Double(additional) / 2 * Scoring.sharedRunVarietyMaximumUtilityBonus)
    }

    static func optionIdentity(for edge: Edge) -> String {
        if let group = edge.group, !group.rawValue.isEmpty { return "group:\(group)" }
        let name = (edge.name ?? "").lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "edge:\(edge.id.stored)" : "name:\(name)"
    }

    static func score(
        runLengthM: Double, verticalDropM: Double, actionTransitionCount: Int,
        downhillAccessS: Double, jointTerrainFit: Double
    ) -> Double {
        let length = min(1, max(0, runLengthM) / 1_200)
        let vertical = min(1, max(0, verticalDropM) / 400)
        let transitionCost = 0.08 * Double(max(0, actionTransitionCount))
        let delayed = max(0, downhillAccessS - Scoring.sharedDownhillAccessGraceS)
        let accessCost = min(1, delayed / Scoring.sharedDownhillAccessPenaltyWindowS)
            * Scoring.sharedDownhillAccessMaximumUtilityPenalty
        let fitCost = (1 - min(1, max(0, jointTerrainFit)))
            * Scoring.sharedTerrainFitMaximumUtilityPenalty
        return max(0, min(1, 0.60 * length + 0.40 * vertical - transitionCost - accessCost - fitCost))
    }

    /// The less comfortable skier's pace on a run relative to their own neutral
    /// pace for its marked difficulty; 1 means no modelled caution.
    static func jointTerrainFit(models: [CostModel], edge: Edge, traversalS: [Double]) -> Double {
        guard edge.kind == .run, edge.lengthM > 0, models.count == traversalS.count,
              !models.isEmpty else { return 1 }
        return zip(models, traversalS).map { model, actual in
            guard actual > 0 else { return 1.0 }
            let neutralSpeed = max(
                Traversal.Run.minViableSpeedMS,
                model.profile.baselineSpeedMS[model.effectiveDifficulty(edge)]
                    ?? Traversal.Run.fallbackSpeedMS
            )
            return min(1, max(0, (edge.lengthM / neutralSpeed) / actual))
        }.min() ?? 1
    }
}

enum Ranking {
    struct ApproachPair {
        let a: Label
        let b: Label

        var latestArrival: Double { max(a.time, b.time) }
        var jointUncertainty: Double { (a.variance + b.variance).squareRoot() }
        var simplicityPenaltyS: Double { max(a.simplicityPenaltyS, b.simplicityPenaltyS) }
        var reliabilityScore: Double {
            latestArrival + Scoring.cvarBeta * jointUncertainty + simplicityPenaltyS
        }
    }

    /// The most dependable pair of approaches to one stop, chosen jointly from
    /// the two bounded frontiers. Wait imbalance is deliberately absent: it ranks
    /// stops, and must never send a skier the long way round to use up a wait.
    static func bestApproachPair(
        at node: NodeID, _ resultA: SearchResult, _ resultB: SearchResult
    ) -> ApproachPair? {
        func reasonable(_ result: SearchResult) -> [Label] {
            let labels = result.labels(at: node)
            guard let fastest = labels.map(\.time).min() else { return [] }
            let allowance = max(
                Scoring.dependablePathMaximumExtraS,
                fastest * Scoring.dependablePathMaximumExtraFraction
            )
            return labels.filter { $0.time <= fastest + allowance }
        }
        func preferred(_ lhs: ApproachPair, over rhs: ApproachPair) -> Bool {
            if lhs.reliabilityScore != rhs.reliabilityScore {
                return lhs.reliabilityScore < rhs.reliabilityScore
            }
            if lhs.latestArrival != rhs.latestArrival { return lhs.latestArrival < rhs.latestArrival }
            if lhs.jointUncertainty != rhs.jointUncertainty {
                return lhs.jointUncertainty < rhs.jointUncertainty
            }
            if lhs.a.reliabilityScore != rhs.a.reliabilityScore {
                return lhs.a.reliabilityScore < rhs.a.reliabilityScore
            }
            if lhs.b.reliabilityScore != rhs.b.reliabilityScore {
                return lhs.b.reliabilityScore < rhs.b.reliabilityScore
            }
            if lhs.a.id != rhs.a.id { return lhs.a.id < rhs.a.id }
            return lhs.b.id < rhs.b.id
        }

        var best: ApproachPair?
        for a in reasonable(resultA) {
            for b in reasonable(resultB) {
                let candidate = ApproachPair(a: a, b: b)
                if best.map({ preferred(candidate, over: $0) }) ?? true { best = candidate }
            }
        }
        return best
    }

    // MARK: Leaving

    enum OnwardMove { case open, beyondAbility, none }

    /// Whether one skier, alone and within their own limits, has somewhere to go
    /// from `node` at `offsetS`: a run they can ski or a running lift they can
    /// ride, at the node or up to three connectors from it. A lift counts only
    /// if it does not strand them: where it lets them off they must again have a
    /// run they can ski or a lift they can ride. `.beyondAbility` means the only
    /// runs out are harder than they ski.
    static func onwardMove(from node: NodeID, model: CostModel, offsetS: Double) -> OnwardMove {
        let graph = model.graph
        var sawTooHard = false
        var visited: Set<NodeID> = []
        func hasMove(
            _ node: NodeID, offset: Double, previous: Edge?, connectorsLeft: Int, ridesLeft: Int
        ) -> Bool {
            guard visited.insert(node).inserted else { return false }
            for edge in graph.outgoing(from: node) {
                guard let seconds = model.traverseTime(edge, elapsedS: offset, previous: previous)
                else {
                    if edge.kind == .run, !model.isWithinAbility(edge), model.traverseTime(
                        edge, elapsedS: offset, previous: previous, ignoreAbility: true
                    ) != nil { sawTooHard = true }
                    continue
                }
                switch edge.kind {
                case .run:
                    return true
                case .lift:
                    // The next segment of a ride already boarded is the same ride.
                    let sameRide = LiftRideContinuation.isContinuation(from: previous, to: edge)
                    if !sameRide, ridesLeft == 0 { return true }
                    if hasMove(
                        edge.to, offset: offset + seconds, previous: edge,
                        connectorsLeft: connectorsLeft, ridesLeft: sameRide ? ridesLeft : ridesLeft - 1
                    ) { return true }
                case .connection:
                    if connectorsLeft > 0, hasMove(
                        edge.to, offset: offset + seconds, previous: edge,
                        connectorsLeft: connectorsLeft - 1, ridesLeft: ridesLeft
                    ) { return true }
                }
            }
            return false
        }
        if hasMove(node, offset: offsetS, previous: nil, connectorsLeft: 3, ridesLeft: 1) {
            return .open
        }
        return sawTooHard ? .beyondAbility : .none
    }

    /// The hard rule: a stop is eligible only if each skier can leave it within
    /// their own limits. A lodge or landmark is a place people go to stop, so one
    /// with nothing leading on (a base lodge, or any lodge after last chair) is
    /// still eligible; one whose only runs out are too hard for the skier is not.
    static func canLeave(_ point: Rendezvous, model: CostModel, offsetS: Double) -> Bool {
        switch onwardMove(from: point.nodeID, model: model, offsetS: offsetS) {
        case .open: true
        case .beyondAbility: false
        case .none: point.kind == .lodge || point.kind == .landmark
        }
    }

    // MARK: After the meet

    /// Seconds of "together later" a stop costs for what the pair can do next
    /// (weights and reasoning in `Scoring`). Zero for a full shared run that
    /// starts at the stop; the maximum when there is no shared run at all.
    static func onwardCostS(continuation: SharedContinuation?) -> Double {
        guard let continuation else { return Scoring.onwardMaximumS }
        let quality = min(1, max(0, continuation.quality))
        let access = min(Scoring.onwardAccessCapS, max(0, continuation.downhillAccessS))
        return Scoring.onwardRunValueS * (1 - quality) + Scoring.onwardAccessRate * access
    }

    /// Lift time left once the pair could first be together: the latest last
    /// chair among lifts both can get to. nil when they can reach no lift at
    /// all, so there is no lift day to run out of.
    static func liftTimeLeftS(
        afterOffsetS offsetS: Double, model: CostModel, _ searchA: SearchResult,
        _ searchB: SearchResult
    ) -> Double? {
        let lifts = model.graph.edges.filter {
            $0.kind == .lift && searchA.reaches($0.from) && searchB.reaches($0.from)
        }
        guard !lifts.isEmpty else { return nil }
        return lifts.map { model.secondsUntilLastChair($0, atOffset: offsetS) ?? 0 }.max()
    }

    private struct ContinuationPath {
        let first: Edge
        let lastID: EdgeID
        let edgeCount: Int
        let firstRun: Edge?
        let runLengthM: Double
        let verticalDropM: Double
        let groupCompletionS: Double
        let downhillAccessS: Double
        let jointTerrainFit: Double
        let runOptionIdentity: String
        let utility: Double
    }

    private struct RolloutState: Hashable {
        let node: NodeID
        let boardings: Int
        let firstRun: EdgeID?
    }

    /// Bounds of the rollout below. A real bundle splits one trail into many
    /// short edges, so the rollout is bounded by what the pair does (one lift
    /// ride, a few connectors, then skiing until the run is as long as the
    /// utility can reward) rather than by an edge count.
    private enum Rollout {
        static let maximumEdges = 24
        static let maximumConnectors = 3
        static let maximumBoardings = 1
        static let horizonS = 30.0 * 60
        static let fullRunLengthM = 1_200.0
        static let fullVerticalDropM = 400.0
    }

    /// The best useful first move both skiers can legally make after meeting:
    /// ski from the stop, or ride one lift and ski from where it lets them off.
    /// It must reach real shared downhill: a lift into a connector and a dead
    /// end is not a shared lap. Judged on the weaker skier throughout.
    static func sharedContinuation(
        at point: Rendezvous, models: [CostModel], bundle: ResortBundle, departureOffsetS: Double
    ) -> SharedContinuation? {
        guard !models.isEmpty else { return nil }
        let graph = bundle.graph
        // The first edge must still be possible after two people find each other.
        let readyOffset = departureOffsetS + Scoring.sharedMeetupHandoffS
        var paths: [ContinuationPath] = []
        // Best arrival so far at a node, per first run and lift use. Anything
        // that is not an improvement on it explores nothing new, which keeps the
        // rollout near-linear in the terrain it covers.
        var reached: [RolloutState: (runLength: Double, offset: Double)] = [:]
        var path: [Edge] = []
        var visited: Set<NodeID> = [point.nodeID]

        func search(
            from node: NodeID, offset: Double, runLength: Double, verticalDrop: Double,
            downhillAccess: Double?, fitWeightedM: Double, firstRun: Edge?, transitions: Int,
            boardings: Int, connectors: Int
        ) {
            guard path.count < Rollout.maximumEdges,
                  runLength < Rollout.fullRunLengthM || verticalDrop < Rollout.fullVerticalDropM
            else { return }
            let previous = path.last
            for edge in graph.outgoing(from: node) {
                var nextBoardings = boardings, nextConnectors = connectors
                switch edge.kind {
                case .run:
                    break
                case .lift:
                    // Once the pair is skiing, another lift is the next lap.
                    guard runLength == 0 else { continue }
                    if !LiftRideContinuation.isContinuation(from: previous, to: edge) {
                        nextBoardings += 1
                    }
                    guard nextBoardings <= Rollout.maximumBoardings else { continue }
                case .connection:
                    nextConnectors += 1
                    guard nextConnectors <= Rollout.maximumConnectors else { continue }
                }
                var slowest = 0.0
                var times: [Double] = []
                for model in models {
                    guard let seconds = model.traverseTime(edge, elapsedS: offset, previous: previous)
                    else { break }
                    times.append(seconds)
                    slowest = max(slowest, seconds)
                }
                guard times.count == models.count else { continue }
                let nextOffset = offset + slowest
                guard nextOffset - readyOffset <= Rollout.horizonS else { continue }
                let isRun = edge.kind == .run
                let edgeRunLength = isRun ? max(0, edge.lengthM) : 0
                let nextRunLength = runLength + edgeRunLength
                let nextVertical = verticalDrop + (isRun ? max(0, -edge.verticalM) : 0)
                let nextAccess = downhillAccess ?? (isRun ? offset - readyOffset : nil)
                let fit = isRun
                    ? SharedLapUtility.jointTerrainFit(models: models, edge: edge, traversalS: times)
                    : 1
                let nextFitWeighted = fitWeightedM + edgeRunLength * fit
                let nextFirstRun = firstRun ?? (isRun ? edge : nil)
                let nextTransitions = transitions + (previous.map { $0.kind != edge.kind ? 1 : 0 } ?? 0)

                if nextRunLength >= 75 || nextVertical >= 10 {
                    let terrainFit = nextRunLength > 0 ? nextFitWeighted / nextRunLength : 1
                    paths.append(ContinuationPath(
                        first: path.first ?? edge, lastID: edge.id, edgeCount: path.count + 1,
                        firstRun: nextFirstRun, runLengthM: nextRunLength,
                        verticalDropM: nextVertical, groupCompletionS: nextOffset - departureOffsetS,
                        downhillAccessS: nextAccess ?? 0, jointTerrainFit: terrainFit,
                        runOptionIdentity: nextFirstRun.map(SharedLapUtility.optionIdentity)
                            ?? "edge:\(edge.id.stored)",
                        utility: SharedLapUtility.score(
                            runLengthM: nextRunLength, verticalDropM: nextVertical,
                            actionTransitionCount: nextTransitions,
                            downhillAccessS: nextAccess ?? 0, jointTerrainFit: terrainFit
                        )
                    ))
                }
                // A lap usually closes at the base it began from; a run may prove
                // that loop, but the rollout never passes through a visited node.
                guard !visited.contains(edge.to) else { continue }
                let state = RolloutState(
                    node: edge.to, boardings: nextBoardings, firstRun: nextFirstRun?.id
                )
                if let best = reached[state] {
                    // Before any skiing the earlier arrival wins; after, the longer run.
                    let better = nextRunLength > best.runLength
                        || (nextRunLength == best.runLength && nextOffset < best.offset)
                    guard better else { continue }
                }
                reached[state] = (nextRunLength, nextOffset)
                path.append(edge)
                visited.insert(edge.to)
                search(
                    from: edge.to, offset: nextOffset, runLength: nextRunLength,
                    verticalDrop: nextVertical, downhillAccess: nextAccess,
                    fitWeightedM: nextFitWeighted, firstRun: nextFirstRun,
                    transitions: nextTransitions, boardings: nextBoardings,
                    connectors: nextConnectors
                )
                visited.remove(edge.to)
                path.removeLast()
            }
        }
        search(
            from: point.nodeID, offset: readyOffset, runLength: 0, verticalDrop: 0,
            downhillAccess: nil, fitWeightedM: 0, firstRun: nil, transitions: 0, boardings: 0,
            connectors: 0
        )

        // Paths are recorded in a fixed order (sorted edge ids), and `min` keeps
        // the first of equals, so the remaining ties are deterministic (I-13).
        guard let best = paths.min(by: { lhs, rhs in
            if lhs.utility != rhs.utility { return lhs.utility > rhs.utility }
            if lhs.edgeCount != rhs.edgeCount { return lhs.edgeCount < rhs.edgeCount }
            if lhs.groupCompletionS != rhs.groupCompletionS {
                return lhs.groupCompletionS < rhs.groupCompletionS
            }
            if lhs.first.id != rhs.first.id { return lhs.first.id < rhs.first.id }
            return lhs.lastID < rhs.lastID
        }) else { return nil }
        let first = best.first

        let minimumUtility = max(
            Scoring.sharedRunOptionMinimumUtility,
            best.utility - Scoring.sharedRunVarietyRelativeUtilityWindow
        )
        let optionCount = max(1, Set(paths.compactMap { path -> String? in
            path.utility >= minimumUtility
                && path.jointTerrainFit >= Scoring.sharedRunOptionMinimumTerrainFit
                ? path.runOptionIdentity : nil
        }).count)

        let kind: SharedContinuation.Kind = switch first.kind {
        case .run: .ski
        case .lift: .ride
        case .connection: .connect
        }
        func displayName(_ edge: Edge?) -> String? {
            let name = (edge?.name ?? edge?.group.flatMap { bundle.group($0)?.name })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }
        return SharedContinuation(
            edgeID: first.id, name: displayName(first), kind: kind,
            firstRunName: displayName(best.firstRun),
            sharedRunLengthM: best.runLengthM, sharedVerticalDropM: best.verticalDropM,
            downhillAccessS: best.downhillAccessS, jointTerrainFit: best.jointTerrainFit,
            sharedRunOptionCount: optionCount,
            quality: SharedLapUtility.scoreWithVariety(
                baseScore: best.utility, optionCount: optionCount
            )
        )
    }

    // MARK: Alternates

    struct Candidate {
        let point: Rendezvous
        /// Until `lapKnown`, ranked as if the wait held the longest possible lap;
        /// until `continuationKnown`, as if the onward cost were zero.
        var rank: RendezvousRank
        let a: Label
        let b: Label
        var continuation: SharedContinuation?
        var continuationKnown = false
        /// The part of the onward cost this stop is charged: less than all of it
        /// only at a lodge when stopping is the point.
        var onwardShare = 1.0
        /// The lap the earlier skier can fit into their wait, if any.
        var lap: Route?
        var lapKnown = false
        /// Skiers who cannot leave this stop within their limits. Non-empty only
        /// on a candidate the hard rule rejected.
        var stuck: [UUID] = []
    }

    /// Lift base or top node → the lift edge it belongs to (smallest id wins), so
    /// two stops served by one lift count as one zone.
    private static func liftZones(_ graph: Graph) -> [NodeID: EdgeID] {
        var bases: [NodeID: EdgeID] = [:]
        var tops: [NodeID: EdgeID] = [:]
        for edge in graph.edges where edge.kind == .lift {
            if bases[edge.from].map({ edge.id < $0 }) ?? true { bases[edge.from] = edge.id }
            if tops[edge.to].map({ edge.id < $0 }) ?? true { tops[edge.to] = edge.id }
        }
        return bases.merging(tops) { base, _ in base }
    }

    private static func lastLift(to label: Label, in search: SearchResult, graph: Graph) -> EdgeID? {
        var current: Label? = label
        while let entry = current, let via = entry.via {
            if graph.edge(via)?.kind == .lift { return via }
            current = entry.previous.map { search.labels[$0] }
        }
        return nil
    }

    private static func clusterKey(
        _ node: Node, zones: [NodeID: EdgeID], lastLift: EdgeID?
    ) -> String {
        if let edge = zones[node.id] ?? lastLift { return "lift:\(edge)" }
        // No lift relationship: a roughly 150 m grid still spreads alternates out.
        return "grid:\((node.lat * 1_000).rounded() / 10):\((node.lon * 1_000).rounded() / 10)"
    }

    /// Stop node → its area, named by the area's smallest node id. Areas are
    /// chained, so a base village whose end lifts are 600 m apart is still one
    /// place as long as stops in between link them. Chaining runs over the whole
    /// catalog, not just the stops this pair can reach, so an area does not
    /// change shape with who is asking.
    static func stopAreas(_ points: [Rendezvous], graph: Graph) -> [NodeID: NodeID] {
        let ids: [NodeID] = Set(points.map(\.nodeID)).sorted()
        let nodes: [Node] = ids.compactMap { graph.nodes[$0] }.sorted { (lhs: Node, rhs: Node) -> Bool in
            lhs.lat != rhs.lat ? lhs.lat < rhs.lat : lhs.id < rhs.id
        }
        var parent = Array(nodes.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        // Sorted by latitude, so only a short window of later nodes can be close.
        let latitudeWindow = Scoring.alternateAreaHorizontalM / 111_000
        for i in nodes.indices {
            var j = i + 1
            while j < nodes.count, nodes[j].lat - nodes[i].lat <= latitudeWindow {
                if abs(nodes[j].eleM - nodes[i].eleM) <= Scoring.alternateAreaVerticalM,
                   Geo.haversineM(nodes[i].coordinate, nodes[j].coordinate)
                    <= Scoring.alternateAreaHorizontalM {
                    let (a, b) = (root(i), root(j))
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
                j += 1
            }
        }
        var name: [Int: NodeID] = [:]
        for index in nodes.indices {
            let id = nodes[index].id
            name[root(index)] = min(name[root(index)] ?? id, id)
        }
        var areas: [NodeID: NodeID] = [:]
        for index in nodes.indices { areas[nodes[index].id] = name[root(index)] }
        return areas
    }

    /// Up to `count` alternates that read as different places, drawn in rank
    /// order from `candidate` (index 0 is the pick). The distance
    /// ladder is walked strict to loose and stops as soon as two real choices
    /// exist; `count` is a ceiling, never a quota to pad with near-duplicates.
    /// Within each step, stops in an area not yet shown and within
    /// `alternateElsewhere…` of the pick's score are taken first; the places
    /// left are then filled in rank order, so a crowded area is thinned, not
    /// banned, and nothing far worse jumps the queue.
    static func diverseAlternates(
        after best: Candidate, searchA: SearchResult, graph: Graph, areas: [NodeID: NodeID],
        count: Int, candidate: (Int) -> Candidate?
    ) -> [Candidate] {
        guard count > 0, let bestNode = graph.nodes[best.point.nodeID] else { return [] }
        let zones = liftZones(graph)
        let bestWait = abs(best.a.time - best.b.time)
        let bestTogether = max(best.a.time, best.b.time)
        let bestScore = best.rank.reliabilityScoreS
        let elsewhereLimitS = bestScore + max(
            Scoring.alternateElsewhereMaximumExtraS,
            abs(bestScore) * Scoring.alternateElsewhereMaximumExtraFraction
        )
        // Somewhere else is a real choice when it is not plainly worse: about
        // as even as the pick, or together sooner. One plainly uneven stop
        // (where the friend already stands, say) may still be shown; a row of
        // them is one choice repeated.
        func isWorthShowing(_ item: Candidate) -> Bool {
            abs(item.a.time - item.b.time) <= bestWait + Scoring.alternateExtraWaitS
                || max(item.a.time, item.b.time) <= bestTogether - Scoring.alternateSoonerS
        }

        func pick(minimumDistanceM: Double) -> [Candidate] {
            var seen: Set<String> = [clusterKey(
                bestNode, zones: zones, lastLift: lastLift(to: best.a, in: searchA, graph: graph)
            )]
            var picked = [bestNode.coordinate]
            var shownAreas: Set<NodeID> = [areas[bestNode.id] ?? bestNode.id]
            var result: [Candidate] = []
            var hasUneven = false
            func take(_ item: Candidate, newAreaOnly: Bool, evenOnly: Bool) {
                guard let node = graph.nodes[item.point.nodeID], node.id != bestNode.id,
                      !result.contains(where: { $0.point.id == item.point.id }) else { return }
                let area = areas[node.id] ?? node.id
                if newAreaOnly, shownAreas.contains(area) { return }
                let uneven = !isWorthShowing(item)
                if uneven, hasUneven || evenOnly { return }
                let key = clusterKey(
                    node, zones: zones, lastLift: lastLift(to: item.a, in: searchA, graph: graph)
                )
                if seen.contains(key) { return }
                if minimumDistanceM > 0, picked.contains(where: {
                    Geo.haversineM($0, node.coordinate) < minimumDistanceM
                }) { return }
                seen.insert(key)
                picked.append(node.coordinate)
                shownAreas.insert(area)
                result.append(item)
                hasUneven = hasUneven || uneven
            }
            // Candidates come in score order, so the first one past the limit
            // ends the search for other areas. The one plainly uneven place is
            // left to the rank-order pass, so it goes to the best-ranked such.
            var index = 1
            while result.count < count, let item = candidate(index),
                  item.rank.reliabilityScoreS <= elsewhereLimitS {
                index += 1
                take(item, newAreaOnly: true, evenOnly: true)
            }
            // Only the strict step may show a second stop in an area: the looser
            // steps exist to find other places, and loosening is exactly what
            // lets a village's lifts, a hundred metres apart, fill the list.
            let reopenAreas = minimumDistanceM >= (Scoring.pairwiseDistanceLadderM.first ?? 0)
            index = 1
            while result.count < count, let item = candidate(index) {
                index += 1
                take(item, newAreaOnly: !reopenAreas, evenOnly: false)
            }
            return result.sorted { $0.rank < $1.rank }
        }

        var bestAttempt: [Candidate] = []
        for distance in Scoring.pairwiseDistanceLadderM {
            let attempt = pick(minimumDistanceM: distance)
            if attempt.count > bestAttempt.count { bestAttempt = attempt }
            if attempt.count >= min(2, count) { return attempt }
        }
        if !bestAttempt.isEmpty { return bestAttempt }
        // Everything shares the primary's cluster: one honest nearby fallback is
        // useful, a row of near-identical pins is not.
        var index = 1
        while let item = candidate(index) {
            if item.point.nodeID != bestNode.id { return [item] }
            index += 1
        }
        return []
    }
}
