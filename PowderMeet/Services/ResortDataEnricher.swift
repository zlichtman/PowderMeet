//
//  ResortDataEnricher.swift
//  PowderMeet
//
//  Cross-references OSM graph data with Epic terrain feeds and Liftie
//  to fill in missing names, correct difficulties, and apply live status.
//
//  Strategy:
//  1. Fuzzy name matching (normalized Levenshtein)
//  2. Elevation/length proximity matching for unnamed features
//  3. Epic data wins for names and difficulties (official source)
//  4. OSM coordinates always used (Epic has no geometry)
//

import Foundation

enum ResortDataEnricher {

    // MARK: - Main Enrichment

    /// Enrich a graph with data from Epic terrain feed, MtnPowder, and Liftie.
    /// Modifies graph edges in-place: fills missing names, corrects difficulties,
    /// applies open/closed and grooming status.
    static func enrich(
        graph: inout MountainGraph,
        epicData: EpicTerrainData?,
        mtnPowderData: MtnPowderData?,
        liftieData: LiftieResponse?
    ) {
        var modified = false

        // ── Enrich trails from Epic ──
        if let epic = epicData {
            modified = enrichTrails(graph: &graph, epicTrails: epic.allTrails) || modified
            modified = enrichLifts(graph: &graph, epicLifts: epic.allLifts) || modified
        }

        // ── Enrich trails from MtnPowder ──
        if let powder = mtnPowderData {
            modified = enrichFromMtnPowder(graph: &graph, data: powder) || modified
        }

        // ── Enrich lift status from Liftie ──
        if let liftie = liftieData {
            modified = enrichFromLiftie(graph: &graph, liftie: liftie) || modified
        }

        // Caller batches one `rebuildIndices()` after `enrich(...)` +
        // `closePhantomTrails(...)` + curated overlay — see
        // `ResortDataManager.loadResort`. Rebuilding here too produced
        // duplicate work on every cold load.
        _ = modified
    }

    // MARK: - Trail Enrichment

