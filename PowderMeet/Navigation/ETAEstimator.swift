//
//  ETAEstimator.swift
//  PowderMeet
//
//  Blends the solver's ETA with a measured-speed estimate. Early in the
//  route, the solver prior dominates (we have no speed samples yet). After
//  ~30s of driving, the measured estimate contributes up to 70%. Never
//  100% — momentary stops (lift line, dismount) shouldn't blow up ETA.
//
//  Kalman filtering is the long-term ideal but requires a proper bimodal
//  motion model (lift ~3 m/s vs downhill 5–15 m/s). An EMA on speed with
//  confidence-weighted blending captures 90% of the benefit with far less
//  tuning surface.
//

import Foundation
import CoreLocation

protocol ETAEstimator: AnyObject {
    func ingest(location: CLLocationCoordinate2D, timestamp: Date, remainingMeters: Double)
    func reset(solverEstimateSeconds: Double, remainingMeters: Double)
    var smoothedETASeconds: Double { get }
    var lastBroadcastETA: Double? { get set }
    /// Pure predicate — `true` if the delta vs. last broadcast warrants a
    /// network update. Does NOT mutate broadcast state; call `didBroadcast`
    /// after the network send succeeds to record it.
    func shouldBroadcast(now: Date) -> Bool
    /// Record a successful broadcast so subsequent `shouldBroadcast` calls
    /// use the updated baseline.
    func didBroadcast(now: Date)
}

final class BlendedETAEstimator: ETAEstimator {

    // MARK: - Tuning Constants

    /// EMA α on speed samples. τ = -Δt / ln(1-α). At 1 Hz fixes, α=0.2 → τ≈4.5s.
    /// Fast enough to react to a downhill pickup, slow enough to ignore a
    /// lift-pylon GPS dropout.
    private let speedEMAAlpha: Double = 0.2

    /// Number of samples at which measured weight saturates at its cap.
    private let samplesToFullConfidence: Double = 30

    /// Maximum weight the measured estimate can reach. Never 100% — lift lines
    /// and chairlift dismounts produce zero-speed fixes we don't want to trust.
    private let measuredWeightCap: Double = 0.7

    /// Reject samples faster than this (m/s). Skiing tops out around
    /// ~28 m/s (100 km/h) on race courses; everything above is a GPS
    /// dropout/teleport. One such sample, unfiltered, can poison the EMA
    /// for ~30s at α=0.2.
    private let maxPlausibleSpeed: Double = 30.0  // m/s = 67 mph

    /// Warm-up: discard the first few samples even if plausible. GPS-fix
    /// quality during cold-start (acquisition) is unreliable; waiting for
    /// stable readings before letting the EMA accept input prevents the
    /// estimator from anchoring on garbage.
    private let warmUpSamples: Int = 3

    /// Broadcast threshold: delta vs. last broadcast.
    private let broadcastDeltaSeconds: Double = 15

    /// Rate limit between broadcasts.
    private let broadcastMinIntervalSeconds: Double = 5

    // MARK: - State

    private var solverPriorSeconds: Double = 0
    private var speedEMA: Double?
    private var sampleCount: Int = 0
    private var warmUpAccepted: Int = 0
    private var lastLocation: CLLocationCoordinate2D?
    private var lastTimestamp: Date?
    private var currentRemainingMeters: Double = 0
    var lastBroadcastETA: Double?
    private var lastBroadcastAt: Date?

    // MARK: - ETAEstimator

    func reset(solverEstimateSeconds: Double, remainingMeters: Double) {
        solverPriorSeconds = solverEstimateSeconds
        speedEMA = nil
        sampleCount = 0
        warmUpAccepted = 0
        lastLocation = nil
        lastTimestamp = nil
        currentRemainingMeters = remainingMeters
    }

    func ingest(location: CLLocationCoordinate2D, timestamp: Date, remainingMeters: Double) {
        currentRemainingMeters = remainingMeters

        defer {
            lastLocation = location
            lastTimestamp = timestamp
        }

        guard let last = lastLocation, let lastTime = lastTimestamp else { return }
        let dt = timestamp.timeIntervalSince(lastTime)
        guard dt > 0.1 else { return } // de-dup duplicate fixes

        let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
        let b = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let distance = a.distance(from: b)
        let instantaneousSpeed = distance / dt

        // Plausibility: skiing speeds are bounded. A 100+ m/s "speed" is
        // a GPS teleport (signal reacquisition after a dropout, or simulator
        // jump) and would poison the EMA for ~30s at α=0.2. Drop it.
        guard instantaneousSpeed <= maxPlausibleSpeed else {
            // Don't increment sampleCount or warmUpAccepted — this fix
            // didn't tell us anything trustworthy.
            return
        }

        // Skip samples with no real movement so standing still doesn't
        // pull the EMA to zero and blow up ETA.
        guard instantaneousSpeed > 0.5 else { return }

        // Warm-up: discard the first few plausible samples completely. GPS
        // accuracy during acquisition is too noisy to anchor an estimator
        // on; we want a few stable readings first.
        guard warmUpAccepted >= warmUpSamples else {
            warmUpAccepted += 1
            return
        }

        // Accept into EMA.
        if let current = speedEMA {
            speedEMA = current * (1 - speedEMAAlpha) + instantaneousSpeed * speedEMAAlpha
        } else {
            speedEMA = instantaneousSpeed
        }
        sampleCount += 1
    }

    var smoothedETASeconds: Double {
        // Defensive: a negative `currentRemainingMeters` would give a
        // negative ETA that broadcasts as nonsense. The tracker should
        // clamp to 0 on completion, but a reroute that lands mid-update
        // could briefly leave it stale. Fall back to the solver prior
        // until the next update fixes it.
        guard currentRemainingMeters > 0 else { return solverPriorSeconds }

        let measuredWeight = min(measuredWeightCap, Double(sampleCount) / samplesToFullConfidence)
        let measuredETA: Double = {
            guard let speed = speedEMA, speed > 0.1 else { return solverPriorSeconds }
            return currentRemainingMeters / speed
        }()
        return solverPriorSeconds * (1 - measuredWeight) + measuredETA * measuredWeight
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

    func didBroadcast(now: Date) {
        lastBroadcastETA = smoothedETASeconds
        lastBroadcastAt = now
    }
}
