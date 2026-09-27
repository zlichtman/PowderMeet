//
//  GraphBuilder+TrailGroups.swift
//  PowderMeet
//
//  Extension of GraphBuilder — trail-group assignment + diagnostics.
//  Split out of GraphBuilder.swift (behavior-preserving code motion) so the
//  legacy on-device build pipeline is navigable by stage. File-private helpers
//  were promoted to internal to be visible across these extension files.
//

import Foundation
import CoreLocation

nonisolated extension GraphBuilder {

    /// Aggressive trail-name normalization so minor OSM inconsistencies
    /// (punctuation, casing, extra whitespace, accents) don't split a single
    /// logical trail into multiple groups. "Peak to Creek", "Peak-to-Creek",
    /// "Peak To Creek " all hash to the same key.
    /// Same normalization used when assigning `trailGroupId` during graph build.
    static func normalizedTrailKey(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let collapsed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let trimmed = String(collapsed).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return trimmed
    }

    /// Stable logical-trail identity derived from the component's source edge
    /// IDs. Adding an unrelated trail cannot renumber every group on a mountain.
    static func stableTrailGroupID(edgeIDs: [String]) -> String {
        let input = "trail-group-v1|" + edgeIDs.sorted().joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "tg-" + String(hash, radix: 16)
    }

    /// Groups edges that share the same normalized trail name, same difficulty,
    /// and are connected via shared nodes into a single logical trail.
    /// Each group gets a unique `trailGroupId` written into EdgeAttributes.
    ///
    /// This solves OSM's fragmentation: one trail stored as 5 separate ways
    /// becomes one visual line on the map.
    static func assignTrailGroups(_ edges: inout [GraphEdge], hints: ResortGraphBuildHints? = nil) {
        let mergeNamedTraverses = hints?.mergeNamedTraverseGroups ?? true

        // Build index: (normalizedName, difficulty or "traverse") → [edge indices]
        var keyToIndices: [String: [Int]] = [:]
        for (i, edge) in edges.enumerated() {
            guard let name = edge.attributes.trailName, !name.isEmpty else { continue }
            let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
            if lower.hasPrefix("unnamed") { continue }

            switch edge.kind {
            case .run, .lift:
                let normName = normalizedTrailKey(name)
                let diffKey = edge.attributes.difficulty?.rawValue ?? "none"
                let key = "\(normName)|\(diffKey)"
                keyToIndices[key, default: []].append(i)
            case .traverse where mergeNamedTraverses:
                let normName = normalizedTrailKey(name)
                let key = "\(normName)|traverse"
                keyToIndices[key, default: []].append(i)
            default:
                break
            }
        }

        // For each group of same-name/difficulty edges, use union-find
        // to merge those connected via shared nodes into trail groups.
        for key in keyToIndices.keys.sorted() {
            guard let indices = keyToIndices[key] else { continue }
            guard indices.count >= 1 else { continue }

            if indices.count == 1 {
                // Single edge — give it its own group
                let idx = indices[0]
                var attrs = edges[idx].attributes
                attrs.trailGroupId = stableTrailGroupID(edgeIDs: [edges[idx].id])
                edges[idx] = GraphEdge(
                    id: edges[idx].id, sourceID: edges[idx].sourceID,
                    targetID: edges[idx].targetID, kind: edges[idx].kind,
                    geometry: edges[idx].geometry, attributes: attrs
                )
                continue
            }

            // Union-Find for this set of edges
            var parent = Array(0..<indices.count)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x {
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                }
                return x
            }
            func union(_ a: Int, _ b: Int) {
                let ra = find(a), rb = find(b)
                if ra != rb { parent[ra] = rb }
            }

            // Build node→local-index map: which local edges touch each node
            var nodeToLocal: [String: [Int]] = [:]
            for (localIdx, edgeIdx) in indices.enumerated() {
                let e = edges[edgeIdx]
                nodeToLocal[e.sourceID, default: []].append(localIdx)
                nodeToLocal[e.targetID, default: []].append(localIdx)
            }

            // Union edges sharing a node
            for (_, locals) in nodeToLocal {
                for j in 1..<locals.count {
                    union(locals[0], locals[j])
                }
            }

            // Collect components and assign group IDs
            var componentEdges: [Int: [Int]] = [:]
            for localIdx in 0..<indices.count {
                componentEdges[find(localIdx), default: []].append(indices[localIdx])
            }
            let orderedComponents = componentEdges.values.sorted {
                $0.map { edges[$0].id }.sorted().joined(separator: "|")
                    < $1.map { edges[$0].id }.sorted().joined(separator: "|")
            }
            for edgeIndices in orderedComponents {
                let gid = stableTrailGroupID(edgeIDs: edgeIndices.map { edges[$0].id })
                for idx in edgeIndices {
                    var attrs = edges[idx].attributes
                    attrs.trailGroupId = gid
                    edges[idx] = GraphEdge(
                        id: edges[idx].id, sourceID: edges[idx].sourceID,
                        targetID: edges[idx].targetID, kind: edges[idx].kind,
                        geometry: edges[idx].geometry, attributes: attrs
                    )
                }
            }
        }

        // Assign groups to remaining ungrouped runs and lifts (one id each).
        for i in 0..<edges.count {
            guard edges[i].attributes.trailGroupId == nil else { continue }
            guard edges[i].kind == .run || edges[i].kind == .lift else { continue }
            var attrs = edges[i].attributes
            attrs.trailGroupId = stableTrailGroupID(edgeIDs: [edges[i].id])
            edges[i] = GraphEdge(
                id: edges[i].id, sourceID: edges[i].sourceID,
                targetID: edges[i].targetID, kind: edges[i].kind,
                geometry: edges[i].geometry, attributes: attrs
            )
        }

        // Unnamed traverse micro-segments: one trailGroupId per connected component.
        mergeUnnamedTraverseChainComponents(&edges)

        let groupedRuns = edges.filter { $0.kind == .run && $0.attributes.trailGroupId != nil }
        let uniqueGroups = Set(groupedRuns.compactMap { $0.attributes.trailGroupId })
        print("[GraphBuilder] Assigned \(groupedRuns.count) run edges to \(uniqueGroups.count) trail groups")
    }

    /// Groups unnamed `traverse` edges that share nodes into single `trailGroupId`s.
    static func mergeUnnamedTraverseChainComponents(_ edges: inout [GraphEdge]) {
        let pending = edges.enumerated().compactMap { i, e -> Int? in
            guard e.kind == .traverse, e.attributes.trailGroupId == nil else { return nil }
            return i
        }
        guard !pending.isEmpty else { return }

        var parent: [Int: Int] = [:]
        for i in pending { parent[i] = i }
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x]! != x {
                parent[x] = parent[parent[x]!]!
                x = parent[x]!
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var nodeToIdx: [String: [Int]] = [:]
        for i in pending {
            let e = edges[i]
            nodeToIdx[e.sourceID, default: []].append(i)
            nodeToIdx[e.targetID, default: []].append(i)
        }
        for (_, arr) in nodeToIdx {
            for j in 1..<arr.count {
                union(arr[0], arr[j])
            }
        }

        var components: [Int: [Int]] = [:]
        for i in pending {
            components[find(i), default: []].append(i)
        }
        let orderedComponents = components.values.sorted {
            $0.map { edges[$0].id }.sorted().joined(separator: "|")
                < $1.map { edges[$0].id }.sorted().joined(separator: "|")
        }
        for idxs in orderedComponents {
            let gid = stableTrailGroupID(edgeIDs: idxs.map { edges[$0].id })
            for idx in idxs {
                var attrs = edges[idx].attributes
                attrs.trailGroupId = gid
                edges[idx] = GraphEdge(
                    id: edges[idx].id, sourceID: edges[idx].sourceID,
                    targetID: edges[idx].targetID, kind: edges[idx].kind,
                    geometry: edges[idx].geometry, attributes: attrs
                )
            }
        }
    }

    // MARK: - Diagnostics

    /// Log graph health metrics for debugging.
    static func logDiagnostics(_ graph: MountainGraph) {
        var outCount: [String: Int] = [:]
        for edge in graph.edges {
            outCount[edge.sourceID, default: 0] += 1
        }

        let sinks = graph.nodes.keys.filter { outCount[$0, default: 0] == 0 }.count

        var totalEdgeCount: [String: Int] = [:]
        for edge in graph.edges {
            totalEdgeCount[edge.sourceID, default: 0] += 1
            totalEdgeCount[edge.targetID, default: 0] += 1
        }
        let deadEnds = graph.nodes.keys.filter { totalEdgeCount[$0, default: 0] <= 1 }.count

        let namedRuns = Set(graph.runs.compactMap { $0.attributes.trailName }).count
        let namedLifts = Set(graph.lifts.compactMap { $0.attributes.trailName }).count

        // Elevation health
        let runsWithVert = graph.runs.filter { $0.attributes.verticalDrop > 0 }.count
        let liftsWithVert = graph.lifts.filter { $0.attributes.verticalDrop > 0 }.count
        let nodesWithElev = graph.nodes.values.filter { $0.elevation > 0 }.count
        let maxVert = graph.edges.map { $0.attributes.verticalDrop }.max() ?? 0

        print("""
        [GraphDiag] Nodes: \(graph.nodes.count), Edges: \(graph.edges.count)
        [GraphDiag] Runs: \(graph.runs.count) (\(namedRuns) named), Lifts: \(graph.lifts.count) (\(namedLifts) named)
        [GraphDiag] Directed sinks (no outgoing): \(sinks)
        [GraphDiag] Dead ends (≤1 total edge): \(deadEnds)
        [GraphDiag] Elevation: \(nodesWithElev)/\(graph.nodes.count) nodes with elev, runs w/vert: \(runsWithVert)/\(graph.runs.count), lifts w/vert: \(liftsWithVert)/\(graph.lifts.count), max vert: \(Int(maxVert))m
        """)
    }
}
