//
//  RouteInstructions.swift
//  PowderMeet
//
//  Converts a solver path ([GraphEdge]) into human-readable
//  turn-by-turn instructions for the route overlay and cards.
//

import Foundation

struct RouteInstruction: Identifiable {
    /// Stable identity: `edgeName|action|index`. Using `UUID()` would regenerate
    /// each time the instructions are rebuilt, which makes `ForEach` tear down
    /// and re-create rows on every refresh (animation jitter, lost focus,
    /// unnecessary work). Index keeps duplicates distinct (e.g. two "Green
    /// Valley" ski instructions split by a lift).
    let id: String
    let action: Action
    let edgeName: String
    let difficulty: RunDifficulty?
    let estimatedSeconds: Double
    let lengthMeters: Double

    enum Action: String {
        case ski       // downhill run
        case ride      // lift ride
        case traverse  // ski/skate across a connector
    }

    var displayText: String {
        let time = UnitFormatter.formatTime(estimatedSeconds)
        switch action {
        case .ski:
            let diffLabel = difficulty.map { " (\($0.displayName))" } ?? ""
            return "Ski \(edgeName)\(diffLabel) — \(time)"
        case .ride:
            return "Ride \(edgeName) lift — \(time)"
        case .traverse:
            return "Traverse \(edgeName) — \(time)"
        }
    }
}

