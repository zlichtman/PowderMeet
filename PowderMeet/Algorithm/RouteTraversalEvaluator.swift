//
//  RouteTraversalEvaluator.swift
//  PowderMeet
//
//  One edge-level contract for search, stored-route validation, and live ETA.
//  Keep mean travel time distinct from the conservative last-loading check.
//

import Foundation

/// Exact provenance contract emitted by both source graph builders: a lift
/// l<OSM way ID> split at shared vertices becomes l<ID>_vx1, _vx2, ... .
/// Names and visual trail groups are NOT proof that two lifts are one ride.
/// Unknown/legacy identities conservatively keep boarding-hour checks.
nonisolated enum LiftRideContinuation {
    static func isContinuation(from previous: GraphEdge?, to next: GraphEdge) -> Bool {
        guard let previous, previous.kind == .lift, next.kind == .lift,
              previous.targetID == next.sourceID,
              next.attributes.chargesLiftWait == false else { return false }
        func sourceSegment(_ id: String) -> (source: String, index: Int)? {
            let parts = id.components(separatedBy: "_vx")
            guard parts.count == 2, parts[0].first == "l",
                  !parts[0].dropFirst().isEmpty,
                  parts[0].dropFirst().utf8.allSatisfy({ (48...57).contains($0) }),
                  let index = Int(parts[1]), index > 0,
                  String(index) == parts[1] else { return nil }
            return (parts[0], index)
        }
        guard let before = sourceSegment(previous.id), let after = sourceSegment(next.id),
              before.source == after.source, after.index > 1,
              before.index == after.index - 1,
              previous.attributes.chargesLiftWait == (before.index == 1) else { return false }
        return true
    }
}

nonisolated enum RouteTraversalEvaluator {
    struct Cost {
        let seconds: Double
        let variance: Double
    }

    static func evaluate(
        edge: GraphEdge,
        profile: UserProfile,
        context: TraversalContext,
        elapsedSeconds: Double,
        approachVariance: Double,
        remainingFraction: Double = 1,
        ignoreSkillGates: Bool = false,
        ignoreLiftDeadlineRisk: Bool = false,
        previousEdge: GraphEdge? = nil
    ) -> Cost? {
        guard let seconds = profile.traverseTime(
            for: edge, context: context, ignoreSkillGates: ignoreSkillGates,
            arrivalTimeOffsetSeconds: elapsedSeconds,
            remainingFraction: remainingFraction, previousEdge: previousEdge
        ) else { return nil }

        // A fractional lift means the skier is already aboard. Do not demand
        // that they join its entry queue again, including after last chair.
        if edge.kind == .lift, remainingFraction >= 1,
           !LiftRideContinuation.isContinuation(from: previousEdge, to: edge),
           context.solveTime != nil, !ignoreLiftDeadlineRisk,
           approachVariance > 0 {
            let conservativeArrival = elapsedSeconds
                + SolverConstants.Scoring.liftCatchConfidenceZ * approachVariance.squareRoot()
            guard profile.traverseTime(
                for: edge, context: context, ignoreSkillGates: ignoreSkillGates,
                arrivalTimeOffsetSeconds: conservativeArrival,
                remainingFraction: remainingFraction, previousEdge: previousEdge
            ) != nil else { return nil }
        }

        return Cost(seconds: seconds, variance: edgeTimeVariance(
            seconds: seconds, edge: edge, observation: context.observation(for: edge)
        ))
    }

    /// Delta-method measured speed variance when trusted; otherwise the
    /// existing per-kind CV model (run 15%, lift 30%, connector 10%). Physical
    /// fragments are correlated by RouteTimeUncertainty after this step.
    private static func edgeTimeVariance(
        seconds: Double, edge: GraphEdge, observation: PerEdgeSpeed?
    ) -> Double {
        guard seconds > 0 else { return 0 }
        if let observation,
           observation.observationCount >= TraversalContext.edgeHistoryMinObservations,
           observation.rollingSpeedMs > 0,
           observation.rollingSpeedVarianceMs2 > 0 {
            let ratio = seconds / observation.rollingSpeedMs
            return ratio * ratio * observation.rollingSpeedVarianceMs2
        }
        let cv: Double
        switch edge.kind {
        case .lift: cv = 0.30
        case .run: cv = 0.15
        case .traverse: cv = 0.10
        }
        let standardDeviation = seconds * cv
        return standardDeviation * standardDeviation
    }
}
