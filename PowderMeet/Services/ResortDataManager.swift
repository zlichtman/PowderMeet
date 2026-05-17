//
//  ResortDataManager.swift
//  PowderMeet
//
//  Observable data manager that loads resort data.
//  Uses shared server-side snapshots (Supabase Edge Function + Storage)
//  to ensure all devices build identical graphs from the same OSM + elevation data.
//  Falls back to direct Overpass fetch if Supabase is unreachable.
//

import Foundation
import Observation
import Supabase

enum ResortLoadError: LocalizedError {
    case snapshotUnavailable

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            return "Could not load resort data. Check your internet connection and try again."
        }
    }
}

@Observable
class ResortDataManager {
    var currentEntry: ResortEntry?
    var currentResort: ResortData?
    var currentGraph: MountainGraph?
    /// The snapshot date of the currently loaded graph (for meet request sync)
    var currentSnapshotDate: String?
    /// Canonical manifest version of the currently loaded graph, set only
    /// when the canonical pipeline produced the graph (else nil). Stamped
    /// on outgoing meet requests so the receiver can force-fetch the
    /// matching version before solving.
    var currentManifestVersion: Int?
    /// Snapshot-frozen resort stats. Computed once after `GraphEnricher.enrich`
    /// and never mutated by background `ResortDataEnricher`. Headline
    /// run/lift integers in the UI MUST go through this — reading
    /// `currentGraph` directly produces volatile numbers that change when
    /// async enrichment finishes (see audit §7.1).
    var currentSnapshotStats: ResortGraphStats?
    var isLoading = false
    var errorMessage: String?

    /// Dismiss the current error banner. Separate from `loadResort` so the
    /// user can acknowledge a failure without being forced into an
    /// automatic retry — `MapView`'s error overlay wires this to the "×"
    /// button; the "RETRY" button calls `loadResort` which will clear the
    /// error on success.
    func clearError() {
        errorMessage = nil
    }

    var error: String? { errorMessage }

    // MARK: - Graph Stats (snapshot-frozen — see currentSnapshotStats)

    /// Headline run count for the loaded resort. Reads frozen snapshot
    /// stats — does NOT recompute from `currentGraph` (which mutates when
    /// background enrichment lands and would otherwise produce a number
    /// that visibly changes on the same resort within seconds).
    var runCount: Int { currentSnapshotStats?.runTrailGroupsTotal ?? 0 }

    /// Headline lift count for the loaded resort. Same snapshot-freeze
    /// contract as `runCount`.
    var liftCount: Int { currentSnapshotStats?.liftLinesTotal ?? 0 }

    private var memoryCache: [String: ResortData] = [:]
    private var graphMemoryCache: [String: MountainGraph] = [:]
    private var statsMemoryCache: [String: ResortGraphStats] = [:]
    /// Per-resort manifest version cached alongside `graphMemoryCache`.
    /// Restored on memory-cache hit so `currentManifestVersion` stays
    /// in sync with `currentGraph`. Nil for non-canonical resorts.
    private var manifestVersionMemoryCache: [String: Int] = [:]
    private let overpassService = OverpassService()
    private let cacheVersion = "v6"
    private var loadingResortId: String?
    /// Set inside `loadOrBuildGraph` when the canonical pipeline produced
    /// the graph successfully (vs. the legacy snapshot/Overpass fallback).
    /// `loadResort` reads this to skip the local `GraphEnricher.enrich`
    /// pass — the canonical graph already had its overlay applied
    /// server-side, and re-applying the IPA-bundled overlay on top would
    /// re-introduce the version-drift problem the canonical pipeline
    /// exists to eliminate.
    private var lastLoadFromCanonical = false
    /// Manifest version of the most recent canonical graph load, threaded
    /// onto `currentManifestVersion` after the load completes successfully.
    private var lastLoadCanonicalManifestVersion: Int?

    // MARK: - Public Load

