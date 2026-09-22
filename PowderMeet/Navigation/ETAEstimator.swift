//
//  ETAEstimator.swift
//  PowderMeet
//
//  Blends the solver's exact remaining-route ETA with measured pace on the
//  current ski edge. After ~30s moving on one run/connector, its adjustment
//  contributes up to 70%; all lift rides/queues and future runs keep modeled
//  costs. Never 100% — momentary stops shouldn't blow up ETA.
//
//  Kalman filtering is the long-term ideal but requires a proper bimodal
//  motion model (lift ~3 m/s vs downhill 5–15 m/s). An EMA on speed with
//  confidence-weighted blending captures 90% of the benefit with far less
//  tuning surface.
//

import Foundation
import CoreLocation

nonisolated struct ActiveRouteETAEstimate: Equatable, Sendable {
    let totalSeconds: Double
    let currentEdgeSeconds: Double
}

/// Re-costs the exact remaining active path against current time-dependent
/// physics. nil means at least one remaining edge is no longer traversable;
/// callers must reroute or invalidate, never omit that edge from the sum.
nonisolated enum ActiveRouteETA {
    static func estimate(
        path: [GraphEdge],
        currentEdgeIndex: Int,
        currentEdgeFraction: Double,
        profile: UserProfile,
        context: TraversalContext
    ) -> ActiveRouteETAEstimate? {
        guard currentEdgeIndex < path.count else {
            return ActiveRouteETAEstimate(totalSeconds: 0, currentEdgeSeconds: 0)
        }
        var total = 0.0
        var currentEdgeSeconds = 0.0
        var uncertainty = RouteTimeUncertainty()
        for (offset, edge) in path[currentEdgeIndex...].enumerated() {
            let remainingFraction = offset == 0
                ? 1 - max(0, min(1, currentEdgeFraction))
                : 1
            guard let cost = RouteTraversalEvaluator.evaluate(
                edge: edge,
                profile: profile,
                context: context,
                elapsedSeconds: total,
                approachVariance: uncertainty.varianceTime,
                remainingFraction: remainingFraction,
                previousEdge: currentEdgeIndex + offset > 0 ? path[currentEdgeIndex + offset - 1] : nil
            ) else { return nil }
            if offset == 0 { currentEdgeSeconds = cost.seconds }
            total += cost.seconds
            uncertainty.append(edge: edge, variance: cost.variance)
        }
        return ActiveRouteETAEstimate(
            totalSeconds: total,
            currentEdgeSeconds: currentEdgeSeconds
        )
    }

    static func seconds(
        path: [GraphEdge],
        currentEdgeIndex: Int,
        currentEdgeFraction: Double,
        profile: UserProfile,
        context: TraversalContext
    ) -> Double? {
        estimate(
            path: path,
            currentEdgeIndex: currentEdgeIndex,
            currentEdgeFraction: currentEdgeFraction,
            profile: profile,
            context: context
        )?.totalSeconds
    }
}

protocol ETAEstimator: AnyObject {
    func ingest(location: CLLocationCoordinate2D, timestamp: Date, remainingMeters: Double)
    func reset(solverEstimateSeconds: Double, remainingMeters: Double)
    var smoothedETASeconds: Double { get }
    var lastBroadcastETA: Double? { get set }
    /// Pure predicate — `true` if the delta vs. last broadcast warrants a
    /// network update. Does NOT mutate broadcast state; call `didBroadcast`
    /// after the network send succeeds to record it.
    func shouldBroadcast(now: Date) -> Bool
    /// Record the exact ETA value acknowledged by the server. The estimator
    /// may keep changing while a slow request is in flight, so sampling
    /// `smoothedETASeconds` at completion would claim an unsent value was
    /// already delivered and suppress the corrective follow-up.
    func didBroadcast(etaSeconds: Double, now: Date)
}

final class BlendedETAEstimator: ETAEstimator {

    // MARK: - Tuning Constants

    /// EMA α on speed samples. τ = -Δt / ln(1-α). At 1 Hz fixes, α=0.2 → τ≈4.5s.
    /// Fast enough to react to a downhill pickup, slow enough to ignore a
    /// lift-pylon GPS dropout.
    private let speedEMAAlpha: Double = 0.2

    /// Actual moving seconds, independent of the CoreLocation delivery rate.
    private let movingSecondsToFullConfidence: TimeInterval = 30

    /// Local pace is no longer representative after a long stop or unobserved
    /// interval. This conservative heuristic is not a GPS accuracy guarantee.
    private let maximumMotionGapSeconds: TimeInterval = 30

    /// Maximum weight the measured estimate can reach. Never 100% — lift lines
    /// and chairlift dismounts produce zero-speed fixes we don't want to trust.
    private let measuredWeightCap: Double = 0.7

