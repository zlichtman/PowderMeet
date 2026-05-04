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
        case walk      // traverse / walk
    }

    var displayText: String {
        let time = UnitFormatter.formatTime(estimatedSeconds)
        switch action {
        case .ski:
            let diffLabel = difficulty.map { " (\($0.displayName))" } ?? ""
            return "Ski \(edgeName)\(diffLabel) — \(time)"
        case .ride:
            return "Ride \(edgeName) lift — \(time)"
        case .walk:
            return "Walk to \(edgeName) — \(time)"
        }
    }
}

struct RouteInstructionBuilder {

    /// Generates turn-by-turn instructions from a solver path.
    /// Consecutive edges on the same logical trail (same `trailGroupId`)
    /// are merged into a single instruction so an OSM-fragmented chain
    /// like ["Frontside Run", "Frontside Run", "Frontside Lower"] reads
    /// as one "Ski Frontside Run · Black" line, not three.
    static func build(
        from path: [GraphEdge],
        profile: UserProfile,
        context: TraversalContext,
        naming: MountainNaming
    ) -> [RouteInstruction] {
        guard !path.isEmpty else { return [] }

        var instructions: [RouteInstruction] = []
        var i = 0

        while i < path.count {
            let edge = path[i]
            let name = naming.edgeLabel(edge, style: .bareName).nilIfEmpty
                ?? fallbackName(for: edge)

            // Merge consecutive edges in the same trail group + kind.
            var mergedLength = edge.attributes.lengthMeters
            var mergedTime = profile.traverseTime(for: edge, context: context) ?? estimateFallback(edge)
            var j = i + 1

            while j < path.count {
                let next = path[j]
                let nextName = naming.edgeLabel(next, style: .bareName).nilIfEmpty
                    ?? fallbackName(for: next)
                guard next.kind == edge.kind, nextName == name else { break }

                mergedLength += next.attributes.lengthMeters
                mergedTime += profile.traverseTime(for: next, context: context) ?? estimateFallback(next)
                j += 1
            }

            let action: RouteInstruction.Action
            switch edge.kind {
            case .run: action = .ski
            case .lift: action = .ride
            case .traverse: action = .walk
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

    private static func fallbackName(for edge: GraphEdge) -> String {
        switch edge.kind {
        case .run: return "trail"
        case .lift: return "lift"
        case .traverse: return "connector"
        }
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
        profile: UserProfile
    ) -> String {
        let runs = path.filter { $0.kind == .run }
        guard !runs.isEmpty else {
            return "Lift ride only — fastest connection to the meeting point."
        }

        let anyGroomed = runs.contains { $0.attributes.isGroomed == true }
        let allGroomed = runs.allSatisfy { $0.attributes.isGroomed == true }
        let anyMoguls = runs.contains { $0.attributes.hasMoguls }
        let anyGladed = runs.contains { $0.attributes.isGladed }
        let maxDiff = runs.compactMap { $0.attributes.difficulty }.max(by: { $0.sortOrder < $1.sortOrder })
        let steepest = runs.map { $0.attributes.maxGradient }.max() ?? 0
        let comfortCap = profile.maxComfortableGradientDegrees ?? profile.maxGradientForLevel

        // Prefer the most informative framing for this skier.
        if allGroomed, profile.conditionUngroomed < 0.5 {
            return "All groomed — matched your preference for smooth terrain."
        }
        if anyGladed, profile.conditionGladed > 0.7 {
            return "Tree runs in the mix — you've rated glades highly."
        }
        if anyMoguls, profile.conditionMoguls < 0.4 {
            return "One mogul section — no lower-effort path connected your positions."
        }
        if steepest > comfortCap * 0.9 {
            let pct = Int((steepest / comfortCap) * 100)
            return "Peak pitch ~\(Int(steepest))° (\(pct)% of your comfort cap) — watch the top section."
        }
        if let diff = maxDiff, diff == .doubleBlack {
            return "Includes a double-black — the fastest path to the meeting point crosses expert terrain."
        }
        if anyGroomed, !anyMoguls {
            return "Groomed main line, no moguls — easiest available path."
        }
        return "Balanced run mix matching your skill profile."
    }
}

// RunDifficulty.displayName is defined in MountainGraph.swift

private extension String {
    /// `nil` when empty/whitespace-only, else `self`. Lets us write
    /// `naming.edgeLabel(...).nilIfEmpty ?? fallback` in one expression.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
