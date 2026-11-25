import Foundation
import MountainCore

/// Finds where two skiers should meet and how each gets there. Pure functions of
/// their input: no mutable solver, no static cache, no clock, no network.
/// Routing may pass through any node, but a meet ends only at a rendezvous in the
/// bundle's catalog (invariant I-01).
public enum MeetSolver {
    public static func solve(_ input: SolveInput) -> Result<MeetOptions, SolveFailure> {
        let bundle = input.bundle
        let graph = bundle.graph
        let skiers = [input.skiers.0, input.skiers.1]
        let models = skiers.map { CostModel(input: input, skier: $0) }
        let status = models[0].status
        if input.options.statusPolicy == .strict, status.freshness != .fresh {
            return .failure(.statusExpired)
        }

        // Exact origins or an honest failure: a skier is never moved to a nearby
        // node that happens to route (I-07).
        // A start blocked only by the skier's level is held back: the easiest
        // way down below may still route them.
        var origins: [ResolvedOrigin] = []
        var heldFailure: SolveFailure?
        for (skier, model) in zip(skiers, models) {
            guard let origin = ResolvedOrigin(skier.origin, graph: graph) else {
                return .failure(heldFailure ?? .originNotOnGraph(skier.id))
            }
            if let failure = originFailure(origin, skier: skier, model: model, bundle: bundle) {
                guard case .abilityBlocksAll = failure,
                      originFailure(
                          origin, skier: skier, model: model.relaxed(toRank: Self.topRank),
                          bundle: bundle
                      ) == nil
                else { return .failure(heldFailure ?? failure) }
                heldFailure = heldFailure ?? failure
            }
            origins.append(origin)
        }

        let maxLabels = input.options.maxLabelsPerNode
        func search(
            _ i: Int, ignoreAbility: Bool = false, ignoreDeadline: Bool = false,
            model: CostModel? = nil
        ) -> SearchResult {
            Search.run(
                from: origins[i], model: model ?? models[i], maxLabels: maxLabels,
                ignoreAbility: ignoreAbility, ignoreLiftDeadlineRisk: ignoreDeadline
            )
        }
        var searchA = search(0)
        var searchB = search(1)
        var routeModels = models
        var eligible = bundle.rendezvous.filter {
            searchA.reaches($0.nodeID) && searchB.reaches($0.nodeID)
        }

        if eligible.isEmpty {
            guard !bundle.rendezvous.isEmpty else {
                return .failure(.bundleUnusable("the bundle has no rendezvous catalog"))
            }
            // Diagnose only: neither probe ever returns a route.
            let riskA = search(0, ignoreDeadline: true), riskB = search(1, ignoreDeadline: true)
            if bundle.rendezvous.contains(where: {
                riskA.reaches($0.nodeID) && riskB.reaches($0.nodeID)
            }) {
                return .failure(.liftDeadlineRisk)
            }
            if let easiest = easiestWayDown(
                skiers: skiers, models: models, normal: [searchA, searchB], bundle: bundle,
                search: { search($0, model: $1) }
            ) {
                searchA = easiest.searches[0]
                searchB = easiest.searches[1]
                routeModels = easiest.models
                eligible = easiest.eligible
            }
        }

        guard !eligible.isEmpty else {
            if let heldFailure { return .failure(heldFailure) }
            let relaxedA = search(0, ignoreAbility: true), relaxedB = search(1, ignoreAbility: true)
            let relaxed = bundle.rendezvous.compactMap { point -> (Rendezvous, Label, Label)? in
                guard let a = relaxedA.best(at: point.nodeID),
                      let b = relaxedB.best(at: point.nodeID) else { return nil }
                return (point, a, b)
            }.min {
                let l = max($0.1.time, $0.2.time), r = max($1.1.time, $1.2.time)
                return l != r ? l < r : $0.0.id < $1.0.id
            }
            if let relaxed {
                let pathA = relaxedA.path(to: relaxed.1, graph: graph)
                let blockedA = pathA.contains { !models[0].isWithinAbility($0) }
                return .failure(.abilityBlocksAll(blockedA ? skiers[0].id : skiers[1].id))
            }
            let reachesAny = { (result: SearchResult) in
                bundle.rendezvous.contains { result.reaches($0.nodeID) }
            }
            return .failure(.noRendezvousReachable(
                !reachesAny(searchA) || reachesAny(searchB) ? skiers[0].id : skiers[1].id
            ))
        }

        let pairs = eligible.compactMap { point in
            Ranking.bestApproachPair(at: point.nodeID, searchA, searchB).map { (point, $0) }
        }
        // One number per solve: how much lift day is left once the pair could
        // first be together. It only ever moves lodges.
        let earliestTogether = pairs.map { $0.1.latestArrival }.min() ?? 0
        let lateDay = Ranking.liftTimeLeftS(
            afterOffsetS: earliestTogether + Scoring.sharedMeetupHandoffS, model: models[0],
            searchA, searchB
        ).map(Scoring.lateDayFactor) ?? 0

        var pending: [Ranking.Candidate] = []
        pending.reserveCapacity(pairs.count)
        for (point, pair) in pairs {
            let latest = pair.latestArrival
            let variance = pair.a.variance + pair.b.variance
            // When stopping is the point, a lodge is not charged for leading
            // nowhere and is credited for being a lodge.
            let stopping = point.kind == .lodge
                ? max(lateDay, models[0].weatherHazard(at: point, arrivalOffsetS: latest)) : 0
            let leaveAt = latest + Scoring.sharedMeetupHandoffS
            let wait = abs(pair.a.time - pair.b.time)
            let possibleLap = RendezvousRank.longestPossibleLapS(waitSpreadS: wait)
            pending.append(Ranking.Candidate(
                point: point,
                rank: RendezvousRank(
                    latestArrivalS: latest,
                    waitSpreadS: wait,
                    lapS: possibleLap,
                    uncertaintyS: variance > 0 ? variance.squareRoot() : 0,
                    waitPenaltyAlpha: input.options.fairnessAlpha
                        ?? models[0].waitPenaltyAlpha(for: point, arrivalOffsetS: latest),
                    approachSimplicityPenaltyS: pair.simplicityPenaltyS,
                    stopCreditS: Scoring.lodgeShelterCreditS * stopping,
                    confidencePenalty: 1 - point.confidence,
                    qualityPenalty: 1 - point.quality,
                    stableID: point.id
                ),
                a: pair.a, b: pair.b, onwardShare: 1 - stopping, lapKnown: possibleLap == 0,
                stuck: zip(skiers, models).compactMap { skier, model in
                    Ranking.canLeave(point, model: model, offsetS: leaveAt) ? nil : skier.id
                }
            ))
        }

        // Hard rule: everyone can leave. If no stop passes, the full list is used
        // and every option says who is stuck, rather than failing the solve.
        let open = pending.filter(\.stuck.isEmpty)

        // The shared run from a stop and the lap the earlier skier can fit into
        // their wait are both part of the score, and finding either is a search
        // of its own. Candidates start out ranked as if the run cost nothing and
        // the wait held the longest possible lap, which can only flatter them,
        // and are taken best first: one still holding a guess gets the real
        // value and goes back in the queue, so the order that comes out is
        // exactly the order of the real scores, without those searches for
        // stops too far down the list to be shown. Stops on one node share both.
        let pool = open.isEmpty ? pending : open
        var queue = BinaryHeap<Ranking.Candidate> { $0.rank < $1.rank }
        for candidate in pool { queue.insert(candidate) }
        var continuations: [NodeID: SharedContinuation?] = [:]
        var laps: [NodeID: Route?] = [:]
        func withContinuation(_ candidate: Ranking.Candidate) -> Ranking.Candidate {
            var next = candidate
            let continuation: SharedContinuation?
            if let known = continuations[next.point.nodeID] {
                continuation = known
            } else {
                continuation = Ranking.sharedContinuation(
                    at: next.point, models: models, bundle: bundle,
                    departureOffsetS: next.rank.latestArrivalS
                )
                continuations[next.point.nodeID] = .some(continuation)
            }
            next.continuation = continuation
            next.continuationKnown = true
            next.rank = next.rank.with(
                onwardCostS: Ranking.onwardCostS(continuation: continuation) * next.onwardShare
            )
            return next
        }
        func withLap(_ candidate: Ranking.Candidate) -> Ranking.Candidate {
            var next = candidate
            let times = [next.a.time, next.b.time]
            let waiter = times[0] <= times[1] ? 0 : 1
            let lap: Route?
            if let known = laps[next.point.nodeID] {
                lap = known
            } else {
                lap = lapWhileWaiting(
                    at: next.point, skier: skiers[waiter], model: models[waiter],
                    arrivalS: times[waiter], partnerArrivalS: times[1 - waiter]
                )
                laps[next.point.nodeID] = .some(lap)
            }
            next.lap = lap
            next.lapKnown = true
            next.rank = next.rank.with(lapS: lap.map { $0.eta.meanS - times[waiter] } ?? 0)
            return next
        }
        func resolved(_ candidate: Ranking.Candidate) -> Ranking.Candidate {
            let next = candidate.continuationKnown ? candidate : withContinuation(candidate)
            return next.lapKnown ? next : withLap(next)
        }
        var ordered: [Ranking.Candidate] = []
        func candidate(at index: Int) -> Ranking.Candidate? {
            while ordered.count <= index {
                guard let next = queue.extractMin() else { return nil }
                if !next.continuationKnown {
                    queue.insert(withContinuation(next))
                } else if !next.lapKnown {
                    queue.insert(withLap(next))
                } else {
                    ordered.append(next)
                }
            }
            return ordered[index]
        }

        guard let best = candidate(at: 0) else {
            return .failure(.noRendezvousReachable(skiers[0].id))
        }
        let maxOptions = input.options.maxOptions
        let areas = Ranking.stopAreas(bundle.rendezvous, graph: graph)
        func area(_ candidate: Ranking.Candidate) -> NodeID {
            areas[candidate.point.nodeID] ?? candidate.point.nodeID
        }
        var alternates = Ranking.diverseAlternates(
            after: best, searchA: searchA, graph: graph, areas: areas,
            count: max(0, maxOptions - 1),
            candidate: candidate(at:)
        )
        // A lodge stays on the list even when it is not the pick: stopping for a
        // break is always a fair answer. It takes the last place if the list is
        // full. It must be somewhere else: a lodge in an area already listed (one
        // on the pick's own node, say) is the same place again, so then none is
        // added. Only lodges are scored here, so the queue is not drained to find one.
        if maxOptions > 1, best.point.kind != .lodge,
           !alternates.contains(where: { $0.point.kind == .lodge }) {
            let listed = Set(([best] + alternates).map(area))
            let lodge = pool
                .filter { $0.point.kind == .lodge && !listed.contains(area($0)) }
                .map(resolved)
                .min { $0.rank < $1.rank }
            if let lodge {
                if alternates.count >= maxOptions - 1 { alternates.removeLast() }
                alternates.append(lodge)
                alternates.sort { $0.rank < $1.rank }
            }
        }
        var chosen = [best] + alternates
        // The place asked for by name joins the list last, however it ranks:
        // the skier wants its routes and its wait, not the solver's opinion.
        var requestedIndex: Int?
        if let wanted = input.options.requested, !chosen.contains(where: { $0.point.id == wanted }) {
            // Held back by the everyone-can-leave rule: still shown, and its
            // reasons say who is stuck. Its lap is never searched.
            let found = pool.first { $0.point.id == wanted }.map(resolved)
                ?? pending.first { $0.point.id == wanted }.map(withContinuation)
            if let found {
                requestedIndex = chosen.count
                chosen.append(found)
            }
        }
        let lodgeAlternative = best.point.kind == .lodge
            ? nil : alternates.first { $0.point.kind == .lodge }?.point.id

        func option(_ candidate: Ranking.Candidate) -> MeetOption {
            MeetOption(
                rendezvous: candidate.point.id,
                routes: (
                    makeRoute(
                        skiers[0], origins[0], candidate.a, searchA, routeModels[0], level: models[0]
                    ),
                    makeRoute(
                        skiers[1], origins[1], candidate.b, searchB, routeModels[1], level: models[1]
                    )
                ),
                score: candidate.rank.reliabilityScoreS,
                expectedWaitS: candidate.rank.waitSpreadS,
                reasons: [],
                sharedContinuation: candidate.continuation,
                lapWhileWaiting: candidate.lap
            )
        }
        var options = chosen.map(option)
        var ownRoutes = options.map(\.routes.0), partnerRoutes = options.map(\.routes.1)
        WeatherFavours.annotate(&ownRoutes, origin: origins[0], model: routeModels[0])
        WeatherFavours.annotate(&partnerRoutes, origin: origins[1], model: routeModels[1])
        for index in options.indices { options[index].routes = (ownRoutes[index], partnerRoutes[index]) }
        // The resort has lifts, and neither skier can board one from anywhere
        // they can get to.
        let noLifts = graph.edges.contains { $0.kind == .lift } && ![searchA, searchB].contains { search in
            search.labels.contains { $0.via.flatMap { graph.edge($0) }?.kind == .lift }
        }
        let top = options[0]
        for index in options.indices {
            options[index].reasons = reasons(
                for: options[index], candidate: chosen[index], top: index == 0 ? nil : top,
                isOnlyOption: options.count == 1,
                isLodgeAlternative: chosen[index].point.id == lodgeAlternative,
                noLiftsRunning: noLifts, models: models
            )
        }
        Tradeoffs.assign(&options, graph: graph)
        if let requestedIndex { options[requestedIndex].tradeoff = .yourPick }
        return .success(MeetOptions(
            options: options, statusFreshness: status.freshness, degraded: status.degraded
        ))
    }

