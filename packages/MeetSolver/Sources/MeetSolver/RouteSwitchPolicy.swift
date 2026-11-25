import Foundation
import MountainCore

public enum RouteSwitchDecision: Hashable, Sendable {
    case keepSamePath
    case keepNearArrival
    case keepReliabilityRegression
    case keepInsufficientGain(requiredS: Double)
    case keepDuringStabilityWindow(requiredS: Double)
    case switchRoute(gainS: Double)
}

/// Whether to swap an active route for a faster one to the same rendezvous. It
/// stops the route line from oscillating; closure and off-route reroutes do not
/// pass through it. A new route must save a useful absolute amount and a useful
/// share, and just after a switch the bar is higher and decays back to normal.
public enum RouteSwitchPolicy {
    public static let nearArrivalS = 30.0
    public static let minimumGainS = 30.0
    public static let normalGainFraction = 0.10
    public static let stabilityWindowS = 2.0 * 60
    public static let immediateReswitchMinimumS = 2.0 * 60
    public static let immediateReswitchGainFraction = 0.20

    public static func decide(
        current: ETA, currentRemainingEdgeIDs: [EdgeID], candidate: Route,
        secondsSinceLastSwitch: TimeInterval?
    ) -> RouteSwitchDecision {
        if currentRemainingEdgeIDs == candidate.legs.map(\.edgeID) { return .keepSamePath }
        let currentS = current.meanS, candidateS = candidate.eta.meanS
        guard currentS.isFinite, candidateS.isFinite, currentS > nearArrivalS, candidateS >= 0 else {
            return .keepNearArrival
        }
        // A shortcut must improve dependable arrival, not only its optimistic mean.
        if current.sdS.isFinite, candidate.eta.sdS.isFinite, current.sdS >= 0, candidate.eta.sdS >= 0,
           candidateS + Scoring.cvarBeta * candidate.eta.sdS > currentS + Scoring.cvarBeta * current.sdS {
            return .keepReliabilityRegression
        }

        let gain = currentS - candidateS
        let normalRequired = max(minimumGainS, currentS * normalGainFraction)
        guard let since = secondsSinceLastSwitch, since >= 0, since < stabilityWindowS else {
            return gain >= normalRequired
                ? .switchRoute(gainS: gain) : .keepInsufficientGain(requiredS: normalRequired)
        }
        let immediateRequired = max(immediateReswitchMinimumS, currentS * immediateReswitchGainFraction)
        let required = normalRequired
            + (immediateRequired - normalRequired) * (1 - since / stabilityWindowS)
        return gain >= required
            ? .switchRoute(gainS: gain) : .keepDuringStabilityWindow(requiredS: required)
    }
}
