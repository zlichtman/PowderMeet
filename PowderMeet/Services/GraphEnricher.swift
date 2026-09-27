//
//  GraphEnricher.swift
//  PowderMeet
//
//  Single source of "apply curated overlay + rebuild indices" so the
//  importer, the live recorder, and the resort loader all enrich a
//  graph the same way before they hand it to MountainNaming or
//  TrailMatcher.
//
//  Without this, a graph that bypasses curated enrichment (e.g.
//  loaded from cache and matched immediately) has no `trailGroupId`
//  populated for many edges. MountainNaming then falls back to the
//  raw `edge.attributes.trailName` (often nil for OSM ways), then
//  through to the kind+elevation label, and the persisted
//  `trail_name` ends up "Imported Run" — the exact regression the
//  recent naming consolidation was meant to kill.
//
//  ────────────────────────────────────────────────────────────────────
//  Enrichment pipeline overview (audit §5)
//  ────────────────────────────────────────────────────────────────────
//
//   1. GraphBuilder.buildGraph       → raw OSM topology + elevation
//   2. CuratedResortLoader.load      → bundled JSON overlay
//                                       (trail names, difficulties,
//                                        curated trailGroupId chains,
//                                        graphBuildHints)
//   3. GraphEnricher.enrich          → applies the curated overlay,
//                                       rebuilds indices, freezes the
//                                       SnapshotGraph the solver and
//                                       MountainNaming consume.
//                                      ── result ──>  SnapshotGraph
//
//   4. ResortDataEnricher.enrich     → pulls live external feeds
//                                       (Epic / MtnPowder / Liftie),
//                                       mutates open/closed + names
//                                       on top of the SnapshotGraph.
//                                      ── result ──>  LiveEnrichedGraph
//
//  Naming convention: think of the graph in two phases.
//   - **SnapshotGraph** — output of step 3. Frozen for headline stats
//     (`ResortGraphStats`), used as the topology contract for meet
//     requests (`graphSnapshotDate`).
//   - **LiveEnrichedGraph** — same topology, with mutable status
//     applied by step 4. Drives map color, lift waits, route
//     suggestions; can change minute-to-minute.
//
//  When adding a new "fold something into the graph" step, decide
//  which phase it belongs in and extend that helper — don't create a
//  third orchestrator. (Pre-Phase-1 we had GraphBuilder + GraphEnricher
//  + ResortDataEnricher + a stray closePhantomTrails that didn't run
//  through any of them; the audit consolidates everything to these
//  three names.)
//

import Foundation

enum GraphEnricher {

    /// Apply the curated overlay (if one exists for this resort) and
    /// rebuild graph indices. Runs on a detached `userInitiated` task
    /// so the work doesn't block whichever actor called us. Idempotent
    /// — calling twice produces the same graph.
    ///
    /// Call this before:
    ///   - `MountainNaming(graph)` for label resolution
    ///   - `TrailMatcher(graph:)` for run matching
    /// in any code path that didn't get its graph from
    /// `ResortDataManager.loadResort` (which already enriches via this
    /// helper). Belt-and-suspenders: cheap to call, safe to repeat.
    static func enrich(_ graph: MountainGraph, resortId: String) async -> MountainGraph {
        await Task.detached(priority: .userInitiated) {
            var g = graph
            if let curated = CuratedResortLoader.load(resortId: resortId) {
                CuratedResortLoader.applyOverlay(curated, to: &g)
                g.rebuildIndices()
            }
            return g
        }.value
    }
}