    /// One skier's most dependable route to an agreed rendezvous.
    public static func route(
        for skier: SkierInput, to rendezvous: RendezvousID, in input: SolveInput
    ) -> Result<Route, SolveFailure> {
        let graph = input.bundle.graph
        guard let point = input.bundle.rendezvous(rendezvous) else {
            return .failure(.bundleUnusable("rendezvous \(rendezvous) is not in this bundle"))
        }
        let model = CostModel(input: input, skier: skier)
        if input.options.statusPolicy == .strict, model.status.freshness != .fresh {
            return .failure(.statusExpired)
        }
        guard let origin = ResolvedOrigin(skier.origin, graph: graph) else {
            return .failure(.originNotOnGraph(skier.id))
        }
        func search(ignoreAbility: Bool = false, ignoreDeadline: Bool = false) -> SearchResult {
            Search.run(
                from: origin, model: model, maxLabels: input.options.maxLabelsPerNode,
                earlyExitTarget: point.nodeID, ignoreAbility: ignoreAbility,
                ignoreLiftDeadlineRisk: ignoreDeadline
            )
        }
        let result = search()
        guard let label = result.best(at: point.nodeID) else {
            if search(ignoreDeadline: true).reaches(point.nodeID) {
                return .failure(.liftDeadlineRisk)
            }
            // No way there within their level: the easiest way there is, the
            // least hard run first (06-SOLVER section 1).
            for ceiling in Self.ceilings(above: model) {
                let relaxed = model.relaxed(toRank: ceiling)
                let result = Search.run(
                    from: origin, model: relaxed, maxLabels: input.options.maxLabelsPerNode,
                    earlyExitTarget: point.nodeID
                )
                if let label = result.best(at: point.nodeID) {
                    return .success(makeRoute(skier, origin, label, result, relaxed, level: model))
                }
            }
            if search(ignoreAbility: true).reaches(point.nodeID) {
                return .failure(.abilityBlocksAll(skier.id))
            }
            return .failure(.noRendezvousReachable(skier.id))
        }
        var routes = [makeRoute(skier, origin, label, result, model)]
        WeatherFavours.annotate(&routes, origin: origin, model: model)
        return .success(routes[0])
    }