    /// Loads (or rebuilds) the graph for `entry`. When `snapshotOverride`
    /// is set, the fast in-memory + disk caches are bypassed and the
    /// snapshot pipeline is asked for that exact date instead of the
    /// resolved default — used by the meet-request "SYNC TO THEIRS" flow
    /// so the receiver can adopt the sender's snapshot before accepting,
    /// guaranteeing both devices solve against the same topology.
    ///
    /// `manifestVersionOverride` is the canonical-pipeline analog: when
    /// non-nil and different from the loaded `currentManifestVersion`,
    /// force-fetches that exact manifest via
    /// `CanonicalGraphFetcher.fetch(resortId:manifestVersion:)`. Called
    /// from the receiver path of an inbound meet request whose sender
    /// stamped a different version.
    func loadResort(
        _ entry: ResortEntry,
        snapshotOverride: String? = nil,
        manifestVersionOverride: Int? = nil
    ) async {
        // ── Canonical force-fetch path: receiver adopting sender's manifest ──
        if let target = manifestVersionOverride,
           target != currentManifestVersion {
            do {
                let result = try await CanonicalGraphFetcher.shared.fetch(
                    resortId: entry.id,
                    manifestVersion: target
                )
                await MainActor.run {
                    currentEntry = entry
                    currentGraph = result.graph
                    currentSnapshotDate = result.snapshotDate
                    currentManifestVersion = result.manifestVersion
                    currentSnapshotStats = result.graph.makeResortStats(
                        resortId: entry.id,
                        snapshotDate: result.snapshotDate ?? ""
                    )
                    errorMessage = nil
                }
                return
            } catch {
                AppLog.graph.error("manifestVersionOverride fetch failed for \(entry.id) v\(target): \(error.localizedDescription) — falling through to default load")
            }
        }
        await loadResortDefault(entry, snapshotOverride: snapshotOverride)
    }

