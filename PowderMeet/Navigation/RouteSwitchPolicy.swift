//
//  RouteSwitchPolicy.swift
//  PowderMeet
//
//  Pure decision policy for swapping an already-active route after a faster
//  path appears. Safety/deviation reroutes bypass this policy entirely.
//

import Foundation

nonisolated enum RouteSwitchDecision: Equatable, Sendable {
    case keepSamePath
    case keepNearArrival
    case keepReliabilityRegression
    case keepInsufficientGain(requiredSeconds: Double)
    case keepDuringStabilityWindow(requiredSeconds: Double)
    case switchRoute(gainSeconds: Double)
}

/// Prevents route-line oscillation without delaying a closure or off-route
/// recovery. A newly opened route must save both a useful absolute amount and
/// a useful percentage. Immediately after an applied optimization, the bar is
/// temporarily higher and decays continuously back to the normal threshold.
nonisolated enum RouteSwitchPolicy {
    static let nearArrivalSeconds: Double = 30
    static let minimumGainSeconds: Double = 30
    static let normalGainFraction: Double = 0.10
    static let stabilityWindowSeconds: TimeInterval = 2 * 60
    static let immediateReswitchMinimumSeconds: Double = 2 * 60
    static let immediateReswitchGainFraction: Double = 0.20

    static func decide(
        currentRemainingSeconds: Double,
        candidateSeconds: Double,
        currentUncertaintySeconds: Double? = nil,
        candidateUncertaintySeconds: Double? = nil,
        currentRemainingEdgeIDs: [String],
        candidateEdgeIDs: [String],
        secondsSinceLastAppliedSwitch: TimeInterval?
    ) -> RouteSwitchDecision {
        if currentRemainingEdgeIDs == candidateEdgeIDs {
            return .keepSamePath
        }
        guard currentRemainingSeconds.isFinite,
              candidateSeconds.isFinite,
              currentRemainingSeconds > nearArrivalSeconds,
              candidateSeconds >= 0 else {
            return .keepNearArrival
        }

        // An optimization-only shortcut must improve real arrival, not just
        // its optimistic mean. Use the same risk weight as meet selection.
        // Missing legacy uncertainty preserves the established mean-time
        // behavior; production solver outputs always provide both values.
        if let currentUncertaintySeconds,
           let candidateUncertaintySeconds,
           currentUncertaintySeconds.isFinite,
           candidateUncertaintySeconds.isFinite,
           currentUncertaintySeconds >= 0,
           candidateUncertaintySeconds >= 0 {
            let currentReliable = currentRemainingSeconds
                + SolverConstants.Scoring.cvarBeta * currentUncertaintySeconds
            let candidateReliable = candidateSeconds
                + SolverConstants.Scoring.cvarBeta * candidateUncertaintySeconds
            if candidateReliable > currentReliable { return .keepReliabilityRegression }
        }

        let gain = currentRemainingSeconds - candidateSeconds
        let normalRequired = max(
            minimumGainSeconds,
            currentRemainingSeconds * normalGainFraction
        )

        guard let secondsSinceLastAppliedSwitch,
              secondsSinceLastAppliedSwitch >= 0,
              secondsSinceLastAppliedSwitch < stabilityWindowSeconds else {
            return gain >= normalRequired
                ? .switchRoute(gainSeconds: gain)
                : .keepInsufficientGain(requiredSeconds: normalRequired)
        }

        let immediateRequired = max(
            immediateReswitchMinimumSeconds,
            currentRemainingSeconds * immediateReswitchGainFraction
        )
        let remainingStability = 1
            - secondsSinceLastAppliedSwitch / stabilityWindowSeconds
        let required = normalRequired
            + (immediateRequired - normalRequired) * remainingStability

        return gain >= required
            ? .switchRoute(gainSeconds: gain)
            : .keepDuringStabilityWindow(requiredSeconds: required)
    }
}