    /// Re-prices the exact remaining legs from `progress` at `at`. Returns nil if
    /// any remaining leg can no longer be taken (I-09): the caller reroutes rather
    /// than showing an ETA that skips the closed part. Variance is recomputed for
    /// the remainder, never dropped (I-10).
    public static func recost(
        _ route: Route, from progress: Progress, at: Date, in input: SolveInput
    ) -> ETA? {
        guard let skier = [input.skiers.0, input.skiers.1].first(where: { $0.id == route.skierID })
        else { return nil }
        guard progress.legIndex < route.legs.count, progress.state != .arrived else {
            return ETA(meanS: 0, sdS: 0)
        }
        let graph = input.bundle.graph
        var model = CostModel(input: input, skier: skier, at: at)
        // An easiest-way-down route may keep the runs above the level it was
        // given, and no harder; closures still end it.
        if let easiest = route.easiestWayDown, let rank = CostModel.hardnessRank(easiest.hardest) {
            model = model.relaxed(toRank: rank)
        }
        var elapsed = 0.0
        var uncertainty = RouteTimeUncertainty()
        var previous: Edge? = progress.legIndex > 0
            ? graph.edge(route.legs[progress.legIndex - 1].edgeID) : nil
        for index in progress.legIndex..<route.legs.count {
            guard let edge = graph.edge(route.legs[index].edgeID) else { return nil }
            let remaining = index == progress.legIndex
                ? 1 - max(0, min(1, progress.fractionAlongLeg)) : 1
            guard let cost = model.evaluate(
                edge, elapsedS: elapsed, approachVariance: uncertainty.varianceTime,
                remainingFraction: remaining, previous: previous
            ) else { return nil }
            elapsed += cost.seconds
            uncertainty.append(edge: edge, variance: cost.variance)
            previous = edge
        }
        return ETA(meanS: elapsed, sdS: uncertainty.varianceTime.squareRoot())
    }

