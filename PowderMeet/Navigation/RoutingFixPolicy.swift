//
//  RoutingFixPolicy.swift
//  PowderMeet
//
//  Shared accuracy gate for any GPS fix allowed to change a route.
//

import Foundation
import CoreLocation

nonisolated enum RoutingFixPolicy {
    static let maximumHorizontalAccuracyMeters = 150.0
    static let maximumFixAgeSeconds: TimeInterval = 75
    static let maximumFutureSkewSeconds: TimeInterval = 30
    /// A precise fix still gets a modest corridor allowance for wide pistes,
    /// tree cover, and imperfect public trail geometry. A poor-but-usable fix
    /// may widen that allowance only to 120 m; it must never revive the legacy
    /// one-kilometre nearest-node teleport.
    static let minimumNetworkSnapToleranceMeters = 65.0
    static let maximumNetworkSnapToleranceMeters = 120.0

    /// Stateless local-origin resolution. A retry must assign this result,
    /// including nil, rather than retaining the last usable origin.
    static func currentOrigin(
        in graph: MountainGraph,
        coordinate: CLLocationCoordinate2D?,
        horizontalAccuracyMeters: Double?,
        capturedAt: Date?,
        travelCourseDegrees: Double? = nil,
        altitudeMeters: Double? = nil,
        verticalAccuracyMeters: Double? = nil,
        now: Date = .now
    ) -> RoutingOrigin? {
        guard let coordinate,
              isUsable(horizontalAccuracyMeters: horizontalAccuracyMeters,
                       capturedAt: capturedAt, now: now) else { return nil }
        return graph.routingOrigin(
            to: coordinate,
            travelCourseDegrees: travelCourseDegrees,
            altitudeMeters: altitudeMeters,
            verticalAccuracyMeters: verticalAccuracyMeters,
            maximumSnapDistanceMeters: networkSnapTolerance(horizontalAccuracyMeters: horizontalAccuracyMeters),
            positionUncertaintyMeters: positionUncertaintyMeters(horizontalAccuracyMeters: horizontalAccuracyMeters)
        )
    }

    static func isUsable(horizontalAccuracyMeters: Double?) -> Bool {
        guard let accuracy = horizontalAccuracyMeters else {
            return true // backward-compatible payload without accuracy
        }
        return accuracy >= 0 && accuracy <= maximumHorizontalAccuracyMeters
    }

    /// Local routing requires an actual recent Core Location capture. Network
    /// send time is not a substitute: heartbeats may repeat a coordinate after
    /// the GPS stream stalls or the phone backgrounds.
    static func isUsable(
        horizontalAccuracyMeters: Double?,
        capturedAt: Date?,
        now: Date = .now
    ) -> Bool {
        isUsable(horizontalAccuracyMeters: horizontalAccuracyMeters)
            && isFresh(capturedAt: capturedAt, now: now)
    }

    static func isFresh(capturedAt: Date?, now: Date = .now) -> Bool {
        guard let capturedAt else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age >= -maximumFutureSkewSeconds
            && age < maximumFixAgeSeconds
    }

    static func networkSnapTolerance(
        horizontalAccuracyMeters: Double?
    ) -> Double {
        guard let accuracy = horizontalAccuracyMeters,
              accuracy.isFinite,
              accuracy >= 0 else {
            return minimumNetworkSnapToleranceMeters
        }
        return min(
            maximumNetworkSnapToleranceMeters,
            max(minimumNetworkSnapToleranceMeters, accuracy)
        )
    }

    /// Core Location reports a radius-like horizontal uncertainty. Preserve it
    /// (bounded by the same route-eligibility cap) so ETA confidence can widen
    /// when the skier's exact along-trail position is unclear.
    static func positionUncertaintyMeters(
        horizontalAccuracyMeters: Double?
    ) -> Double {
        guard let accuracy = horizontalAccuracyMeters,
              accuracy.isFinite,
              accuracy >= 0 else { return 0 }
        return min(maximumHorizontalAccuracyMeters, accuracy)
    }

    /// Ten-metre UI bucket: coarse enough to ignore normal GPS noise, but an
    /// actual lock improvement/worsening must invalidate meeting solves because
    /// it changes both network eligibility and ETA confidence.
    static func accuracyFingerprintBucket(
        horizontalAccuracyMeters: Double?
    ) -> Int {
        guard let accuracy = horizontalAccuracyMeters,
              accuracy.isFinite,
              accuracy >= 0 else { return -1 }
        return Int((min(maximumHorizontalAccuracyMeters, accuracy) / 10).rounded())
    }
}