/// One presentation boundary for written directions, route cards, and live
/// maneuvers. Equal labels alone cannot prove equal trails or safe difficulty.
nonisolated enum RouteInstructionGrouping {
    static func label(for edge: GraphEdge, naming: MountainNaming?) -> String {
        if let naming { return naming.edgeLabel(edge, style: .bareName) }
        if let name = nonempty(edge.attributes.trailName) { return name }
        switch edge.kind {
        case .run: return "Trail"
        case .lift: return "Lift"
        case .traverse: return "Connector"
        }
    }

    static func canMerge(
        _ previous: GraphEdge,
        _ next: GraphEdge,
        previousLabel: String,
        nextLabel: String
    ) -> Bool {
        guard previous.targetID == next.sourceID,
              previous.kind == next.kind,
              previousLabel == nextLabel else { return false }
        if previous.kind == .run,
           previous.attributes.difficulty != next.attributes.difficulty { return false }
        switch (nonempty(previous.attributes.trailGroupId), nonempty(next.attributes.trailGroupId)) {
        case let (.some(a), .some(b)): return a == b
        case (.none, .none):
            // Legacy named fragments may merge; generic labels such as Trail
            // or Lift are not identities and must never hide a transition.
            guard let name = nonempty(previous.attributes.trailName) else { return false }
            return name == nonempty(next.attributes.trailName)
        default: return false
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

struct RouteInstructionBuilder {

    /// Generates turn-by-turn instructions from a solver path.
    /// Consolidates contiguous same-identity fragments, while preserving
    /// changes in displayed name, difficulty, or physical action.
    static func build(
        from path: [GraphEdge],
        profile: UserProfile,
        context: TraversalContext,
        naming: MountainNaming
    ) -> [RouteInstruction] {
        guard !path.isEmpty else { return [] }

        var instructions: [RouteInstruction] = []
        var i = 0
        var cumulativeTime: Double = 0

        while i < path.count {
            let edge = path[i]
            let name = RouteInstructionGrouping.label(for: edge, naming: naming)

            // Merge consecutive edges in the same trail group + kind.
            var mergedLength = edge.attributes.lengthMeters
            var mergedTime = profile.traverseTime(
                for: edge,
                context: context,
                arrivalTimeOffsetSeconds: cumulativeTime,
                previousEdge: i > 0 ? path[i - 1] : nil
            ) ?? estimateFallback(edge)
            cumulativeTime += mergedTime
            var j = i + 1

            while j < path.count {
                let next = path[j]
                let nextName = RouteInstructionGrouping.label(for: next, naming: naming)
                guard RouteInstructionGrouping.canMerge(
                    path[j - 1], next,
                    previousLabel: name, nextLabel: nextName
                ) else { break }

                mergedLength += next.attributes.lengthMeters
                let nextTime = profile.traverseTime(
                    for: next,
                    context: context,
                    arrivalTimeOffsetSeconds: cumulativeTime,
                    previousEdge: path[j - 1]
                ) ?? estimateFallback(next)
                mergedTime += nextTime
                cumulativeTime += nextTime
                j += 1
            }

            let action: RouteInstruction.Action
            switch edge.kind {
            case .run: action = .ski
            case .lift: action = .ride
            case .traverse: action = .traverse
            }

            instructions.append(RouteInstruction(
                id: "\(instructions.count)|\(action.rawValue)|\(name)",
                action: action,
                edgeName: name,
                difficulty: edge.kind == .run ? edge.attributes.difficulty : nil,
                estimatedSeconds: mergedTime,
                lengthMeters: mergedLength
            ))

            i = j
        }

        return instructions
    }

    private static func estimateFallback(_ edge: GraphEdge) -> Double {
        switch edge.kind {
        case .run: return edge.attributes.lengthMeters / 5.0
        case .lift: return (edge.attributes.rideTimeSeconds ?? 360) + 90
        case .traverse: return edge.attributes.lengthMeters / 1.5
        }
    }

    /// Returns a one-sentence "why this route" for a skier — surfaces in the
    /// route card so the user can see the solver's reasoning in plain English.
    /// Favours the most distinctive positive or negative match for the profile.
    static func reason(
        for path: [GraphEdge],
        profile: UserProfile,
        context: TraversalContext? = nil
    ) -> String {
        let longestLiveLiftWait = path
            .filter { $0.kind == .lift && $0.attributes.chargesLiftWait != false }
            .compactMap(\.attributes.waitTimeMinutes)
            .filter { $0 >= 0 && $0 <= 60 }
            .max()
        guard !path.isEmpty else { return "No travel is needed along this route." }
        let runs = path.filter { $0.kind == .run }

        let anyGroomed = runs.contains { $0.attributes.isGroomed == true }
        let allGroomed = runs.allSatisfy { $0.attributes.isGroomed == true }
        let anyMoguls = runs.contains { $0.attributes.hasMoguls }
        let anyGladed = runs.contains { $0.attributes.isGladed }
        let anyUngroomed = runs.contains { $0.attributes.isGroomed == false }
        let includesLift = path.contains { $0.kind == .lift }
        let maxObstacleDensity = runs.compactMap(\.attributes.obstacleDensity).max() ?? 0
        // Terrain park is a parallel category, not a difficulty above double
        // black. Keep conventional maximum grade and park disclosure separate.
        let runDifficulties = runs.compactMap { $0.attributes.difficulty }
        let includesTerrainPark = runDifficulties.contains(.terrainPark)
        let maxDiff = runDifficulties
            .filter { $0 != .terrainPark }
            .max(by: { $0.sortOrder < $1.sortOrder })
        let steepest = runs.map { $0.attributes.maxGradient }.max() ?? 0
        let comfortCap = profile.maxComfortableGradientDegrees ?? profile.maxGradientForLevel
        let exposureComfort = profile.exposureTolerance
            ?? (profile.conditionUngroomed + profile.conditionGladed) / 2
        let technicalComfort = 0.45 * profile.conditionUngroomed
            + 0.35 * profile.conditionGladed
            + 0.20 * exposureComfort
        let routeWeather: (
            maximumLiftWind: Double,
            lowVisibilityOnSteepRun: Bool,
            maximumUngroomedFreshSnow: Double
        )? = {
            guard let context else { return nil }
            var cumulativeTime: Double = 0
            var maximumLiftWind = 0.0
            var lowVisibilityOnSteepRun = false
            var maximumUngroomedFreshSnow = 0.0
            for (index, edge) in path.enumerated() {
                let arrival = context.solveTime?.addingTimeInterval(cumulativeTime)
                let weather = context.weather(at: arrival)
                // Describe the weather at the relevant edge's arrival, not
                // unrelated extremes elsewhere in the itinerary.
                if edge.kind == .lift {
                    maximumLiftWind = max(maximumLiftWind, weather.windSpeedKmh)
                }
                if edge.kind == .run, edge.attributes.maxGradient >= 20,
                   weather.visibilityKm < 2 {
                    lowVisibilityOnSteepRun = true
                }
                if edge.kind == .run, edge.attributes.isGroomed == false {
                    maximumUngroomedFreshSnow = max(
                        maximumUngroomedFreshSnow,
                        context.effectiveFreshSnowCm(at: arrival)
                    )
                }
                cumulativeTime += profile.traverseTime(
                    for: edge,
                    context: context,
                    arrivalTimeOffsetSeconds: cumulativeTime,
                    previousEdge: index > 0 ? path[index - 1] : nil
                ) ?? estimateFallback(edge)
            }
            return (maximumLiftWind, lowVisibilityOnSteepRun, maximumUngroomedFreshSnow)
        }()

        // Prefer the most informative framing for this skier.
        // Current safety-relevant conditions come first because they can
        // change between visits even when the physical route is identical.
        if let routeWeather,
           routeWeather.lowVisibilityOnSteepRun {
            return "Low visibility is expected on a steep section — the ETA includes a cautious whiteout pace."
        }
        if let routeWeather,
           routeWeather.maximumLiftWind >= TraversalConstants.Lift.windReducedSpeedKph,
           includesLift {
            return "High wind is expected by the lift — extra ride time is included in this ETA."
        }
        if let routeWeather,
           routeWeather.maximumUngroomedFreshSnow >= 8,
           anyUngroomed {
            if let width = context?.equipment?.waistWidthMm, width >= 100 {
                return "Fresh ungroomed snow — your wider skis reduce the powder slowdown in this ETA."
            }
            return "Fresh ungroomed snow — the ETA includes your powder pace and selected skis."
        }
        if let liveWait = longestLiveLiftWait, liveWait >= 5 {
            return "Live lift data includes about \(Int(liveWait.rounded())) minutes in line on this route."
        }
        guard !runs.isEmpty else {
            let includesConnector = path.contains { $0.kind == .traverse }
            if includesLift && includesConnector {
                return "Lift and connector sections — allow for skating or walking between lifts."
            }
            if includesLift { return "Lift connection — no downhill run sections." }
            return "Connector route — allow for skating or walking."
        }
        // Dense technical features outrank the broad groomed/gladed labels:
        // this is the less obvious signal and the one the personalized cost
        // model now specifically accounts for.
        if maxObstacleDensity >= 0.65, technicalComfort < 0.55 {
            return "One technical section has dense obstacles — the ETA includes your cautious-terrain pace."
        }
        if maxObstacleDensity >= 0.65, technicalComfort >= 0.8 {
            return "Technical terrain is in the mix — matched to your obstacle and ungroomed comfort."
        }
        // Marked expert terrain outranks reassuring surface copy. A smooth,
        // freshly groomed double-black is still a double-black.
        if let diff = maxDiff, diff == .doubleBlack {
            return "Includes a double-black — this route crosses marked expert terrain."
        }
        if includesTerrainPark {
            if context?.equipment?.category?.contains("park") == true {
                return "Includes terrain-park features — your selected park skis are included in the ETA."
            }
            return "Includes terrain-park features — your marked-terrain ability and pace are included."
        }
        if allGroomed,
           context?.equipment?.category?.contains("race") == true,
           context.map({ $0.effectiveFreshSnowCm(at: $0.solveTime) < 3 }) == true {
            return "Firm groomers — your selected race skis add a small edge-to-edge pace advantage."
        }
        if allGroomed, profile.conditionUngroomed < 0.5 {
            return "All groomed — matched your preference for smooth terrain."
        }
        if anyGladed, profile.conditionGladed > 0.7 {
            return "Tree runs in the mix — you've rated glades highly."
        }
        if anyMoguls, profile.conditionMoguls < 0.4 {
            return "Includes moguls — the ETA accounts for your mogul pace."
        }
        if steepest > comfortCap * 0.9 {
            let pct = Int((steepest / comfortCap) * 100)
            return "Peak pitch ~\(Int(steepest))° (\(pct)% of your comfort cap) — watch for the steep section."
        }
        if anyGroomed, !anyMoguls {
            return "Includes groomed terrain; no moguls are marked in the route data."
        }
        return "Balanced run mix matching your skill profile."
    }
}

// RunDifficulty.displayName is defined in MountainGraph.swift