    private static func enrichTrails(graph: inout MountainGraph, epicTrails: [EpicTrail]) -> Bool {
        var modified = false

        // Build normalized name lookup from Epic trails
        let epicByNormalized = Dictionary(
            epicTrails.map { (normalizeName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // For unmatched Epic trails, build elevation lookup
        var unmatchedEpicTrails = epicTrails
        var matchedEpicNames = Set<String>()

        // Pass 1: Match by name
        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard edge.kind == .run else { continue }
            guard let trailName = edge.attributes.trailName else { continue }

            let normalized = normalizeName(trailName)
            guard let epic = epicByNormalized[normalized] else { continue }

            matchedEpicNames.insert(normalizeName(epic.name))
            graph.edges[i] = applyEpicTrailData(edge: edge, epic: epic)
            modified = true
        }

        // Remove matched from unmatched list
        unmatchedEpicTrails.removeAll { matchedEpicNames.contains(normalizeName($0.name)) }

        // Pass 2: For unnamed OSM trail edges, try to match by elevation proximity
        guard !unmatchedEpicTrails.isEmpty else { return modified }

        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard edge.kind == .run else { continue }
            guard edge.attributes.trailName == nil else { continue }

            // Find best matching Epic trail by difficulty + vertical proximity
            if let bestMatch = findBestEpicTrailMatch(
                edge: edge,
                candidates: unmatchedEpicTrails,
                graph: graph
            ) {
                unmatchedEpicTrails.removeAll { $0.id == bestMatch.id }
                graph.edges[i] = applyEpicTrailData(edge: edge, epic: bestMatch)
                modified = true
            }
        }

        return modified
    }

    // MARK: - Lift Enrichment

    private static func enrichLifts(graph: inout MountainGraph, epicLifts: [EpicLift]) -> Bool {
        var modified = false

        let epicByNormalized = Dictionary(
            epicLifts.map { (normalizeName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var unmatchedEpicLifts = epicLifts
        var matchedEpicNames = Set<String>()

        // Pass 1: Name matching
        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard edge.kind == .lift else { continue }
            guard let liftName = edge.attributes.trailName else { continue }

            let normalized = normalizeName(liftName)

            // Try exact normalized match first
            if let epic = epicByNormalized[normalized] {
                matchedEpicNames.insert(normalizeName(epic.name))
                graph.edges[i] = applyEpicLiftData(edge: edge, epic: epic)
                modified = true
                continue
            }

            // Try fuzzy match
            let bestFuzzy = epicLifts
                .filter { !matchedEpicNames.contains(normalizeName($0.name)) }
                .min(by: { levenshteinDistance(normalizeName($0.name), normalized)
                    < levenshteinDistance(normalizeName($1.name), normalized) })

            if let best = bestFuzzy {
                let dist = levenshteinDistance(normalizeName(best.name), normalized)
                let maxLen = max(normalized.count, normalizeName(best.name).count)
                let similarity = 1.0 - Double(dist) / Double(max(maxLen, 1))
                if similarity > 0.78 {
                    matchedEpicNames.insert(normalizeName(best.name))
                    graph.edges[i] = applyEpicLiftData(edge: edge, epic: best)
                    modified = true
                }
            }
        }

        unmatchedEpicLifts.removeAll { matchedEpicNames.contains(normalizeName($0.name)) }

        // Pass 2: For unnamed lift edges, match by vertical rise + lift type
        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard edge.kind == .lift else { continue }
            guard edge.attributes.trailName == nil else { continue }

            if let bestMatch = findBestEpicLiftMatch(
                edge: edge,
                candidates: unmatchedEpicLifts,
                graph: graph
            ) {
                unmatchedEpicLifts.removeAll { $0.name == bestMatch.name }
                graph.edges[i] = applyEpicLiftData(edge: edge, epic: bestMatch)
                modified = true
            }
        }

        return modified
    }

    // MARK: - Liftie Enrichment

    private static func enrichFromLiftie(graph: inout MountainGraph, liftie: LiftieResponse) -> Bool {
        var modified = false

        let liftieByNormalized = Dictionary(
            liftie.lifts.status.map { (normalizeName($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard edge.kind == .lift else { continue }
            guard let liftName = edge.attributes.trailName else { continue }

            let normalized = normalizeName(liftName)

            // Try exact match
            if let status = liftieByNormalized[normalized] {
                let isOpen = status == "open"
                if edge.attributes.isOpen != isOpen || !edge.attributes.isOfficiallyValidated {
                    // Liftie only provides open/closed status — preserve everything else
                    graph.edges[i] = edge.withAttributes(edge.attributes.enriched(
                        isOpen: isOpen,
                        isOfficiallyValidated: true
                    ))
                    modified = true
                }
                continue
            }

            // Try fuzzy match against Liftie names
            let bestFuzzy = liftie.lifts.status.keys.min(by: {
                levenshteinDistance(normalizeName($0), normalized)
                < levenshteinDistance(normalizeName($1), normalized)
            })

            if let bestKey = bestFuzzy {
                let dist = levenshteinDistance(normalizeName(bestKey), normalized)
                let maxLen = max(normalized.count, normalizeName(bestKey).count)
                let similarity = 1.0 - Double(dist) / Double(max(maxLen, 1))
                if similarity > 0.78, let status = liftie.lifts.status[bestKey] {
                    let isOpen = status == "open"
                    if edge.attributes.isOpen != isOpen || !edge.attributes.isOfficiallyValidated {
                        graph.edges[i] = edge.withAttributes(edge.attributes.enriched(
                            isOpen: isOpen,
                            isOfficiallyValidated: true
                        ))
                        modified = true
                    }
                }
            }
        }

        return modified
    }

    // MARK: - MtnPowder Enrichment

    private static func enrichFromMtnPowder(graph: inout MountainGraph, data: MtnPowderData) -> Bool {
        var modified = false

        // Build normalized name lookups
        let trailsByName = Dictionary(
            data.trails.map { (normalizeName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let liftsByName = Dictionary(
            data.lifts.map { (normalizeName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard let edgeName = edge.attributes.trailName else { continue }
            guard !edge.attributes.isOfficiallyValidated else { continue }

            let normalized = normalizeName(edgeName)

            if edge.kind == .run, let trail = trailsByName[normalized] {
                graph.edges[i] = applyMtnPowderTrail(edge: edge, trail: trail)
                modified = true
            } else if edge.kind == .lift, let lift = liftsByName[normalized] {
                graph.edges[i] = applyMtnPowderLift(edge: edge, lift: lift)
                modified = true
            } else if edge.kind == .run {
                // Fuzzy match for trails
                let bestMatch = data.trails
                    .filter { !$0.name.isEmpty }
                    .min(by: { levenshteinDistance(normalizeName($0.name), normalized)
                        < levenshteinDistance(normalizeName($1.name), normalized) })
                if let best = bestMatch {
                    let dist = levenshteinDistance(normalizeName(best.name), normalized)
                    let maxLen = max(normalized.count, normalizeName(best.name).count)
                    let similarity = 1.0 - Double(dist) / Double(max(maxLen, 1))
                    if similarity > 0.7 {
                        graph.edges[i] = applyMtnPowderTrail(edge: edge, trail: best)
                        modified = true
                    }
                }
            } else if edge.kind == .lift {
                // Fuzzy match for lifts
                let bestMatch = data.lifts
                    .filter { !$0.name.isEmpty }
                    .min(by: { levenshteinDistance(normalizeName($0.name), normalized)
                        < levenshteinDistance(normalizeName($1.name), normalized) })
                if let best = bestMatch {
                    let dist = levenshteinDistance(normalizeName(best.name), normalized)
                    let maxLen = max(normalized.count, normalizeName(best.name).count)
                    let similarity = 1.0 - Double(dist) / Double(max(maxLen, 1))
                    if similarity > 0.75 {
                        graph.edges[i] = applyMtnPowderLift(edge: edge, lift: best)
                        modified = true
                    }
                }
            }
        }

        return modified
    }

    private static func applyMtnPowderTrail(edge: GraphEdge, trail: MtnPowderTrail) -> GraphEdge {
        edge.withAttributes(edge.attributes.enriched(
            difficulty: trail.difficulty,
            trailName: edge.attributes.trailName ?? trail.name,
            hasMoguls: trail.hasMoguls,
            isGroomed: trail.isGroomed,
            isGladed: trail.isGladed,
            isOpen: trail.isOpen,
            isOfficiallyValidated: true
        ))
    }

    private static func applyMtnPowderLift(edge: GraphEdge, lift: MtnPowderLift) -> GraphEdge {
        edge.withAttributes(edge.attributes.enriched(
            trailName: edge.attributes.trailName ?? lift.name,
            hasMoguls: false,
            isGroomed: false,
            isGladed: false,
            liftType: lift.liftType,
            waitTimeMinutes: lift.waitTimeMinutes.map { Double($0) },
            isOpen: lift.isOpen,
            isOfficiallyValidated: true
        ))
    }

    // MARK: - Phantom Trail Validation

    /// Builds a normalized whitelist of official trail names from the Epic
    /// terrain feed. Used by `closePhantomTrails` on resorts that don't ship
    /// with a hand-curated whitelist JSON — covers the ~159 Epic/Ikon resorts
    /// automatically. Lifts are included so lift edges also escape closure.
    static func whitelist(fromEpic data: EpicTerrainData) -> Set<String> {
        var names: Set<String> = []
        for trail in data.allTrails where !trail.name.isEmpty {
            names.insert(normalizeName(trail.name))
        }
        for lift in data.allLifts where !lift.name.isEmpty {
            names.insert(normalizeName(lift.name))
        }
        return names
    }

    /// Same as `whitelist(fromEpic:)` but sourced from MtnPowder — some
    /// resorts are only covered by MtnPowder, not Epic.
    static func whitelist(fromMtnPowder data: MtnPowderData) -> Set<String> {
        var names: Set<String> = []
        for trail in data.trails where !trail.name.isEmpty {
            names.insert(normalizeName(trail.name))
        }
        for lift in data.lifts where !lift.name.isEmpty {
            names.insert(normalizeName(lift.name))
        }
        return names
    }

    /// Marks unmatched named OSM trails as uncertain rather than hard-closing them.
    /// Only fully closes a trail if it fails both exact and fuzzy name matching against
    /// all official sources AND is not in any curated whitelist.
    /// Trails marked as uncertain remain open but get a routing penalty via lower confidence.
    static func closePhantomTrails(
        graph: inout MountainGraph,
        hasOfficialData: Bool,
        officialNames: Set<String> = []
    ) {
        guard hasOfficialData else { return }

        var closedCount = 0
        var uncertainCount = 0
        for i in graph.edges.indices {
            let edge = graph.edges[i]
            guard (edge.kind == .run || edge.kind == .lift) else { continue }
            guard let trailName = edge.attributes.trailName, !trailName.isEmpty else { continue }
            guard !edge.attributes.isOfficiallyValidated else { continue }
            guard edge.attributes.isOpen else { continue }

            // Two-tier fuzzy gate:
            //   ≥0.85  → confident match, mark officially validated
            //   ≥0.72  → uncertain match, keep open without validating
            //   <0.72  → phantom, close the edge
            let bestSimilarity = officialNames.map { Self.fuzzySimilarity(trailName, $0) }.max() ?? 0

            if bestSimilarity >= 0.85 {
                graph.edges[i] = edge.withAttributes(edge.attributes.enriched(isOfficiallyValidated: true))
                uncertainCount += 1
            } else if bestSimilarity >= 0.72 {
                // Keep open, not validated — routing still works but skill gates treat it as lower confidence.
                uncertainCount += 1
            } else {
                // No match at all — close the phantom trail
                graph.edges[i] = edge.withAttributes(edge.attributes.enriched(isOpen: false))
                closedCount += 1
            }
        }

        // Caller batches the index rebuild — same reason as `enrich(...)`.
        if closedCount > 0 || uncertainCount > 0 {
            print("[Enricher] Phantom trails for \(graph.resortID): closed \(closedCount), fuzzy-matched \(uncertainCount)")
        }
    }

    /// Simple similarity metric (Dice coefficient on bigrams). Returns 0–1.
    private static func fuzzyMatch(_ a: String, _ b: String, threshold: Double) -> Bool {
        fuzzySimilarity(a, b) >= threshold
    }

    /// Dice coefficient on bigrams. Returns 0–1 so callers can apply tiered thresholds
    /// (e.g. 0.72 to keep open, 0.85 to mark officially validated).
    private static func fuzzySimilarity(_ a: String, _ b: String) -> Double {
        let aNorm = a.lowercased().filter { $0.isLetter || $0.isNumber }
        let bNorm = b.lowercased().filter { $0.isLetter || $0.isNumber }
        guard aNorm.count >= 2, bNorm.count >= 2 else {
            return aNorm == bNorm ? 1.0 : 0.0
        }
        let aBigrams = Set(zip(aNorm, aNorm.dropFirst()).map { "\($0)\($1)" })
        let bBigrams = Set(zip(bNorm, bNorm.dropFirst()).map { "\($0)\($1)" })
        let intersection = aBigrams.intersection(bBigrams).count
        return 2.0 * Double(intersection) / Double(aBigrams.count + bBigrams.count)
    }

    // MARK: - Apply Data Helpers

    private static func applyEpicTrailData(edge: GraphEdge, epic: EpicTrail) -> GraphEdge {
        edge.withAttributes(edge.attributes.enriched(
            difficulty: epic.runDifficulty,
            trailName: edge.attributes.trailName ?? epic.name,
            isGroomed: epic.isGroomed,
            isOpen: epic.isOpen,
            isOfficiallyValidated: true
        ))
    }

    private static func applyEpicLiftData(edge: GraphEdge, epic: EpicLift) -> GraphEdge {
        edge.withAttributes(edge.attributes.enriched(
            trailName: edge.attributes.trailName ?? epic.name,
            hasMoguls: false,
            isGroomed: false,
            isGladed: false,
            liftType: epic.liftType,
            liftCapacity: epic.capacity,
            waitTimeMinutes: epic.waitTimeInMinutes.map { Double($0) },
            isOpen: epic.isOpen,
            isOfficiallyValidated: true
        ))
    }

    // MARK: - Proximity Matching

    private static func findBestEpicTrailMatch(
        edge: GraphEdge,
        candidates: [EpicTrail],
        graph: MountainGraph
    ) -> EpicTrail? {
        // Score candidates by difficulty match + vertical proximity
        let edgeDifficulty = edge.attributes.difficulty
        let edgeVert = edge.attributes.verticalDrop

        var bestScore = Double.infinity
        var bestTrail: EpicTrail?

        for epic in candidates {
            var score: Double = 0

            // Difficulty mismatch penalty
            if let ed = edgeDifficulty {
                let diffMismatch = abs(ed.sortOrder - epic.runDifficulty.sortOrder)
                score += Double(diffMismatch) * 100
            }

            // Vertical proximity (if meaningful)
            if edgeVert > 10 {
                score += abs(edgeVert - 200) * 0.5 // rough penalty
            }

            if score < bestScore {
                bestScore = score
                bestTrail = epic
            }
        }

        // Only match if score is reasonable (don't force bad matches)
        guard bestScore < 300, let trail = bestTrail else { return nil }
        return trail
    }

    private static func findBestEpicLiftMatch(
        edge: GraphEdge,
        candidates: [EpicLift],
        graph: MountainGraph
    ) -> EpicLift? {
        let edgeVert = edge.attributes.verticalDrop
        let edgeLiftType = edge.attributes.liftType

        var bestScore = Double.infinity
        var bestLift: EpicLift?

        for epic in candidates {
            var score: Double = 0

            // Type match bonus
            if let et = edgeLiftType, let epicType = epic.liftType, et == epicType {
                score -= 50
            } else if edgeLiftType != nil && epic.liftType != nil {
                score += 30
            }

            // Vertical proximity
            if edgeVert > 10, let epicCap = epic.capacity {
                // Rough heuristic: higher capacity lifts tend to be longer
                let expectedVert = Double(epicCap) * 30
                score += abs(edgeVert - expectedVert) * 0.3
            }

            if score < bestScore {
                bestScore = score
                bestLift = epic
            }
        }

        guard bestScore < 200, let lift = bestLift else { return nil }
        return lift
    }

    // MARK: - String Matching Utilities

    /// Normalize a trail/lift name for comparison.
    /// Lowercases, strips common suffixes, removes punctuation.
    static func normalizeName(_ name: String) -> String {
        var s = name.lowercased()
            .replacingOccurrences(of: "express", with: "")
            .replacingOccurrences(of: "quad", with: "")
            .replacingOccurrences(of: "triple", with: "")
            .replacingOccurrences(of: "double", with: "")
            .replacingOccurrences(of: "detach", with: "")
            .replacingOccurrences(of: "fixed", with: "")
            .replacingOccurrences(of: "high-speed", with: "")
            .replacingOccurrences(of: "high speed", with: "")

        // Remove punctuation and extra spaces
        s = s.filter { $0.isLetter || $0.isNumber || $0 == " " }
        s = s.split(separator: " ").joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        return s
    }

    /// Levenshtein edit distance between two strings.
    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,          // deletion
                    curr[j - 1] + 1,      // insertion
                    prev[j - 1] + cost    // substitution
                )
            }
            prev = curr
        }

        return curr[n]
    }
}
