//
//  MountainGraph+ResortStats.swift
//  PowderMeet
//
//  Snapshot-frozen resort headline stats. Computed once when the graph is
//  first delivered after `GraphEnricher.enrich` and frozen for that load
//  unless `MountainGraph.fingerprint` changes (new snapshot build). The
//  background `ResortDataEnricher` mutates `currentGraph` for routing
//  weights and labels, but it MUST NOT rewrite headline integers — see
//  the audit (§7.1) for the bug class this prevents.
//

import Foundation

/// Snapshot-stable resort stats. Built from the post-curated-overlay graph,
/// keyed by `(resortId, snapshotDate, snapshotGraphFingerprint)` so callers
/// can verify a stats record matches the graph they currently hold.
struct ResortGraphStats: Hashable {
    // Identity
    let resortId: String
    let snapshotDate: String
    let snapshotGraphFingerprint: String

    // Headline — uses trail-group consolidation (trailGroupId ?? edge.id),
    // matching `GeoJSONBuilder.trailFeatures` so the number lines up with
    // what the map renders. Stable across async name-enrichment.
    let runTrailGroupsTotal: Int
    let liftLinesTotal: Int

    // Diagnostics — secondary numbers callers may want for debugging or
    // confidence-tier UI. Not used in the headline.
    let edgesRun: Int
    let edgesLift: Int
    let namedRunsUnique: Int
    let namedLiftsUnique: Int
}

extension MountainGraph {
    /// Pure helper — deterministic given the same graph + identity inputs.
    /// Call right after `GraphEnricher.enrich` (curated overlay applied,
    /// before background `ResortDataEnricher` runs).
    func makeResortStats(resortId: String, snapshotDate: String) -> ResortGraphStats {
        let runs = self.runs
        let lifts = self.lifts
        let runGroups = Set(runs.map { $0.attributes.trailGroupId ?? $0.id })
        let liftGroups = Set(lifts.map { $0.attributes.trailGroupId ?? $0.id })
        let namedRuns = Set(runs.compactMap { $0.attributes.trailName })
        let namedLifts = Set(lifts.compactMap { $0.attributes.trailName })
        return ResortGraphStats(
            resortId: resortId,
            snapshotDate: snapshotDate,
            snapshotGraphFingerprint: self.fingerprint,
            runTrailGroupsTotal: runGroups.count,
            liftLinesTotal: liftGroups.count,
            edgesRun: runs.count,
            edgesLift: lifts.count,
            namedRunsUnique: namedRuns.count,
            namedLiftsUnique: namedLifts.count
        )
    }
}
