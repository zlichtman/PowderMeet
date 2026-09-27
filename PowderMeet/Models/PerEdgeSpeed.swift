//
//  PerEdgeSpeed.swift
//  PowderMeet
//
//  One row of `profile_edge_speeds` — per-(resort, edge, conditions,
//  equipment) measured pace. This is an empirical edge speed, not a broad
//  skier baseline: terrain and any attributed conditions present at recording
//  time are already reflected in it. Rows retain the equipment used for the
//  observation so switching skis cannot silently reuse another ski's pace.
//  Loaded into a compound-keyed dictionary and consulted by
//  `UserProfile.traverseTime` before the bucketed-difficulty fallback.
//

import Foundation

nonisolated struct PerEdgeSpeed: Codable, Sendable {
    let resortId: String
    let edgeId: String
    let conditionsFp: String
    let datasetVersion: String?
    /// Lowercase UUID of the ski used for this cohort, or `neutral` when the
    /// source did not provide trustworthy equipment provenance.
    let equipmentKey: String
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

    /// Admission boundary shared by mean ETA and uncertainty selection. These
    /// are measured downhill values, so retain the import metric limits even
    /// for decoded/cache rows. An absent optional peak is valid legacy data;
    /// an explicitly non-finite or impossible value is not.
    var hasPlausibleRoutingMetrics: Bool {
        let ceiling = GPXSpeedStats.peakSpeedCeiling
        guard !resortId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !edgeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !conditionsFp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              datasetVersion.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
              rollingSpeedMs.isFinite, rollingSpeedMs > 0, rollingSpeedMs <= ceiling,
              rollingDurationS.isFinite, rollingDurationS > 0,
              rollingDurationS <= GPXSpeedStats.maximumLearningDuration,
              rollingSpeedVarianceMs2.isFinite, rollingSpeedVarianceMs2 >= 0,
              // Loose second-moment bound for speeds confined to 0...ceiling;
              // also prevents overflow poisoning route reliability scores.
              rollingSpeedVarianceMs2 <= ceiling * ceiling,
              lastObservedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        if let peak = rollingPeakMs {
            return peak.isFinite && peak > 0 && peak <= ceiling
        }
        return true
    }

    /// Standard deviation of speed in m/s. Convenience over the raw
    /// variance column.
    var rollingSpeedStdMs: Double {
        rollingSpeedVarianceMs2 > 0 ? rollingSpeedVarianceMs2.squareRoot() : 0
    }

    init(
        resortId: String,
        edgeId: String,
        conditionsFp: String,
        datasetVersion: String? = nil,
        equipmentKey: String = PerEdgeSpeed.neutralEquipmentKey,
        observationCount: Int,
        rollingSpeedMs: Double,
        rollingPeakMs: Double? = nil,
        rollingDurationS: Double,
        rollingSpeedVarianceMs2: Double = 0,
        lastObservedAt: Date
    ) {
        self.resortId = resortId
        self.edgeId = edgeId
        self.conditionsFp = conditionsFp
        self.datasetVersion = datasetVersion
        self.equipmentKey = Self.normalizedEquipmentKey(equipmentKey)
        self.observationCount = observationCount
        self.rollingSpeedMs = rollingSpeedMs
        self.rollingPeakMs = rollingPeakMs
        self.rollingDurationS = rollingDurationS
        self.rollingSpeedVarianceMs2 = rollingSpeedVarianceMs2
        self.lastObservedAt = lastObservedAt
    }

    enum CodingKeys: String, CodingKey {
        case resortId               = "resort_id"
        case edgeId                 = "edge_id"
        case conditionsFp           = "conditions_fp"
        case datasetVersion         = "dataset_version"
        case equipmentKey           = "equipment_key"
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
        self.datasetVersion         = try c.decodeIfPresent(String.self, forKey: .datasetVersion)
        self.equipmentKey           = Self.normalizedEquipmentKey(
            try c.decodeIfPresent(String.self, forKey: .equipmentKey)
                ?? Self.neutralEquipmentKey
        )
        self.observationCount       = try c.decode(Int.self,    forKey: .observationCount)
        self.rollingSpeedMs         = try c.decode(Double.self, forKey: .rollingSpeedMs)
        self.rollingPeakMs          = try c.decodeIfPresent(Double.self, forKey: .rollingPeakMs)
        self.rollingDurationS       = try c.decode(Double.self, forKey: .rollingDurationS)
        self.rollingSpeedVarianceMs2 = try c.decodeIfPresent(Double.self, forKey: .rollingSpeedVarianceMs2) ?? 0
        self.lastObservedAt         = try c.decode(Date.self,   forKey: .lastObservedAt)
    }

    static let neutralEquipmentKey = "neutral"

    static func normalizedEquipmentKey(for skiID: UUID?) -> String {
        skiID?.uuidString.lowercased() ?? neutralEquipmentKey
    }

    static func normalizedEquipmentKey(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? neutralEquipmentKey : normalized
    }

    /// Compound dictionary key. Dataset identity is included defensively even
    /// though today's recompute keeps only the latest dataset per resort.
    var historyKey: String {
        "dataset=\(datasetVersion ?? "-")|equipment=\(equipmentKey)|conditions=\(conditionsFp)"
    }

    /// Stable, content-complete cache fingerprint. Counts alone are not enough:
    /// recency reweighting can change a rolling speed while row and observation
    /// counts remain identical, and equipment cohorts can swap with the same
    /// cardinality. Dictionary storage keys are included so malformed grouping
    /// cannot alias a valid cache entry.
    static func historyFingerprint(
        _ history: [String: [String: PerEdgeSpeed]]
    ) -> String {
        guard !history.isEmpty else { return "∅" }
        let rows = history.flatMap { outerEdgeID, perEdge in
            perEdge.map { storageKey, row in
                [
                    outerEdgeID,
                    storageKey,
                    row.resortId,
                    row.edgeId,
                    row.conditionsFp,
                    row.datasetVersion ?? "-",
                    row.equipmentKey,
                    String(row.observationCount),
                    String(row.rollingSpeedMs.bitPattern, radix: 16),
                    row.rollingPeakMs.map {
                        String($0.bitPattern, radix: 16)
                    } ?? "-",
                    String(row.rollingDurationS.bitPattern, radix: 16),
                    String(row.rollingSpeedVarianceMs2.bitPattern, radix: 16),
                    String(row.lastObservedAt.timeIntervalSinceReferenceDate.bitPattern,
                           radix: 16)
                ].joined(separator: "\u{1f}")
            }
        }.sorted()

        let totalObservations = history.values.reduce(0) { total, perEdge in
            total + perEdge.values.reduce(0) { $0 + $1.observationCount }
        }
        let digest = Data(rows.joined(separator: "\u{1e}").utf8).sha256Hex
        return "n=\(history.count) buckets=\(rows.count) obs=\(totalObservations) "
            + "sha256=\(digest)"
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