    public static func maneuvers(for route: Route, in bundle: ResortBundle) -> [Maneuver] {
        Maneuvers.build(for: route, in: bundle)
    }

    // MARK: Internals

    /// Why a solve cannot start from this origin, or nil when it can.
    private static func originFailure(
        _ origin: ResolvedOrigin, skier: SkierInput, model: CostModel, bundle: ResortBundle
    ) -> SolveFailure? {
        let graph = bundle.graph
        let edges: [Edge]
        if let approach = origin.approachEdge {
            if model.traverseTime(approach, remainingFraction: origin.remainingFraction) != nil {
                return nil
            }
            edges = [approach]
        } else {
            // Someone already standing at a stopping point can simply wait there,
            // even when nothing leads onward.
            if bundle.rendezvous.contains(where: { $0.nodeID == origin.startNode }) { return nil }
            edges = graph.outgoing(from: origin.startNode)
            if edges.contains(where: { model.traverseTime($0) != nil }) { return nil }
        }
        // Tell terrain the skier's limits exclude apart from a closed or
        // disconnected start. The relaxation only explains; it never routes.
        let blockedByAbility = edges.contains {
            !model.isWithinAbility($0) && model.traverseTime(
                $0, remainingFraction: origin.remainingFraction, ignoreAbility: true
            ) != nil
        }
        return blockedByAbility ? .abilityBlocksAll(skier.id) : .originNotOnGraph(skier.id)
    }