    private func loadResortDefault(_ entry: ResortEntry, snapshotOverride: String? = nil) async {
        // Phase timing — single-line elapsed-ms log per phase. Lets us see
        // at a glance which step dominates cold load. Plain print so it
        // shows up in Xcode console without instrumentation tooling.
        let loadStart = Date()
        let phase: (String) -> Void = { label in
            let ms = Int(Date().timeIntervalSince(loadStart) * 1000)
            AppLog.graph.debug("LOAD \(entry.id) \(label) +\(ms)ms")
        }

        // When the caller asked for a specific snapshot date, the
        // in-memory and graph caches keyed by entry.id alone aren't
        // safe to return — they may hold a different date's graph.
        // Bypass the fast paths and force the slow pipeline, which
        // already threads `snapshotOverride` into `invokeSnapshotFunction`.
        let bypassCaches = (snapshotOverride != nil) && (snapshotOverride != currentSnapshotDate)

        if !bypassCaches, let cached = memoryCache[entry.id] {
            let cachedManifestVersion = manifestVersionMemoryCache[entry.id]
            await MainActor.run {
                currentEntry = entry
                currentResort = cached
                currentGraph = graphMemoryCache[entry.id]
                currentSnapshotStats = statsMemoryCache[entry.id]
                currentManifestVersion = cachedManifestVersion
                // Clear any stale "MAP LOAD ERROR" from a previous failed
                // load — a cache hit means the UI has a working graph now
                // and the old message shouldn't linger over top of it.
                errorMessage = nil
            }
            phase("memory-hit")
            return
        }

        // Snapshot/disk-cache paths populate `graphMemoryCache` but not
        // `memoryCache` (that's only set on the Overpass fallback). Without
        // this guard, re-entering `loadResort` for an already-loaded resort
        // re-runs the full pipeline including background enrichment, which
        // shows up as duplicate Epic/MtnPowder/Liftie fetches in the log.
        if !bypassCaches, let cachedGraph = graphMemoryCache[entry.id] {
            // Re-query the snapshot date so `MeetRequest.graphSnapshotDate`
            // lines up with the graph we're actually handing out.
            let snapshotDate = await GraphCacheManager.shared.snapshotDate(for: entry.id)
            // Restore frozen stats if we built them previously this session;
            // otherwise compute them off the cached graph. Either way the
            // headline integers do NOT come from `currentGraph` directly.
            let stats = statsMemoryCache[entry.id]
                ?? cachedGraph.makeResortStats(resortId: entry.id, snapshotDate: snapshotDate ?? "")
            statsMemoryCache[entry.id] = stats
            let cachedManifestVersion = manifestVersionMemoryCache[entry.id]
            await MainActor.run {
                currentEntry = entry
                // Fallback to any previously-loaded ResortData for this entry
                // so UI bits that read `currentResort` don't see a stale pointer
                // from the last resort.
                currentResort = memoryCache[entry.id]
                currentGraph = cachedGraph
                currentSnapshotDate = snapshotDate
                currentSnapshotStats = stats
                currentManifestVersion = cachedManifestVersion
                errorMessage = nil
            }
            phase("graph-memory-hit")
            Task { await SupabaseManager.shared.remapUnnamedRuns(resortId: entry.id, graph: cachedGraph) }
            return
        }

        // Prevent duplicate concurrent loads for the same resort
        guard loadingResortId != entry.id else { return }
        loadingResortId = entry.id

        await MainActor.run {
            isLoading = true
            errorMessage = nil
            currentEntry = entry
            // CRITICAL: clear the previous resort's graph data immediately.
            // Without this, a failed cold load on resort B leaves resort A's
            // graph rendered underneath the error overlay — user sees
            // Whistler's trails when they tapped Palisades and it failed
            // to build. Better to render nothing than the wrong mountain.
            currentGraph = nil
            currentResort = nil
            currentSnapshotDate = nil
            currentManifestVersion = nil
            currentSnapshotStats = nil
        }

        do {
            phase("graph-load:start")
            let (graph, snapshotDate) = try await loadOrBuildGraph(
                entry: entry,
                snapshotOverride: snapshotOverride
            )
            phase("graph-load:done")

            // Apply curated data overlay (corrects names, difficulties, lift
            // times) via GraphEnricher — same helper the importer + live
            // recorder use, so all three paths produce graphs that label
            // identically through MountainNaming. Detached inside the
            // helper, so the overlay walk + index rebuild stay off the
            // main thread (both can run 100-300ms on larger resorts).
            //
            // SKIP when the graph came from the canonical pipeline —
            // that graph already has the overlay applied server-side
            // (against the canonical_trail / canonical_lift Postgres
            // tables, not the IPA-bundled JSON). Re-applying locally
            // would re-introduce app-version drift.
            let resortId = entry.id
            let enrichedGraph: MountainGraph
            if lastLoadFromCanonical {
                enrichedGraph = graph
                phase("curated-overlay:skipped-canonical")
            } else {
                enrichedGraph = await GraphEnricher.enrich(graph, resortId: resortId)
                phase("curated-overlay:done")
            }

            // ── Deliver graph IMMEDIATELY so Location tester + routing work ──
            graphMemoryCache[entry.id] = enrichedGraph
            if let mv = lastLoadCanonicalManifestVersion {
                manifestVersionMemoryCache[entry.id] = mv
            } else {
                manifestVersionMemoryCache.removeValue(forKey: entry.id)
            }

            // Freeze headline stats off the post-curated-overlay graph.
            // Background `ResortDataEnricher` (Epic / MtnPowder / Liftie)
            // can mutate `currentGraph` for routing weights and labels,
            // but it must NOT rewrite this snapshot — see audit §7.1.
            let snapshotStats = enrichedGraph.makeResortStats(resortId: entry.id, snapshotDate: snapshotDate)
            statsMemoryCache[entry.id] = snapshotStats
            phase("delivered-to-ui")

            // Re-resolve trail names for any imported_runs at this resort
            // that were left unnamed (imported before the graph existed,
            // or strict matcher dropped them). Background-fire so it
            // doesn't delay first paint.
            Task { await SupabaseManager.shared.remapUnnamedRuns(resortId: entry.id, graph: enrichedGraph) }

            if loadingResortId == entry.id { loadingResortId = nil }
            let canonicalManifestVersion = lastLoadCanonicalManifestVersion
            await MainActor.run {
                if currentEntry?.id == entry.id {
                    currentResort = memoryCache[entry.id]
                    currentGraph = enrichedGraph
                    currentSnapshotDate = snapshotDate
                    currentSnapshotStats = snapshotStats
                    currentManifestVersion = canonicalManifestVersion
                }
                // Always clear `isLoading` on the way out, even when the user
                // swapped to a different resort mid-load. The previous code
                // swapped to a different resort mid-load. The previous code
                // returned early without doing so, which left `isLoading`
                // stuck at `true` forever if the swap target hit the cache
                // fast-path (which never touches `isLoading`). That manifested
                // as the resort-bar spinner never going away until another
                // cold load happened to finish.
                isLoading = false
            }

            // ── Background enrichment — non-blocking ──
            // SKIP for canonical-pipeline resorts: live status (open/closed,
            // wait minutes) comes from the server-side `refresh-live-status`
            // sidecar blob attached to the canonical graph fetch, not from
            // on-device Epic / MtnPowder / Liftie scrapes. Running the
            // legacy enrichment on top of a canonical graph would mutate
            // `isOfficiallyValidated` and `isOpen` based on the IPA
            // whitelist + scraper output, defeating the determinism
            // contract.
            if lastLoadFromCanonical {
                AppLog.graph.debug("Skipping background enrichment for \(resortId) — canonical pipeline")
            } else {
            let graphForEnrichment = enrichedGraph
            Task { [weak self] in
                async let epicData = EpicTerrainScraper.shared.fetchTerrainData(resortId: resortId)
                async let mtnPowderData = MtnPowderService.shared.fetchData(resortId: resortId)
                async let liftieData = LiftieService.shared.fetchLiftStatus(resortId: resortId)

                let (epic, powder, liftie) = await (epicData, mtnPowderData, liftieData)

                let epicCount = epic?.allTrails.count ?? 0
                let powderTrails = powder?.trails.count ?? 0
                let powderLifts = powder?.lifts.count ?? 0
                let liftieCount = liftie?.lifts.status.count ?? 0
                AppLog.graph.debug("Enrichment sources for \(resortId): Epic(\(epicCount) trails), MtnPowder(\(powderTrails) trails, \(powderLifts) lifts), Liftie(\(liftieCount) lifts)")

                var enrichedGraph = graphForEnrichment
                ResortDataEnricher.enrich(graph: &enrichedGraph, epicData: epic, mtnPowderData: powder, liftieData: liftie)

                // Build official-name whitelist from all available sources and close
                // phantom trails that don't match. This only affects run/lift STATUS
                // (isOpen), never topology — both devices still have identical edges.
                var officialNames: Set<String> = []
                if let epic { officialNames.formUnion(ResortDataEnricher.whitelist(fromEpic: epic)) }
                if let powder { officialNames.formUnion(ResortDataEnricher.whitelist(fromMtnPowder: powder)) }
                let hasOfficialData = !officialNames.isEmpty
                if hasOfficialData {
                    ResortDataEnricher.closePhantomTrails(
                        graph: &enrichedGraph,
                        hasOfficialData: true,
                        officialNames: officialNames
                    )
                }

                enrichedGraph.rebuildIndices()

                let namedRuns = Set(enrichedGraph.runs.compactMap { $0.attributes.trailName }).count
                let namedLifts = Set(enrichedGraph.lifts.compactMap { $0.attributes.trailName }).count
                let validatedCount = enrichedGraph.edges.filter { $0.attributes.isOfficiallyValidated }.count
                let openCount = enrichedGraph.edges.filter { $0.attributes.isOpen }.count
                AppLog.graph.debug("Post-enrichment: \(namedRuns) named runs, \(namedLifts) named lifts, \(validatedCount) validated, \(openCount) open")

                GraphDiagnostics.printReport(enrichedGraph)

                self?.graphMemoryCache[resortId] = enrichedGraph
                await MainActor.run {
                    guard let self, self.currentEntry?.id == resortId else { return }
                    self.currentGraph = enrichedGraph
                    AppLog.graph.debug("Graph enriched with live data for \(resortId)")
                }
            }
            }   // end of else (legacy enrichment branch)
        } catch {
            if loadingResortId == entry.id { loadingResortId = nil }
            await MainActor.run {
                if currentEntry?.id == entry.id {
                    errorMessage = "Failed to load \(entry.name): \(error.localizedDescription)"
                    // Make sure we don't leave a partially-loaded graph
                    // dangling — caller pre-cleared at load start, but
                    // belt-and-suspenders here in case future edits add
                    // a code path that mutates currentGraph mid-load.
                    currentGraph = nil
                    currentResort = nil
                    currentSnapshotDate = nil
                    currentManifestVersion = nil
                    currentSnapshotStats = nil
                } else {
                    // User switched resorts mid-load; their new load owns the UI now.
                    AppLog.graph.debug("Suppressed stale error for \(entry.id) — user switched to \(currentEntry?.id ?? "none")")
                }
                // Always clear isLoading — see the success branch above for rationale.
                isLoading = false
            }
        }
    }

