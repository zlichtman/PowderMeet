//
//  SolveFailureReason.swift
//  PowderMeet
//
//  Structured reasons the solver returns nil, with user-facing copy.
//  Extracted from MeetingPointSolver.swift.
//

import Foundation

// MARK: - Solve Failure Reasons

/// Structured reason for why the solver returned nil.
enum SolveFailureReason {
    case skierAtDeadEnd(skierName: String)
    case noReachableIntersection
    case skillGatedPath(diagnostics: [SkierCapabilityDiagnostic])
    case startingTerrainBlocked(diagnostic: SkierCapabilityDiagnostic)
    case noEligibleRendezvous
    case noReachableRendezvous
    case liftDeadlineRisk
    case allLiftsClosedInArea
    case operationalStatusUnavailable
    case mountainOffSeason
    case unknownPosition

    var userMessage: String {
        switch self {
        case .skierAtDeadEnd(let name):
            return "\(name) is at a location with no available routes. Try moving closer to a lift or trail."
        case .noReachableIntersection:
            return "No open path connects both positions with the current lift and trail status."
        case .skillGatedPath(let diagnostics):
            guard !diagnostics.isEmpty else {
                return "The only connecting routes exceed one or both skiers' marked difficulty or terrain limits."
            }
            return "No shared meeting route satisfies these requirements — "
                + diagnostics.map(\.userFacingSummary).joined(separator: "; ")
                + "."
        case .startingTerrainBlocked(let diagnostic):
            return "The available starting routes are blocked by these requirements — "
                + diagnostic.userFacingSummary + "."
        case .noEligibleRendezvous:
            return "This mountain dataset has no validated stopping points yet. Try again after the trail map updates."
        case .noReachableRendezvous:
            return "No validated meeting area is safely reachable from both positions with the current trail and lift status."
        case .liftDeadlineRisk:
            return "The only shared route depends on a lift that is too close to last chair to catch reliably. Move toward a lower meeting area or closer to the lift."
        case .allLiftsClosedInArea:
            return "All lifts in the area appear to be closed. Routes can't be calculated without lift access."
        case .operationalStatusUnavailable:
            return "Live trail and lift status is unavailable. Verify closures with the resort and try again when status refreshes."
        case .mountainOffSeason:
            return "This mountain is currently off season, so live ski routing is paused."
        case .unknownPosition:
            return "Unable to determine skier position on the mountain."
        }
    }
}