    /// Hardest ladder rank (double black).
    static let topRank = Difficulty.doubleBlack.ladderRank ?? 3

    /// The difficulty caps an easiest-way-down search tries, least hard first:
    /// every rank above the skier's own limit.
    static func ceilings(above model: CostModel) -> [Int] {
        let limit = model.profile.maxDifficulty.ladderRank ?? Difficulty.blue.ladderRank ?? 1
        return limit < topRank ? Array((limit + 1)...topRank) : []
    }

    struct EasiestWayDownSearch {
        var searches: [SearchResult]
        var models: [CostModel]
        var eligible: [Rendezvous]
    }

    /// When the two share no stop within their levels: the least hard way for
    /// one or both to reach one. Caps rise one difficulty at a time and the
    /// first that works wins; within it, relaxing one skier beats relaxing two,
    /// then fewer metres above the level, then the skier ids. Only the stops
    /// with the fewest metres above stay eligible; the usual ranking orders them.
    /// The order of the two skiers never changes the answer.
    private static func easiestWayDown(
        skiers: [SkierInput], models: [CostModel], normal: [SearchResult], bundle: ResortBundle,
        search: (Int, CostModel) -> SearchResult
    ) -> EasiestWayDownSearch? {
        let caps = models.map { Set(ceilings(above: $0)) }
        let sets: [[Bool]] = [[true, false], [false, true], [true, true]]
        var relaxedSearches: [Int: [Int: SearchResult]] = [:]
        func relaxed(_ i: Int, _ ceiling: Int) -> SearchResult {
            if let known = relaxedSearches[i]?[ceiling] { return known }
            let result = search(i, models[i].relaxed(toRank: ceiling))
            relaxedSearches[i, default: [:]][ceiling] = result
            return result
        }
        for ceiling in 0...topRank {
            var best: (key: (Int, Double, String), found: EasiestWayDownSearch)?
            for set in sets where (0..<2).allSatisfy({ !set[$0] || caps[$0].contains(ceiling) }) {
                let searches = (0..<2).map { set[$0] ? relaxed($0, ceiling) : normal[$0] }
                var least = Double.infinity
                var eligible: [Rendezvous] = []
                for point in bundle.rendezvous {
                    guard let a = searches[0].best(at: point.nodeID),
                          let b = searches[1].best(at: point.nodeID) else { continue }
                    let metres = a.aboveLimitM + b.aboveLimitM
                    if metres < least {
                        least = metres
                        eligible = [point]
                    } else if metres == least {
                        eligible.append(point)
                    }
                }
                guard !eligible.isEmpty else { continue }
                let who = (0..<2).filter { set[$0] }.map { skiers[$0].id.uuidString }
                    .sorted().joined(separator: ",")
                let key = (set.filter { $0 }.count, least, who)
                if let current = best, !(key < current.key) { continue }
                best = (key, EasiestWayDownSearch(
                    searches: searches,
                    models: (0..<2).map { set[$0] ? models[$0].relaxed(toRank: ceiling) : models[$0] },
                    eligible: eligible
                ))
            }
            if let best { return best.found }
        }
        return nil
    }