    // MARK: - Graph Loading Pipeline

    /// Tries: canonical pipeline (when opted in) → disk cache → server
    /// snapshot → direct Overpass fetch. Disk-cache load and snapshot
    /// fetch run concurrently so a cold start never waits on the cache
    /// check before a network request is in flight.
    private func loadOrBuildGraph(
        entry: ResortEntry,
        snapshotOverride: String? = nil
    ) async throws -> (MountainGraph, String) {
        let phaseStart = Date()
        let phase: (String) -> Void = { label in
            let ms = Int(Date().timeIntervalSince(phaseStart) * 1000)
            AppLog.graph.debug("LOAD \(entry.id) graph:\(label) +\(ms)ms")
        }

        // ── Canonical pipeline branch ──
        // When this resort is opted into the server-authoritative path,
        // the graph is fetched as a pre-built blob (no on-device
        // GraphBuilder run, no curated overlay locally — both already
        // happened server-side in build-resort-graph). Skip the legacy
        // snapshot/Overpass plumbing entirely.
        //
        // If the canonical fetch fails (e.g. manifest not yet applied
        // for this resort, or transient network), fall through to the
        // legacy pipeline so we don't hard-fail the resort load during
        // rollout.
        lastLoadFromCanonical = false
        lastLoadCanonicalManifestVersion = nil
        if CanonicalGraphFetcher.shared.isEnabled(for: entry.id) {
            phase("canonical:start")
            do {
                let result = try await CanonicalGraphFetcher.shared.fetch(resortId: entry.id)
                phase("canonical:fetched")
                let snapshotDate = result.snapshotDate ?? ISO8601DateFormatter().string(from: Date())
                lastLoadFromCanonical = true
                lastLoadCanonicalManifestVersion = result.manifestVersion
                return (result.graph, snapshotDate)
            } catch {
                AppLog.graph.error("Canonical fetch for \(entry.id) failed: \(error.localizedDescription) — falling back to legacy pipeline")
            }
        }

        // Start disk-cache load and snapshot fetch concurrently. The disk load
        // resolves in milliseconds and short-circuits the network request; if
        // it's stale or missing we're already waiting for the snapshot.
        let cacheTask = Task { await GraphCacheManager.shared.loadCachedGraph(resortID: entry.id) }
        let snapshotTask = Task { await fetchFromSnapshotWithRetry(entry: entry, snapshotOverride: snapshotOverride) }

        // 1. Current-version disk cache is the fast path. Skipped when
        //    `snapshotOverride` differs from the cached date — we
        //    explicitly want the override's blob, not whatever the
        //    cache happens to have.
        let cached = await cacheTask.value
        if let cached,
           cached.snapshotVersion == GraphCacheManager.snapshotVersion,
           snapshotOverride == nil || snapshotOverride == cached.snapshotDate {
            AppLog.graph.debug("Using cached graph for \(entry.id) (snapshot \(cached.snapshotDate))")
            snapshotTask.cancel()
            phase("disk-cache-hit")
            return (cached.graph, cached.snapshotDate)
        }

        // 2. Wait for the in-flight snapshot fetch.
        if let (graph, snapshotDate) = await snapshotTask.value {
            await GraphCacheManager.shared.saveGraph(graph, snapshotDate: snapshotDate)
            phase("snapshot-fetched")
            return (graph, snapshotDate)
        }

        // 3. Use stale cache if available (wrong snapshotVersion is still usable),
        //    but only when no override was requested — silently returning a
        //    different date than the caller asked for would defeat the point.
        if let cached, snapshotOverride == nil {
            AppLog.graph.debug("Using stale cached graph for \(entry.id) (snapshot \(cached.snapshotDate))")
            phase("stale-cache")
            return (cached.graph, cached.snapshotDate)
        }

        // 4. Fall back to direct Overpass fetch.
        AppLog.graph.info("Falling back to direct Overpass fetch for \(entry.id)")
        phase("overpass-fallback:start")
        let resortData = try await overpassService.fetchResortData(entry: entry)
        phase("overpass-fetched")
        memoryCache[entry.id] = resortData
        let dataForBuild = resortData.withGraphBuildHints(CuratedResortLoader.load(resortId: entry.id)?.graphBuildHints)
        let graph = GraphBuilder.buildGraph(from: dataForBuild, resortID: entry.id)
        phase("graph-built")
        let snapshotDate = ISO8601DateFormatter().string(from: Date())
        await GraphCacheManager.shared.saveGraph(graph, snapshotDate: snapshotDate)
        AppLog.graph.debug("Built graph from Overpass: \(graph.nodes.count) nodes, \(graph.edges.count) edges")
        return (graph, snapshotDate)
    }

