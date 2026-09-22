//
//  RouteSimplicity.swift
//  PowderMeet
//
//  Canonical, bounded preference for ski routes that are easier to follow.
//  This never changes physical ETA or edge eligibility; it only breaks close
//  route choices after closures, capability, hours, and conditions are applied.
//

import Foundation

nonisolated enum RouteSimplicity {
    /// Stable identity for one user-visible route action. Canonical run-group
    /// identity prevents an OSM trail split from looking like extra decisions.
    /// Older graphs fall back to normalized names; only truly unnamed fragments
    /// use edge identity and therefore remain conservatively distinct.
    static func actionIdentity(for edge: GraphEdge) -> String {
        let kind = edge.kind.rawValue
        if let groupID = edge.attributes.trailGroupId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !groupID.isEmpty {
            return "\(kind):group:\(groupID)"
        }
        if let rawName = edge.attributes.trailName {
            let normalized = rawName
                .folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
            if !normalized.isEmpty {
                return "\(kind):name:\(normalized)"
            }
        }
        return "\(kind):edge:\(edge.id)"
    }

    static func transitionCount(in path: [GraphEdge]) -> Int {
        guard let first = path.first else { return 0 }
        var prior = actionIdentity(for: first)
        var count = 0
        for edge in path.dropFirst() {
            let next = actionIdentity(for: edge)
            if next != prior { count += 1 }
            prior = next
        }
        return count
    }

    /// Small score-only cost. Four or more changes saturate at 32 seconds, so
    /// a meaningfully faster route always wins; among near-ties, the skier gets
    /// fewer trail/lift transitions to remember while wearing gloves.
    static func preferencePenaltySeconds(forTransitionCount count: Int) -> Double {
        min(
            SolverConstants.Scoring.routeSimplicityMaximumPenaltySeconds,
            Double(max(0, count))
                * SolverConstants.Scoring.routeActionTransitionPenaltySeconds
        )
    }
}