    /// What an easiest-way-down route has above the skier's level, or nil when
    /// nothing on it is.
    private static func easiestWayDown(
        _ steps: [(edge: Edge, exitS: Double)], firstStartFraction: Double, level: CostModel
    ) -> EasiestWayDown? {
        var runs: [Difficulty: Int] = [:]
        var edgeIDs: [EdgeID] = []
        var metres = 0.0
        var hardest: Difficulty?
        var previousAbove: String?
        for (index, step) in steps.enumerated() {
            let edge = step.edge
            guard edge.kind == .run, !level.isWithinLevel(edge) else {
                previousAbove = nil
                continue
            }
            let difficulty = level.effectiveDifficulty(edge)
            let identity = RouteSimplicity.actionIdentity(for: edge)
            if identity != previousAbove { runs[difficulty, default: 0] += 1 }
            previousAbove = identity
            edgeIDs.append(edge.id)
            metres += edge.lengthM * (1 - (index == 0 ? firstStartFraction : 0))
            if (CostModel.hardnessRank(difficulty) ?? -1)
                > (hardest.flatMap(CostModel.hardnessRank) ?? -1) {
                hardest = difficulty
            }
        }
        guard let hardest else { return nil }
        return EasiestWayDown(
            hardest: hardest, runsAboveLevel: runs, metresAboveLevel: metres.rounded(),
            edgeIDs: edgeIDs
        )
    }

    /// `level` is the skier's unrelaxed model: when `model` is relaxed, the
    /// route says what it has above that level.
    private static func makeRoute(
        _ skier: SkierInput, _ origin: ResolvedOrigin, _ label: Label, _ search: SearchResult,
        _ model: CostModel, level: CostModel? = nil
    ) -> Route {
        var chain: [Label] = []
        var current: Label? = label
        while let entry = current, entry.via != nil {
            chain.append(entry)
            current = entry.previous.map { search.labels[$0] }
        }
        chain.reverse()

        var steps: [(edge: Edge, exitS: Double)] = []
        for entry in chain {
            guard let via = entry.via, let edge = model.graph.edge(via) else { continue }
            steps.append((edge, entry.time))
        }
        let firstStartFraction = origin.startFraction(forFirstEdge: steps.first?.edge.id)
        var route = assembleRoute(
            skier.id, steps: steps, startS: 0,
            firstStartFraction: firstStartFraction,
            eta: ETA(meanS: label.time, sdS: label.variance > 0 ? label.variance.squareRoot() : 0),
            model: model
        )
        if let level, model.difficultyCeilingRank != nil {
            route.easiestWayDown = easiestWayDown(
                steps, firstStartFraction: firstStartFraction, level: level
            )
        }
        return route
    }

