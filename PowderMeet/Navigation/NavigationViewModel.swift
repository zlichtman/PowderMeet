//
//  NavigationViewModel.swift
//  PowderMeet
//
//  UI-facing facade over RouteProgressTracker. Consolidates consecutive
//  same-trail edges into one "maneuver" and exposes it as a Maneuver struct
//  the nav bar can consume directly. Lives between the tracker (state
//  machine) and the view (pure render).
//

import Foundation
import Observation

@MainActor @Observable
final class NavigationViewModel {
    struct Maneuver: Equatable {
        let iconSymbolName: String
        let verb: String
        let primaryName: String
        let transitionTo: String?
        let transitionDifficulty: RunDifficulty?
        let remainingMeters: Double
        let difficulty: RunDifficulty?
    }

    private let tracker: RouteProgressTracker
    private let profile: UserProfile
    /// Used only for `MountainNaming` resolution so the next-maneuver
    /// label matches the picker / EdgeInfoCard / route step card on
    /// the same edge. Optional so callers can construct without a
    /// loaded graph (cold-start) — names then fall back to a bare
    /// kind label until a recompute fires post-load.
    private let naming: MountainNaming?

    var currentManeuver: Maneuver?
    var nextManeuver: Maneuver?

    init(tracker: RouteProgressTracker, profile: UserProfile, graph: MountainGraph?) {
        self.tracker = tracker
        self.profile = profile
        self.naming = graph.map(MountainNaming.init)
        recompute()
    }

    /// Call when the underlying tracker advances or the path changes.
    func recompute() {
        let (current, next) = extractManeuvers(from: tracker.path, startingAt: tracker.currentEdgeIndex)
        currentManeuver = current
        nextManeuver = next
    }

    // MARK: - Merge logic

    private func extractManeuvers(from path: [GraphEdge], startingAt index: Int) -> (Maneuver?, Maneuver?) {
        guard index < path.count else { return (nil, nil) }
        let (currentRange, currentName) = mergeRun(path: path, from: index)
        let current = maneuver(
            from: path,
            range: currentRange,
            mergedName: currentName,
            next: currentRange.upperBound < path.count ? path[currentRange.upperBound] : nil,
            firstEdgeRemainingMeters: tracker.currentEdgeRemainingMeters
        )
        guard currentRange.upperBound < path.count else { return (current, nil) }
        let (nextRange, nextName) = mergeRun(path: path, from: currentRange.upperBound)
        let next = maneuver(from: path, range: nextRange, mergedName: nextName, next: nextRange.upperBound < path.count ? path[nextRange.upperBound] : nil)
        return (current, next)
    }

    /// Uses the same identity/difficulty boundaries as cards and directions.
    private func mergeRun(path: [GraphEdge], from start: Int) -> (Range<Int>, String) {
        let first = path[start]
        let firstName = label(for: first)
        var end = start + 1
        while end < path.count {
            let next = path[end]
            let nextName = label(for: next)
            guard RouteInstructionGrouping.canMerge(
                path[end - 1], next,
                previousLabel: firstName, nextLabel: nextName
            ) else { break }
            end += 1
        }
        return (start..<end, firstName)
    }

    private func maneuver(
        from path: [GraphEdge],
        range: Range<Int>,
        mergedName: String,
        next: GraphEdge?,
        firstEdgeRemainingMeters: Double? = nil
    ) -> Maneuver {
        let slice = path[range]
        // mergeRun's invariant guarantees `start < end` so slice.first is
        // always non-nil; a precondition makes that load-bearing assumption
        // explicit and gives a clear crash message if a future change to
        // mergeRun violates it.
        precondition(!slice.isEmpty, "maneuver(from:range:): empty slice — mergeRun invariant violated")
        let current = slice.first!
        var totalMeters = slice.reduce(0.0) { $0 + $1.attributes.lengthMeters }
        if let firstEdgeRemainingMeters {
            totalMeters -= current.attributes.lengthMeters
            totalMeters += max(0, firstEdgeRemainingMeters)
        }
        return Maneuver(
            // The turn is at the end of the consolidated trail, not at the
            // end of its first source fragment (which may face elsewhere).
            iconSymbolName: ManeuverIconResolver.symbolName(for: slice.last!, next: next),
            verb: ManeuverIconResolver.verb(for: current),
            primaryName: mergedName.uppercased(),
            transitionTo: next.map { label(for: $0).uppercased() },
            transitionDifficulty: next?.kind == .run ? next?.attributes.difficulty : nil,
            remainingMeters: totalMeters,
            difficulty: current.kind == .run ? current.attributes.difficulty : nil
        )
    }

    /// Resolve an edge to a display name through MountainNaming when
    /// we have one. Mirrors RouteStepConsolidator so the route-step
    /// card and the maneuver HUD agree on the same edge.
    private func label(for edge: GraphEdge) -> String {
        RouteInstructionGrouping.label(for: edge, naming: naming)
    }
}