    /// Reject samples faster than this (m/s). Skiing tops out around
    /// ~28 m/s (100 km/h) on race courses; everything above is a GPS
    /// dropout/teleport. One such sample, unfiltered, can poison the EMA
    /// for ~30s at α=0.2.
    private let maxPlausibleSpeed: Double = 30.0  // m/s = 67 mph

    /// Warm-up: discard the first few moving seconds even if plausible. GPS-fix
    /// quality during cold-start (acquisition) is unreliable; waiting for
    /// stable readings before letting the EMA accept input prevents the
    /// estimator from anchoring on garbage.
    private let warmUpSeconds: TimeInterval = 3

    /// Broadcast threshold: delta vs. last broadcast.
    private let broadcastDeltaSeconds: Double = 15

    /// Rate limit between broadcasts.
    private let broadcastMinIntervalSeconds: Double = 5

    // MARK: - State

    private var solverPriorSeconds: Double = 0
    private var initialRemainingMeters: Double = 0
    private var speedEMA: Double?
    private var movingSeconds: TimeInterval = 0
    private var warmUpAcceptedSeconds: TimeInterval = 0
    private var lastMovementTimestamp: Date?
    private var lastLocation: CLLocationCoordinate2D?
    private var lastTimestamp: Date?
    /// Separate from the motion baseline, which survives a rejected teleport
    /// and resets on edge transitions. Capture ordering must survive both.
    private var lastIngestTimestamp: Date?
    private var currentRemainingMeters: Double = 0
    /// Exact current-time recost of the unfinished route. Observed speed may
    /// adjust only its current edge; future lifts, queues, and runs remain
    /// priced by the route model instead of being divided by downhill speed.
    private var activeRouteEstimate: ActiveRouteETAEstimate?
    private var activeEdgeRemainingMeters: Double = 0
    private var activeEdgeID: String?
    private var activeEdgeKind: GraphEdge.EdgeKind?
    var lastBroadcastETA: Double?
    private var lastBroadcastAt: Date?

    // MARK: - ETAEstimator

    func reset(solverEstimateSeconds: Double, remainingMeters: Double) {
        solverPriorSeconds = max(0, solverEstimateSeconds)
        initialRemainingMeters = max(0, remainingMeters)
        resetMotionEvidence()
        lastLocation = nil
        lastTimestamp = nil
        currentRemainingMeters = max(0, remainingMeters)
        activeRouteEstimate = nil
        lastIngestTimestamp = nil
        activeEdgeRemainingMeters = 0
        activeEdgeID = nil
        activeEdgeKind = nil
        lastBroadcastETA = nil
        lastBroadcastAt = nil
    }

    /// Refreshes the physics-based baseline for the exact unfinished route.
    /// A trail/lift transition resets motion samples so downhill pace can
    /// never leak into lift travel (or vice versa).
    func updateRouteEstimate(
        _ estimate: ActiveRouteETAEstimate,
        currentEdgeRemainingMeters: Double,
        edgeID: String?,
        edgeKind: GraphEdge.EdgeKind?
    ) {
        if activeEdgeID != edgeID || activeEdgeKind != edgeKind {
            resetMotionEvidence()
            lastLocation = nil
            lastTimestamp = nil
        }
        activeEdgeID = edgeID
        activeEdgeKind = edgeKind
        activeRouteEstimate = ActiveRouteETAEstimate(
            totalSeconds: max(0, estimate.totalSeconds),
            currentEdgeSeconds: max(0, estimate.currentEdgeSeconds)
        )
        activeEdgeRemainingMeters = max(0, currentEdgeRemainingMeters)
    }

