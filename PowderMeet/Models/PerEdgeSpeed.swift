//
//  PerEdgeSpeed.swift
//  PowderMeet
//
//  One row of `profile_edge_speeds` — per-(resort, edge, conditions)
//  rolling skill memory. Loaded into a `[String: PerEdgeSpeed]` dict
//  keyed by `edge_id` and consulted by `UserProfile.traverseTime`
//  before the bucketed-difficulty fallback.
//

import Foundation

struct PerEdgeSpeed: Codable, Sendable {
    let resortId: String
    let edgeId: String
    let conditionsFp: String
    let observationCount: Int
    let rollingSpeedMs: Double
    let rollingPeakMs: Double?
    let rollingDurationS: Double
    let lastObservedAt: Date

    enum CodingKeys: String, CodingKey {
        case resortId         = "resort_id"
        case edgeId           = "edge_id"
        case conditionsFp     = "conditions_fp"
        case observationCount = "observation_count"
        case rollingSpeedMs   = "rolling_speed_ms"
        case rollingPeakMs    = "rolling_peak_ms"
        case rollingDurationS = "rolling_duration_s"
        case lastObservedAt   = "last_observed_at"
    }

    /// Stable per-edge fingerprint built from attributes that carry over
    /// from import-time to solve-time (no live weather). Future revisions
    /// will fold weather snapshots into the fingerprint when we start
    /// stamping a snapshot at import-time too.
    static func conditionsFingerprint(for edge: GraphEdge) -> String {
        let moguls = edge.attributes.hasMoguls ? "1" : "0"
        let groomed: String
        switch edge.attributes.isGroomed {
        case .some(true):  groomed = "1"
        case .some(false): groomed = "0"
        case .none:        groomed = "?"
        }
        let gladed = edge.attributes.isGladed ? "1" : "0"
        return "m\(moguls)|g\(groomed)|gl\(gladed)"
    }
}