    /// Legs and summary figures for edges travelled in order from `startS`.
    private static func assembleRoute(
        _ skierID: UUID, steps: [(edge: Edge, exitS: Double)], startS: Double,
        firstStartFraction: Double, eta: ETA, model: CostModel
    ) -> Route {
        var legs: [RouteLeg] = []
        var hardest: Difficulty?
        var hasPark = false
        var liftCount = 0
        var lengthM = 0.0
        var previous: Edge?
        var enter = startS
        for (index, step) in steps.enumerated() {
            let edge = step.edge
            let startFraction = index == 0 ? firstStartFraction : 0
            legs.append(RouteLeg(
                edgeID: edge.id, enterS: enter, exitS: step.exitS, startFraction: startFraction
            ))
            enter = step.exitS
            lengthM += edge.lengthM * (1 - startFraction)
            switch edge.kind {
            case .run:
                let difficulty = model.effectiveDifficulty(edge)
                if let rank = difficulty.ladderRank {
                    if rank > (hardest?.ladderRank ?? -1) { hardest = difficulty }
                } else {
                    hasPark = true
                }
            case .lift:
                if !LiftRideContinuation.isContinuation(from: previous, to: edge) { liftCount += 1 }
            case .connection:
                break
            }
            previous = edge
        }
        return Route(
            skierID: skierID, legs: legs, eta: eta,
            hardestDifficulty: hardest ?? (hasPark ? .park : .green),
            liftCount: liftCount, lengthM: lengthM
        )
    }

    /// A lap for the skier who would otherwise stand waiting: the loop from the
    /// stop back to the stop, within their own limits, that returns latest while
    /// still being back `waitLapReturnMarginS` before the partner is expected. A
    /// suggestion only: it changes neither the meeting point nor either route.
    private static func lapWhileWaiting(
        at point: Rendezvous, skier: SkierInput, model: CostModel, arrivalS: Double,
        partnerArrivalS: Double
    ) -> Route? {
        let deadline = partnerArrivalS - Scoring.waitLapReturnMarginS
        guard partnerArrivalS - arrivalS >= Scoring.waitLapMinimumWaitS,
              let origin = ResolvedOrigin(.node(point.nodeID), graph: model.graph) else { return nil }
        // One label per node: the loop is closed from the fastest way to each
        // neighbour, and this runs for every stop the ranking looks at.
        let search = Search.run(
            from: origin, model: model, maxLabels: 1, startTimeS: arrivalS, deadlineS: deadline
        )
        // The search never returns to its own start, so the loop is closed here:
        // the best way to each neighbour, then the edge back in.
        var best: (steps: [(edge: Edge, exitS: Double)], sdS: Double)?
        for closing in model.graph.incoming(to: point.nodeID) {
            guard closing.from != point.nodeID, let label = search.best(at: closing.from) else {
                continue
            }
            let previous = label.via.flatMap { model.graph.edge($0) }
            guard let cost = model.evaluate(
                closing, elapsedS: label.time, approachVariance: label.variance, previous: previous
            ) else { continue }
            let returnS = label.time + cost.seconds
            guard returnS <= deadline else { continue }
            var steps: [(edge: Edge, exitS: Double)] = []
            var current: Label? = label
            while let entry = current, let via = entry.via {
                if let edge = model.graph.edge(via) { steps.append((edge, entry.time)) }
                current = entry.previous.map { search.labels[$0] }
            }
            steps.reverse()
            steps.append((closing, returnS))
            // A lap is a lift and a real run: walking to the next building and
            // back, or a carpet and a few metres of snow, is not one.
            let runLengthM = steps.reduce(0) { $0 + ($1.edge.kind == .run ? $1.edge.lengthM : 0) }
            guard steps.contains(where: { $0.edge.kind == .lift }),
                  runLengthM >= Scoring.waitLapMinimumRunLengthM else { continue }
            if let current = best, let last = current.steps.last, last.exitS >= returnS { continue }
            var uncertainty = label.uncertainty
            uncertainty.append(edge: closing, variance: cost.variance)
            best = (steps, uncertainty.varianceTime.squareRoot())
        }
        guard let best, let last = best.steps.last else { return nil }
        return assembleRoute(
            skier.id, steps: best.steps, startS: arrivalS, firstStartFraction: 0,
            eta: ETA(meanS: last.exitS, sdS: best.sdS), model: model
        )
    }

