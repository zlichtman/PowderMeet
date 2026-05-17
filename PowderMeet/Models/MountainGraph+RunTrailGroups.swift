//
//  MountainGraph+RunTrailGroups.swift
//  PowderMeet
//
//  Canonical run trail groups (trailGroupId) for picker + map alignment.
//

import Foundation
import CoreLocation

/// One consolidated run pathway — matches map GeoJSON grouping.
nonisolated struct RunTrailGroupSummary: Sendable {
    let trailGroupId: String
    let orderedRunEdges: [GraphEdge]
    /// Higher-elevation chain end (conventional top).
    let topNodeId: String
    /// Lower-elevation chain end (conventional bottom).
    let bottomNodeId: String
    let displayName: String?
    let difficulty: RunDifficulty?

    /// All run nodes incident to any edge in this group (for middle-of-trail detection).
    var runNodeIds: Set<String> {
        var s = Set<String>()
        for e in orderedRunEdges {
            s.insert(e.sourceID)
            s.insert(e.targetID)
        }
        return s
    }
}

// Inherits `nonisolated` from the primary `MountainGraph` declaration —
// repeated explicitly so methods stay callable from MountainNaming
// (also nonisolated) and other off-main-actor compute paths.
nonisolated extension MountainGraph {

    /// Per-`trailGroupId` picker row title, with disambiguation when the same
    /// trail name + difficulty appears on multiple disconnected groups.
    func runTrailPickerTitlesByGroupId() -> [String: String] {
        let summaries = runTrailGroupSummaries()
        func normName(_ s: String?) -> String {
            guard let n = s?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return "" }
            return GraphBuilder.normalizedTrailKey(n)
        }
        var buckets: [[RunTrailGroupSummary]] = []
        var keyIndex: [String: Int] = [:]
        for s in summaries {
            let nk = normName(s.displayName)
            let dk = s.difficulty?.rawValue ?? "_"
            let key = "\(nk)|\(dk)"
            if let idx = keyIndex[key] {
                buckets[idx].append(s)
            } else {
                keyIndex[key] = buckets.count
                buckets.append([s])
            }
        }

        var out: [String: String] = [:]
        for group in buckets {
            guard !group.isEmpty else { continue }
            if group.count == 1 {
                let s = group[0]
                out[s.trailGroupId] = Self.basePickerTitle(for: s)
                continue
            }
            let sorted = group.sorted { $0.trailGroupId < $1.trailGroupId }
            for (i, s) in sorted.enumerated() {
                let suffix = sorted.count > 1 ? " · #\(i + 1)" : ""
                out[s.trailGroupId] = Self.basePickerTitle(for: s) + suffix
            }
        }
        return out
    }

    private static func basePickerTitle(for s: RunTrailGroupSummary) -> String {
        let raw = s.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = raw.isEmpty ? "Trail" : raw
        if let d = s.difficulty {
            return "\(name) · \(d.displayName)"
        }
        return name
    }

    /// All run `trailGroupId` summaries with ordered edges and top/bottom endpoints.
    func runTrailGroupSummaries() -> [RunTrailGroupSummary] {
        var byGid: [String: [GraphEdge]] = [:]
        for e in runs {
            let gid = e.attributes.trailGroupId ?? e.id
            byGid[gid, default: []].append(e)
        }

        var out: [RunTrailGroupSummary] = []
        for (gid, edges) in byGid {
            guard let s = RunTrailGroupSummary.build(trailGroupId: gid, runEdges: edges, nodes: nodes) else {
                continue
            }
            out.append(s)
        }
        return out.sorted {
            let a = $0.displayName ?? $0.trailGroupId
            let b = $1.displayName ?? $1.trailGroupId
            if a.caseInsensitiveCompare(b) != .orderedSame {
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            return $0.trailGroupId < $1.trailGroupId
        }
    }

    /// Run `trailGroupId` for a node if it touches any run edge in that group.
    func runTrailGroupId(containingRunNode nodeId: String) -> String? {
        for e in runs where e.sourceID == nodeId || e.targetID == nodeId {
            return e.attributes.trailGroupId ?? e.id
        }
        return nil
    }

    /// Summary for a run trail group id, or nil.
    func runTrailGroupSummary(forGroupId groupId: String) -> RunTrailGroupSummary? {
        let runEdges = edgesInGroup(groupId).filter { $0.kind == .run }
        return RunTrailGroupSummary.build(trailGroupId: groupId, runEdges: runEdges, nodes: nodes)
    }

    /// Run trail summary for any node that lies on a run edge in the group.
    func runTrailGroupSummary(containingRunNode nodeId: String) -> RunTrailGroupSummary? {
        guard let gid = runTrailGroupId(containingRunNode: nodeId) else { return nil }
        return runTrailGroupSummary(forGroupId: gid)
    }
}

nonisolated extension RunTrailGroupSummary {
    fileprivate static func build(
        trailGroupId: String,
        runEdges: [GraphEdge],
        nodes: [String: GraphNode]
    ) -> RunTrailGroupSummary? {
        guard !runEdges.isEmpty else { return nil }
        let ordered = TrailChainGeometry.orderEdgeChain(runEdges)
        let rep = ordered.first!
        let (top, bottom) = Self.topBottomEndpoints(ordered: ordered, nodes: nodes)
        return RunTrailGroupSummary(
            trailGroupId: trailGroupId,
            orderedRunEdges: ordered,
            topNodeId: top,
            bottomNodeId: bottom,
            displayName: rep.attributes.trailName,
            difficulty: rep.attributes.difficulty
        )
    }

    /// Pick chain ends; higher elevation = top. Falls back to first edge orientation.
    private static func topBottomEndpoints(
        ordered: [GraphEdge],
        nodes: [String: GraphNode]
    ) -> (String, String) {
        let terminals = TrailChainGeometry.chainTerminalNodes(ordered: ordered)
        if terminals.count == 2 {
            let a = terminals[0]
            let b = terminals[1]
            let ea = nodes[a]?.elevation ?? 0
            let eb = nodes[b]?.elevation ?? 0
            return ea >= eb ? (a, b) : (b, a)
        }
        guard let e0 = ordered.first else { return ("", "") }
        let s = e0.sourceID
        let t = e0.targetID
        let es = nodes[s]?.elevation ?? 0
        let et = nodes[t]?.elevation ?? 0
        return es >= et ? (s, t) : (t, s)
    }
}
