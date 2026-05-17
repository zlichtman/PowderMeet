//
//  CuratedResortData.swift
//  PowderMeet
//
//  Loads bundled per-resort JSON files that contain curated trail/lift data.
//  These files augment/correct OSM data with official trail names, accurate
//  difficulty ratings, lift capacity/ride times, and grooming info.
//
//  JSON files live in Resources/ResortData/{resortId}.json.
//

import Foundation

// MARK: - Curated Data Model

nonisolated struct CuratedResort: Codable {
    let resortId: String
    let version: Int
    let trails: [CuratedTrail]?
    let lifts: [CuratedLift]?
    let operatingHours: OperatingHours?
    /// Optional overrides passed to `GraphBuilder.assignTrailGroups`.
    let graphBuildHints: ResortGraphBuildHints?

    /// Official trail names from the resort trail map.
    /// Used to validate OSM trails — any named OSM trail NOT on this list
    /// is marked as a phantom trail and closed for routing.
    let trailWhitelist: [String]?
    /// Official lift names from the resort trail map.
    let liftWhitelist: [String]?
}

nonisolated struct CuratedTrail: Codable {
    let name: String
    let osmWayIds: [String]?       // OSM way IDs to match against
    let difficulty: String?         // green, blue, black, doubleBlack, terrainPark
    let isGroomed: Bool?
    let hasMoguls: Bool?
    let isGladed: Bool?
    let lengthMeters: Double?      // official length if known
    let verticalDrop: Double?      // official vert if known
}

nonisolated struct CuratedLift: Codable {
    let name: String
    let osmWayIds: [String]?
    let liftType: String?
    let capacity: Int?
    let rideTimeSeconds: Double?
    let verticalRise: Double?
    let weekdayWaitMinutes: Double?
    let weekendWaitMinutes: Double?

    /// Returns the appropriate wait time for the current day.
    var currentWaitMinutes: Double? {
        let weekday = Calendar.current.component(.weekday, from: .now)
        let isWeekend = weekday == 1 || weekday == 7
        return isWeekend ? weekendWaitMinutes : weekdayWaitMinutes
    }
}

nonisolated struct OperatingHours: Codable {
    let openHour: Int              // e.g. 8
    let closeHour: Int             // e.g. 16
    let nightSkiingCloseHour: Int? // e.g. 21, nil = no night skiing
}

// MARK: - Loader

// `nonisolated` — called from the importer (background) and from
// graph build paths that run detached. Lock-guarded internally.
nonisolated enum CuratedResortLoader {
    // Insert-only read-mostly cache, populated lazily on first hit per
    // resortId and never mutated after that. Lock-guarded under a private
    // NSLock so concurrent loads from any actor (importer thread,
    // ResortDataManager, GraphEnricher) cannot tear the dict. Decoded
    // values are immutable Codable structs.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CuratedResort] = [:]

    /// Load curated data for a resort. Returns nil if no file bundled.
    nonisolated static func load(resortId: String) -> CuratedResort? {
        cacheLock.lock()
        if let cached = cache[resortId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let url = Bundle.main.url(forResource: resortId, withExtension: "json", subdirectory: "ResortData") else {
            return nil
        }

        let resort: CuratedResort
        do {
            let data = try Data(contentsOf: url)
            resort = try JSONDecoder().decode(CuratedResort.self, from: data)
        } catch {
            AppLog.graph.error("CuratedResortLoader \(resortId).json failed: \(error.localizedDescription)")
            return nil
        }
        cacheLock.lock()
        cache[resortId] = resort
        cacheLock.unlock()
        return resort
    }

    /// Returns all available curated resort IDs (bundled JSON files).
    nonisolated static var availableResortIds: [String] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "ResortData") else { return [] }
        return urls.compactMap { $0.deletingPathExtension().lastPathComponent }
    }
}

// MARK: - Graph Cross-Referencing

extension CuratedResortLoader {

