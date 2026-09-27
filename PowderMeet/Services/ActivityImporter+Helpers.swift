//
//  ActivityImporter+Helpers.swift
//  PowderMeet
//
//  Extension of ActivityImporter — slug/speed helpers.
//  Split out of ActivityImporter.swift. `nonisolated extension` preserves the
//  struct's off-main default; methods needing the main actor keep @MainActor.
//

import Foundation
import CryptoKit
import Supabase

nonisolated extension ActivityImporter {
    // MARK: - Helpers

    /// Deterministic slug of a resort name for the "no catalog match"
    /// case. Lowercase, alphanumeric, dash-separated. Empty / nil →
    /// "unknown-resort". Same name on two devices → same slug, so runs
    /// from "Big Sky Resort" group correctly even before we add it to
    /// the catalog.
    func slugify(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "unknown-resort" }
        let lowered = name.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "unknown-resort" : collapsed
    }

    /// Haversine moving-average speed over a point list, with sustained-
    /// pause segments excluded (audit Phase 4.1 — moving-time filter).
    /// Only used when the source format didn't provide native avgSpeed
    /// (raw GPX). Mirrors `TrailMatcher.movingSpeed` so imports and live
    /// recordings agree on what "moving" means: skip any window where
    /// the user was below 1 m/s for at least 10 continuous seconds (lift
    /// wait, lunch break, gear adjust). Without this, lift-and-lunch
    /// time silently dragged the average ski speed down by 30-50% for
    /// users importing whole-day GPX traces from non-Slopes apps.
    /// Haversine moving-average speed with sustained pauses excluded. Only
    /// used when the source format didn't provide native avgSpeed (raw GPX).
    /// Delegates to the shared `GPXSpeedStats` so the import path and the live
    /// recorder agree on what "moving" means.
    func computedAvgSpeed(points: [GPXTrackPoint]) -> Double {
        GPXSpeedStats.movingAverageSpeed(points)
    }

    /// 3-sample-smoothed peak speed, capped at the recreational ski ceiling.
    /// Delegates to the shared `GPXSpeedStats`.
    func computedPeakSpeed(points: [GPXTrackPoint]) -> Double {
        GPXSpeedStats.peakSpeed(points)
    }

}
