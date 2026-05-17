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
    /// Recency-weighted population variance of `speed_ms` over this
    /// edge's observations. Same exponential decay weighting as the
    /// mean (60-day half-life). Drives the CVaR-style scoring on
    /// path totals so a candidate with predictable times beats a
    /// candidate whose mean is the same but whose worst case is bad.
    /// 0 when the edge has only a single observation.
    let rollingSpeedVarianceMs2: Double
    let lastObservedAt: Date

    /// Standard deviation of speed in m/s. Convenience over the raw
    /// variance column.
    var rollingSpeedStdMs: Double {
        rollingSpeedVarianceMs2 > 0 ? rollingSpeedVarianceMs2.squareRoot() : 0
    }

    enum CodingKeys: String, CodingKey {
        case resortId               = "resort_id"
        case edgeId                 = "edge_id"
        case conditionsFp           = "conditions_fp"
        case observationCount       = "observation_count"
        case rollingSpeedMs         = "rolling_speed_ms"
        case rollingPeakMs          = "rolling_peak_ms"
        case rollingDurationS       = "rolling_duration_s"
        case rollingSpeedVarianceMs2 = "rolling_speed_variance_ms2"
        case lastObservedAt         = "last_observed_at"
    }

    /// Decoder default for `rollingSpeedVarianceMs2` so legacy rows
    /// (or test fixtures without the column) still decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resortId               = try c.decode(String.self, forKey: .resortId)
        self.edgeId                 = try c.decode(String.self, forKey: .edgeId)
        self.conditionsFp           = try c.decode(String.self, forKey: .conditionsFp)
        self.observationCount       = try c.decode(Int.self,    forKey: .observationCount)
        self.rollingSpeedMs         = try c.decode(Double.self, forKey: .rollingSpeedMs)
        self.rollingPeakMs          = try c.decodeIfPresent(Double.self, forKey: .rollingPeakMs)
        self.rollingDurationS       = try c.decode(Double.self, forKey: .rollingDurationS)
        self.rollingSpeedVarianceMs2 = try c.decodeIfPresent(Double.self, forKey: .rollingSpeedVarianceMs2) ?? 0
        self.lastObservedAt         = try c.decode(Date.self,   forKey: .lastObservedAt)
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