    /// Strip the GraphBuilder prefix ("t", "l") and any split-edge suffixes
    /// ("_s1", "_s2", "_ix1", etc.) to recover the raw OSM way ID.
    nonisolated private static func stripEdgeIdToOSMId(_ edgeId: String) -> String {
        var id = edgeId
        // Remove prefix: "t123456" → "123456", "l789" → "789"
        if let first = id.first, (first == "t" || first == "l"), id.count > 1 {
            id = String(id.dropFirst())
        }
        // Remove split suffixes: "123456_s1" → "123456", "123456_ix2" → "123456"
        if let underscoreRange = id.range(of: "_s", options: .backwards) {
            id = String(id[id.startIndex..<underscoreRange.lowerBound])
        } else if let underscoreRange = id.range(of: "_ix", options: .backwards) {
            id = String(id[id.startIndex..<underscoreRange.lowerBound])
        }
        return id
    }

    /// Apply curated data over an OSM-built graph, correcting trail names,
    /// difficulties, grooming flags, and lift attributes.
    nonisolated static func applyOverlay(_ curated: CuratedResort, to graph: inout MountainGraph) {
        var modified = false

        // Build a lookup: trail name (lowercased) → curated data
        let trailsByName = Dictionary(
            (curated.trails ?? []).map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Build a lookup: OSM way ID → curated trail
        var trailsByOSMId: [String: CuratedTrail] = [:]
        for trail in curated.trails ?? [] {
            for osmId in trail.osmWayIds ?? [] {
                trailsByOSMId[osmId] = trail
            }
        }

        let liftsByName = Dictionary(
            (curated.lifts ?? []).map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var liftsByOSMId: [String: CuratedLift] = [:]
        for lift in curated.lifts ?? [] {
            for osmId in lift.osmWayIds ?? [] {
                liftsByOSMId[osmId] = lift
            }
        }

        for i in graph.edges.indices {
            let edge = graph.edges[i]
            // Strip prefix/suffix to get raw OSM ID for curated data lookup
            let rawOSMId = stripEdgeIdToOSMId(edge.id)

            if edge.kind == .run {
                // Try matching by OSM ID (raw and prefixed), then by name
                let curatedTrail = trailsByOSMId[edge.id]
                    ?? trailsByOSMId[rawOSMId]
                    ?? (edge.attributes.trailName.flatMap { trailsByName[$0.lowercased()] })

                guard let ct = curatedTrail else { continue }

                // Apply curated overrides
                if let diff = ct.difficulty, let rd = RunDifficulty(rawValue: diff) {
                    graph.edges[i] = GraphEdge(
                        id: edge.id,
                        sourceID: edge.sourceID,
                        targetID: edge.targetID,
                        kind: edge.kind,
                        geometry: edge.geometry,
                        attributes: EdgeAttributes(
                            difficulty: rd,
                            lengthMeters: ct.lengthMeters ?? edge.attributes.lengthMeters,
                            verticalDrop: ct.verticalDrop ?? edge.attributes.verticalDrop,
                            averageGradient: edge.attributes.averageGradient,
                            maxGradient: edge.attributes.maxGradient,
                            aspect: edge.attributes.aspect,
                            trailName: ct.name,
                            hasMoguls: ct.hasMoguls ?? edge.attributes.hasMoguls,
                            isGroomed: ct.isGroomed ?? edge.attributes.isGroomed,
                            isGladed: ct.isGladed ?? edge.attributes.isGladed,
                            liftType: edge.attributes.liftType,
                            liftCapacity: edge.attributes.liftCapacity,
                            rideTimeSeconds: edge.attributes.rideTimeSeconds,
                            waitTimeMinutes: edge.attributes.waitTimeMinutes,
                            isOpen: edge.attributes.isOpen
                        )
                    )
                    modified = true
                }

            } else if edge.kind == .lift {
                let curatedLift = liftsByOSMId[edge.id]
                    ?? liftsByOSMId[rawOSMId]
                    ?? (edge.attributes.trailName.flatMap { liftsByName[$0.lowercased()] })

                guard let cl = curatedLift else { continue }

                let lt: LiftType? = cl.liftType.flatMap { LiftType(rawValue: $0) } ?? edge.attributes.liftType

                graph.edges[i] = GraphEdge(
                    id: edge.id,
                    sourceID: edge.sourceID,
                    targetID: edge.targetID,
                    kind: edge.kind,
                    geometry: edge.geometry,
                    attributes: EdgeAttributes(
                        difficulty: edge.attributes.difficulty,
                        lengthMeters: edge.attributes.lengthMeters,
                        verticalDrop: cl.verticalRise ?? edge.attributes.verticalDrop,
                        averageGradient: edge.attributes.averageGradient,
                        maxGradient: edge.attributes.maxGradient,
                        aspect: edge.attributes.aspect,
                        trailName: cl.name,
                        hasMoguls: false,
                        isGroomed: false,
                        isGladed: false,
                        liftType: lt,
                        liftCapacity: cl.capacity ?? edge.attributes.liftCapacity,
                        rideTimeSeconds: cl.rideTimeSeconds ?? edge.attributes.rideTimeSeconds,
                        waitTimeMinutes: cl.currentWaitMinutes ?? edge.attributes.waitTimeMinutes,
                        isOpen: edge.attributes.isOpen
                    )
                )
                modified = true
            }
        }

        // ── Whitelist validation ──
        // Mark edges whose names appear in the official whitelist as validated.
        if let trailWhitelist = curated.trailWhitelist, !trailWhitelist.isEmpty {
            let normalizedWhitelist = Set(trailWhitelist.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })

            for i in graph.edges.indices {
                let edge = graph.edges[i]
                guard edge.kind == .run || edge.kind == .lift else { continue }
                guard let name = edge.attributes.trailName else { continue }

                let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
                if normalizedWhitelist.contains(normalizedName) {
                    var attrs = edge.attributes
                    attrs.isOfficiallyValidated = true
                    graph.edges[i] = GraphEdge(
                        id: edge.id, sourceID: edge.sourceID, targetID: edge.targetID,
                        kind: edge.kind, geometry: edge.geometry, attributes: attrs
                    )
                    modified = true
                }
            }
        }

        if let liftWhitelist = curated.liftWhitelist, !liftWhitelist.isEmpty {
            let normalizedWhitelist = Set(liftWhitelist.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })

            for i in graph.edges.indices {
                let edge = graph.edges[i]
                guard edge.kind == .lift else { continue }
                guard let name = edge.attributes.trailName else { continue }

                let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
                if normalizedWhitelist.contains(normalizedName) {
                    var attrs = edge.attributes
                    attrs.isOfficiallyValidated = true
                    graph.edges[i] = GraphEdge(
                        id: edge.id, sourceID: edge.sourceID, targetID: edge.targetID,
                        kind: edge.kind, geometry: edge.geometry, attributes: attrs
                    )
                    modified = true
                }
            }
        }

        // Caller is responsible for one final `rebuildIndices()` after
        // all overlay+enrichment passes — see `ResortDataManager.loadResort`.
        // Calling it here too produced 200–400 ms of redundant index-rebuild
        // churn on every cold load (curated overlay → enricher → phantom
        // closure each rebuilt independently).

        // Note: `modified` is intentionally unused now; kept above as an
        // assertion-style breadcrumb so changes that introduce a mutation
        // don't have to retrace the conditional.
        _ = modified
    }

    /// Returns true if the curated data includes a trail or lift whitelist.
    static func hasWhitelist(resortId: String) -> Bool {
        guard let curated = load(resortId: resortId) else { return false }
        let hasTrails = !(curated.trailWhitelist ?? []).isEmpty
        let hasLifts = !(curated.liftWhitelist ?? []).isEmpty
        return hasTrails || hasLifts
    }
}