    private static let materialGainS = 60.0

    /// Typed hints for the option card. The first skier in the input is "you".
    private static func reasons(
        for option: MeetOption, candidate: Ranking.Candidate, top: MeetOption?,
        isOnlyOption: Bool, isLodgeAlternative: Bool, noLiftsRunning: Bool, models: [CostModel]
    ) -> [Reason] {
        let point = candidate.point
        let graph = models[0].graph
        var reasons: [Reason] = [option.routes.0, option.routes.1]
            .filter { $0.easiestWayDown != nil }.map { .easiestWayDownFor($0.skierID) }
        reasons += candidate.stuck.map(Reason.noOnwardRouteFor)
        if noLiftsRunning { reasons.append(.noLiftsRunning) }
        // The pick is the best there is; when it is still this uneven, say so.
        if top == nil, option.expectedWaitS >= Scoring.longWaitNoticeS {
            let first = option.routes.0.eta.meanS <= option.routes.1.eta.meanS
                ? option.routes.0 : option.routes.1
            reasons.append(.longWaitUnavoidable(first.skierID))
        }
        for route in [option.routes.0, option.routes.1] where route.legs.isEmpty {
            reasons.append(.alreadyThere(route.skierID))
        }
        if let next = option.sharedContinuation,
           next.downhillAccessS <= Scoring.skiOnTogetherMaximumAccessS,
           next.quality >= Scoring.skiOnTogetherMinimumQuality {
            reasons.append(.skiOnTogether(run: next.firstRunName))
        }
        if isLodgeAlternative { reasons.append(.lodgeAlternative) }
        if let lap = option.lapWhileWaiting { reasons.append(.lapWhileWaitingFor(lap.skierID)) }
        if let top {
            if option.routes.0.eta.meanS <= top.routes.0.eta.meanS - materialGainS {
                reasons.append(.closerForYou)
            }
            func partnerWait(_ o: MeetOption) -> Double {
                max(0, o.routes.0.eta.meanS - o.routes.1.eta.meanS)
            }
            if partnerWait(option) <= partnerWait(top) - materialGainS {
                reasons.append(.lessWaitFor(option.routes.1.skierID))
            }
            let black = Difficulty.black.ladderRank ?? 2
            for (mine, theirs) in [(option.routes.0, top.routes.0), (option.routes.1, top.routes.1)]
            where (theirs.hardestDifficulty.ladderRank ?? -1) >= black
                && (mine.hardestDifficulty.ladderRank ?? black) < black {
                reasons.append(.avoidsBlackFor(mine.skierID))
            }
        }
        for (route, model) in zip([option.routes.0, option.routes.1], models) {
            let held = route.legs.contains { leg in
                leg.startFraction == 0 && graph.edge(leg.edgeID).map {
                    model.windHoldLikelihood($0, atOffset: leg.enterS)
                        >= Traversal.Lift.windHoldNoticeLikelihood
                } == true
            }
            if held { reasons.append(.windHoldLikelyFor(route.skierID)) }
        }
        if point.isIndoor { reasons.append(.indoor) }
        if isOnlyOption, models[0].status.hasClosures { reasons.append(.onlyOptionUnderClosures) }
        // Unknown status is labelled, never silently treated as open (I-07).
        let unknown = models[0].status.degraded
            || (option.routes.0.legs + option.routes.1.legs).contains {
                !models[0].status.isKnown(graph.edge($0.edgeID)?.group)
            }
        if unknown { reasons.append(.statusUnknown) }
        return reasons
    }
}

