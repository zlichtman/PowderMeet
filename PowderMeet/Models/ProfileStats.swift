//
//  ProfileStats.swift
//  PowderMeet
//
//  Aggregated lifetime stats for a profile, recomputed server-side from
//  `imported_runs` whenever an activity import completes. Friend cards and
//  the profile page read this row directly — no client-side aggregation.
//

import Foundation

struct ProfileStats: Codable, Equatable {
    let profileId: UUID
    let daysSkied: Int
    let runsCount: Int
    let verticalM: Double
    let topSpeedMs: Double
    let totalDurationS: Double
    let totalDistanceM: Double
    /// Steepest gradient ever skied, in degrees. Matches the units of
    /// `EdgeAttributes.maxGradient` (capped at 60° upstream).
    let topGradeDeg: Double
    /// Mean of per-run average speeds (m/s) — matches the way Slopes
    /// shows lifetime "Avg Speed" on its tile, so our number lines up
    /// with what users see in their other app.
    let avgSpeedMs: Double
    let lastImportAt: Date?

    enum CodingKeys: String, CodingKey {
        case profileId        = "profile_id"
        case daysSkied        = "days_skied"
        case runsCount        = "runs_count"
        case verticalM        = "vertical_m"
        case topSpeedMs       = "top_speed_ms"
        case totalDurationS   = "total_duration_s"
        case totalDistanceM   = "total_distance_m"
        case topGradeDeg      = "top_grade_deg"
        case avgSpeedMs       = "avg_speed_ms"
        case lastImportAt     = "last_import_at"
    }

    static func empty(for id: UUID) -> ProfileStats {
        ProfileStats(
            profileId: id,
            daysSkied: 0,
            runsCount: 0,
            verticalM: 0,
            topSpeedMs: 0,
            totalDurationS: 0,
            totalDistanceM: 0,
            topGradeDeg: 0,
            avgSpeedMs: 0,
            lastImportAt: nil
        )
    }
}
