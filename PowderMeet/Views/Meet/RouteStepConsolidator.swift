//
//  RouteStepConsolidator.swift
//  PowderMeet
//
//  Shared route-step consolidation used by meeting-option and active-meetup cards.
//  Collapses consecutive edges on the same named trail/lift into a single display step.
//

import SwiftUI

struct RouteStep {
    let name: String
    let icon: String
    let iconColor: Color
    let difficulty: RunDifficulty?
}

@MainActor
enum RouteStepConsolidator {

    /// Collapse a path of edges into user-facing route steps. Consecutive
    /// edges sharing a label merge into one step.
    ///
    /// Pass the graph so we resolve names through `MountainNaming` —
    /// the same path the picker, EdgeInfoCard, and profile HUD use.
    /// Without it, two disconnected chains with the same difficulty
    /// would both render as plain "BLACK"; with it, they get the
    /// canonical chain titles ("Black · #1" / "Black · #2") that
    /// match what the user sees elsewhere in the app.
    ///
    /// `graph == nil` is tolerated for two reasons: (a) the cards
    /// themselves accept `MountainGraph?` so layouts can render
    /// during graph-load; (b) keeps the API safe to call with raw
    /// data (e.g. tests). The fallback uses bare difficulty/lift
    /// type names — same as the prior behavior.
    ///
    /// `@MainActor` because `MountainNaming.init` reads a process-wide
    /// `NSCache` whose Sendable inference under Swift 6 strict
    /// concurrency requires main-actor isolation. Both call sites
    /// (active-meetup card, meeting-option card) are SwiftUI views
    /// already running on the main actor, so the annotation is free.
    static func consolidate(_ path: [GraphEdge], graph: MountainGraph? = nil) -> [RouteStep] {
        let naming = graph.map(MountainNaming.init)
        var steps: [RouteStep] = []
        var lastName: String?

        for edge in path {
            let displayName = label(for: edge, naming: naming)
            if displayName == lastName { continue }
            lastName = displayName

            let icon: String
            let iconColor: Color
            switch edge.kind {
            case .lift:
                icon = "arrow.up"
                iconColor = HUDTheme.accentAmber
            case .run:
                icon = "arrow.down"
                iconColor = edge.attributes.difficulty.map { HUDTheme.color(for: $0) } ?? HUDTheme.secondaryText
            case .traverse:
                icon = "arrow.right"
                iconColor = HUDTheme.secondaryText
            }

            steps.append(RouteStep(
                name: displayName,
                icon: icon,
                iconColor: iconColor,
                difficulty: edge.kind == .run ? edge.attributes.difficulty : nil
            ))
        }
        return steps
    }

    /// Maps a raw edge index (from RouteProgressTracker) to its
    /// consolidated step index. Returns nil if the raw index is nil
    /// or outside the path. Pass the same graph used for `consolidate`
    /// — both must use the same labelling source so step boundaries
    /// stay aligned.
    static func consolidatedIndex(
        for path: [GraphEdge],
        rawEdgeIndex: Int?,
        graph: MountainGraph? = nil
    ) -> Int? {
        guard let rawIdx = rawEdgeIndex else { return nil }
        let naming = graph.map(MountainNaming.init)
        var stepIndex = 0
        var lastName: String?
        var isFirst = true
        for (i, edge) in path.enumerated() {
            let name = label(for: edge, naming: naming)
            let isMerged = (name == lastName)
            if !isMerged {
                if !isFirst { stepIndex += 1 }
                isFirst = false
            }
            lastName = name
            if i == rawIdx { return stepIndex }
        }
        return nil
    }

    /// Resolve a single edge to a display label. Routes through
    /// MountainNaming when a graph is available so the route HUD
    /// agrees with every other surface that names this edge.
    private static func label(for edge: GraphEdge, naming: MountainNaming?) -> String {
        if let naming {
            return naming.edgeLabel(edge, style: .bareName)
        }
        // No graph — best-effort fallback. Unchanged from the prior
        // private helper so callers without a graph still see something.
        switch edge.kind {
        case .lift:     return edge.attributes.liftType?.displayName ?? "Lift"
        case .run:      return edge.attributes.difficulty?.displayName ?? "Run"
        case .traverse: return "Traverse"
        }
    }
}