    func ingest(location: CLLocationCoordinate2D, timestamp: Date, remainingMeters: Double) {
        guard CLLocationCoordinate2DIsValid(location),
              timestamp.timeIntervalSinceReferenceDate.isFinite else { return }
        if let lastIngestTimestamp, timestamp <= lastIngestTimestamp { return }
        lastIngestTimestamp = timestamp
        currentRemainingMeters = max(0, remainingMeters)

        guard let last = lastLocation, let lastTime = lastTimestamp else {
            lastLocation = location
            lastTimestamp = timestamp
            return
        }
        let dt = timestamp.timeIntervalSince(lastTime)
        guard dt > 0.1 else { return } // de-dup duplicate fixes

        guard dt <= maximumMotionGapSeconds else {
            // Do not interpret an unobserved minute as continuous movement,
            // or carry pre-gap confidence into the next few fixes.
            resetMotionEvidence()
            lastLocation = location
            lastTimestamp = timestamp
            return
        }

        let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
        let b = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let distance = a.distance(from: b)
        let instantaneousSpeed = distance / dt

        // Plausibility: skiing speeds are bounded. A 100+ m/s "speed" is
        // a GPS teleport (signal reacquisition after a dropout, or simulator
        // jump) and would poison the EMA for ~30s at α=0.2. Drop it.
        guard instantaneousSpeed <= maxPlausibleSpeed else {
            // Keep the previous trustworthy baseline. Otherwise the next real
            // fix looks like a second teleport while returning from this one.
            return
        }

        // A plausible stationary fix should advance the baseline so the next
        // movement sample measures only its own time interval.
        lastLocation = location
        lastTimestamp = timestamp

        // Skip samples with no real movement so standing still doesn't
        // pull the EMA to zero and blow up ETA.
        guard instantaneousSpeed > 0.5 else {
            if let lastMovementTimestamp,
               timestamp.timeIntervalSince(lastMovementTimestamp) >= maximumMotionGapSeconds {
                resetMotionEvidence()
            }
            return
        }
        lastMovementTimestamp = timestamp

        // Warm-up: discard the first few plausible moving seconds. GPS
        // accuracy during acquisition is too noisy to anchor an estimator
        // on; we want a short period of stable readings first.
        let warmingSeconds = min(dt, max(0, warmUpSeconds - warmUpAcceptedSeconds))
        warmUpAcceptedSeconds += warmingSeconds
        let measuredSeconds = dt - warmingSeconds
        guard measuredSeconds > 0 else { return }

        // Accept into EMA.
        if let current = speedEMA {
            // speedEMAAlpha is the one-second response. Scaling it to the
            // measured interval keeps the smoothing horizon stable at 4 Hz,
            // 1 Hz, or battery-throttled delivery rates.
            let alpha = 1 - pow(1 - speedEMAAlpha, measuredSeconds)
            speedEMA = current * (1 - alpha) + instantaneousSpeed * alpha
        } else {
            speedEMA = instantaneousSpeed
        }
        movingSeconds = min(movingSecondsToFullConfidence, movingSeconds + measuredSeconds)
    }

    private func resetMotionEvidence() {
        speedEMA = nil
        movingSeconds = 0
        warmUpAcceptedSeconds = 0
        lastMovementTimestamp = nil
    }

    var smoothedETASeconds: Double {
        // Arrival must broadcast zero. Returning the original solver prior at
        // zero distance left the partner seeing a stale ETA after completion.
        guard currentRemainingMeters > 0 else { return 0 }

        let measuredWeight = measuredWeightCap
            * min(1, movingSeconds / movingSecondsToFullConfidence)

        if let activeRouteEstimate {
            // A queue's walking/GPS-drift speed says nothing about chairlift
            // ride time or how quickly the line will clear. Lift timing stays
            // with the operational model even after motion samples accumulate.
            guard activeEdgeKind != .lift, let speed = speedEMA, speed > 0.1 else {
                return activeRouteEstimate.totalSeconds
            }
            let measuredCurrentEdgeSeconds = activeEdgeRemainingMeters / speed
            let currentEdgeCorrection = measuredCurrentEdgeSeconds
                - activeRouteEstimate.currentEdgeSeconds
            return max(
                0,
                activeRouteEstimate.totalSeconds + currentEdgeCorrection * measuredWeight
            )
        }

        // Compatibility fallback for callers that have not supplied an exact
        // active-route recost. The prior describes the full route at reset
        // time and decays with distance progress instead of remaining constant
        // until enough measured-speed samples accumulate.
        let solverRemaining: Double = {
            guard initialRemainingMeters > 0 else { return solverPriorSeconds }
            return solverPriorSeconds * currentRemainingMeters / initialRemainingMeters
        }()

        let measuredETA: Double = {
            guard let speed = speedEMA, speed > 0.1 else { return solverRemaining }
            return currentRemainingMeters / speed
        }()
        return max(
            0,
            solverRemaining * (1 - measuredWeight) + measuredETA * measuredWeight
        )
    }

    func shouldBroadcast(now: Date) -> Bool {
        let currentETA = smoothedETASeconds
        if let last = lastBroadcastETA {
            guard abs(currentETA - last) >= broadcastDeltaSeconds else { return false }
        }
        if let lastAt = lastBroadcastAt {
            guard now.timeIntervalSince(lastAt) >= broadcastMinIntervalSeconds else { return false }
        }
        return true
    }

    func didBroadcast(etaSeconds: Double, now: Date) {
        guard etaSeconds.isFinite, etaSeconds >= 0 else { return }
        lastBroadcastETA = etaSeconds
        lastBroadcastAt = now
    }
}