    /// Runs `fetchFromSnapshot` with one retry on cold-start failure.
    /// Honours cooperative cancellation so the disk-cache fast path can
    /// short-circuit an in-flight snapshot request cleanly.
    private func fetchFromSnapshotWithRetry(
        entry: ResortEntry,
        snapshotOverride: String? = nil
    ) async -> (MountainGraph, String)? {
        for attempt in 1...2 {
            if Task.isCancelled { return nil }
            if let result = await fetchFromSnapshot(entry: entry, snapshotOverride: snapshotOverride) {
                return result
            }
            if Task.isCancelled { return nil }
            if attempt < 2 {
                AppLog.graph.info("Snapshot attempt \(attempt) failed for \(entry.id), retrying...")
                try? await Task.sleep(for: .seconds(2))
            }
        }
        return nil
    }

    // MARK: - Server-Side Snapshot

    /// Calls the snapshot-resort Edge Function, downloads OSM + elevation
    /// data, and builds the graph locally from the shared frozen snapshot.
    ///
    /// The Edge Function uses a chunked-elevation state machine for big
    /// resorts: a single invocation processes ~1200 elevation coords
    /// (12 batches × 100), persists progress in a checkpoint blob, and
    /// returns `status: "elevation_pending"` with a `processed/total`
    /// counter. We loop on that response, calling back until `status:
    /// "ready"`. Worst case: a 5K-coord resort needs ~5 round-trips
    /// (~30s + Open-Meteo backoff time) to cold-build; subsequent
    /// devices get the cached pinned blob in one round-trip.
    private func fetchFromSnapshot(
        entry: ResortEntry,
        snapshotOverride: String? = nil
    ) async -> (MountainGraph, String)? {
        do {
            let snapshotResp = try await driveSnapshotPipeline(entry: entry, snapshotOverride: snapshotOverride)
            AppLog.graph.debug("Snapshot for \(entry.id): date=\(snapshotResp.snapshot_date), cached=\(snapshotResp.cached ?? false)")

            // Download the OSM + elevation blobs.
            async let osmData = downloadData(from: snapshotResp.osm_url ?? "")
            async let elevData = downloadData(from: snapshotResp.elevation_url ?? "")
            let (osm, elev) = try await (osmData, elevData)

            // Build graph from the frozen snapshot.
            let resortData = try await overpassService.buildFromSnapshot(
                osmData: osm,
                elevationData: elev,
                entry: entry
            )
            memoryCache[entry.id] = resortData

            let dataForBuild = resortData.withGraphBuildHints(CuratedResortLoader.load(resortId: entry.id)?.graphBuildHints)
            let graph = GraphBuilder.buildGraph(from: dataForBuild, resortID: entry.id)
            AppLog.graph.debug("Built graph from snapshot: \(graph.nodes.count) nodes, \(graph.edges.count) edges")

            return (graph, snapshotResp.snapshot_date)
        } catch {
            if (error as? CancellationError) != nil || (error as? URLError)?.code == .cancelled {
                return nil
            }
            AppLog.graph.error("Snapshot fetch failed for \(entry.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Single-call response shape from the snapshot-resort Edge Function.
    /// `status == "ready"` carries the OSM/elev signed URLs; `status ==
    /// "elevation_pending"` carries an `elevation_progress` object so
    /// the client can advance progress UI between continuation calls.
    private struct SnapshotResponse: Decodable {
        let status: String?
        let snapshot_date: String
        let osm_url: String?
        let elevation_url: String?
        let cached: Bool?
        let elevation_progress: ElevationProgress?

        struct ElevationProgress: Decodable {
            let processed: Int
            let total: Int
        }

        var isReady: Bool { (status ?? "ready") == "ready" }
    }

    /// Drives the chunked snapshot pipeline to completion. Calls the
    /// Edge Function, and if the response is `elevation_pending`, calls
    /// it again (up to a sane cap) until ready. Cooperative cancellation
    /// is honored at every loop turn.
    private func driveSnapshotPipeline(
        entry: ResortEntry,
        snapshotOverride: String? = nil
    ) async throws -> SnapshotResponse {
        let maxIterations = 12 // 12 × 1200 coords = 14.4K coords ceiling — fits the largest catalog resort
        for iteration in 0..<maxIterations {
            try Task.checkCancellation()
            let resp = try await invokeSnapshotFunction(
                entry: entry,
                isContinuation: iteration > 0,
                snapshotOverride: snapshotOverride
            )
            if resp.isReady {
                return resp
            }
            if let prog = resp.elevation_progress {
                let pct = prog.total > 0 ? Int(Double(prog.processed) / Double(prog.total) * 100) : 0
                AppLog.graph.debug("\(entry.id) elevation \(prog.processed)/\(prog.total) (\(pct)%) — continuing…")
            }
            // Tiny pause between continuations so the Edge Function
            // doesn't see a thundering herd if multiple resorts are
            // loading concurrently. 250ms is plenty.
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "Snapshot build did not converge for \(entry.id)"])
    }

    /// One round-trip to the Edge Function. Returns the typed response
    /// or throws on transport / HTTP / decode failure.
    private func invokeSnapshotFunction(
        entry: ResortEntry,
        isContinuation: Bool,
        snapshotOverride: String? = nil
    ) async throws -> SnapshotResponse {
        guard let functionURL = URL(string: "\(SupabaseManager.projectURL)/functions/v1/snapshot-resort") else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Bad SupabaseURL config — cannot build snapshot-resort URL"])
        }

        // Resolve the pin: explicit override (meet-request "SYNC TO
        // THEIRS") wins over the SupabaseManager resolver, which itself
        // walks server-canonical pin → catalog default → baked default.
        // Without the override path every device used the resolved pin,
        // which couldn't help when accepting a request whose graph was
        // built against a different snapshot.
        let pinnedDate: String
        if let override = snapshotOverride {
            pinnedDate = override
        } else {
            pinnedDate = await MainActor.run {
                SupabaseManager.shared.resolvedPinnedSnapshotDate(for: entry)
            }
        }
        var bodyDict: [String: Any] = [
            "resort_id": entry.id,
            "south": entry.bounds.minLat,
            "west": entry.bounds.minLon,
            "north": entry.bounds.maxLat,
            "east": entry.bounds.maxLon,
            "pinned_snapshot_date": pinnedDate
        ]
        if isContinuation { bodyDict["continue"] = true }

        var request = URLRequest(url: functionURL, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseManager.anonKey, forHTTPHeaderField: "apikey")
        let token: String? = await MainActor.run { SupabaseManager.shared.currentSession?.accessToken }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (responseData, httpResp) = try await URLSession.shared.data(for: request)
        guard let http = httpResp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(SnapshotResponse.self, from: responseData)
    }

    private func downloadData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Cache Management

    func clearCache(for id: String) {
        memoryCache.removeValue(forKey: id)
        graphMemoryCache.removeValue(forKey: id)
        manifestVersionMemoryCache.removeValue(forKey: id)
        let url = cacheURL(for: id)
        try? FileManager.default.removeItem(at: url)
        Task { await GraphCacheManager.shared.clearResort(id) }
    }

    // MARK: - Legacy Disk Cleanup

    /// The old-style `ResortData` disk path. Writes are gone (the current
    /// pipeline caches via `GraphCacheManager`), but `clearCache(for:)` still
    /// deletes these files so users upgrading from an older build aren't left
    /// with stale `v6` JSON on disk.
    private func cacheURL(for id: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("resorts").appendingPathComponent("\(id)-\(cacheVersion).json")
    }
}
