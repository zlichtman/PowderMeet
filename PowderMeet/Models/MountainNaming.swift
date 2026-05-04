//
//  MountainNaming.swift
//  PowderMeet
//
//  Single source of truth for "what is the human name of this place
//  on the mountain". Wraps the run-group / lift-group rules that
//  `RoutingTestSheet` established and exposes them to every consumer
//  through one API, so a node labeled "Frontside Run · Black · TOP"
//  in the picker can never appear as "Frontside Run" or "Junction
//  (3122 m)" anywhere else.
//
//  Replaces five independent name systems that previously disagreed:
//    - `MountainGraph.displayName(for:)`              (graph-adjacency, broken at junctions)
//    - `MountainGraph.displayName(near:)`             (thin wrapper of the above)
//    - `MountainGraph.locationPickerAlignedTitle(for:)` (partial fix; only 3 callers used it)
//    - `RoutingTestSheet.PickerEntry` inline naming
//    - `RouteInstructionBuilder.edgeName` raw `trailName` access
//    - `GeoJSONBuilder.liftEndpointFeatures` inline `name + " TOP"` formatting
//
//  Construction is O(edges) — same cost as a single call to the old
//  `runTrailPickerTitlesByGroupId()`, but amortized across every
//  subsequent lookup. Callers that do many lookups (`RoutingTestSheet`,
//  `GeoJSONBuilder.poiFeatures`) should construct once and reuse;
//  one-off callers can construct per call without measurable cost.
//

import Foundation
import CoreLocation

// `nonisolated` — called from the solver's route-narrative path, which
// runs in detached compute. Pure derivation over MountainGraph state.
nonisolated struct MountainNaming {
    enum Style {
        /// "Frontside Run · Black", "Peak Express", "Gondola #1",
        /// "Junction · 3122 m" for nodes outside any named group.
        /// Never returns the empty string or a raw graph id.
        case canonical

        /// Adds chain-position suffix where it disambiguates:
        /// run chains → "Frontside Run · Black · TOP" / "· BOTTOM"
        /// lifts      → "Peak Express · BASE" / "· TOP"
        /// otherwise  → same as `.canonical`
        case withChainPosition

        /// Trail / lift name only — no difficulty, no position.
        /// For route instructions where the difficulty is rendered
        /// separately as a parenthetical "(Black)".
        case bareName
    }

    let graph: MountainGraph
    private let cache: NamingCache

    /// Process-wide cache keyed by `MountainGraph.fingerprint`. Building
    /// the `NamingCache` is O(edges) — Whistler's ~8k edges add up
    /// across the consumers that ask for one per render
    /// (`GeoJSONBuilder.poiFeatures`, route-step instructions, every
    /// SwiftUI body re-eval that calls `nodeLabel`). The fingerprint is
    /// already stamped on the graph at build/mutation time, so cache
    /// invalidation is automatic — a `rebuildIndices()` after enrichment
    /// regenerates the fingerprint and the next `MountainNaming(graph)`
    /// rebuilds.
    ///
    /// `NSCache` is the right shape: thread-safe, automatic eviction
    /// under memory pressure, no manual lifecycle. Cap at a few resorts
    /// — anyone bouncing through more than 8 unique resorts in a
    /// session is a corner case the eviction handles cleanly.
    private static let sharedCache: NSCache<NSString, NamingCache> = {
        let c = NSCache<NSString, NamingCache>()
        c.countLimit = 8
        return c
    }()

    init(_ graph: MountainGraph) {
        self.graph = graph
        if let fingerprint = graph.fingerprint as NSString? {
            if let hit = Self.sharedCache.object(forKey: fingerprint) {
                self.cache = hit
            } else {
                let built = NamingCache.build(for: graph)
                Self.sharedCache.setObject(built, forKey: fingerprint)
                self.cache = built
            }
        } else {
            // Graph with no fingerprint (shouldn't happen — `MountainGraph`
            // always stamps one — but if it does, build without caching
            // rather than fail).
            self.cache = NamingCache.build(for: graph)
        }
    }

    // MARK: - Public API

    /// Label for any graph node. Always returns a non-empty string.
    func nodeLabel(_ nodeId: String, style: Style = .canonical) -> String {
        guard let node = graph.nodes[nodeId] else { return nodeId }

        // Run group. `nodeLabel` is for general UI consumers (friend
        // cards, map POIs, meeting-node labels, solver logs, profile
        // HUD) — none of which want the picker's "· #N" disambig
        // suffix. Use `displayTitleByGroupId` (picker minus disambig).
        // The picker's own row labels go through `runGroupTitle(forGroupId:)`,
        // which still returns the full disambig'd `pickerTitleByGroupId`.
        if let groupId = cache.runGroupForNode[nodeId],
           let title = cache.displayTitleByGroupId[groupId] {
            switch style {
            case .canonical:
                return title
            case .bareName:
                return cache.bareTitleByGroupId[groupId] ?? title
            case .withChainPosition:
                if cache.runGroupTopNode[groupId] == nodeId {
                    return title + " · TOP"
                }
                if cache.runGroupBottomNode[groupId] == nodeId {
                    return title + " · BOTTOM"
                }
                return title
            }
        }

        // Lift node (named or unnamed) — picker-aligned label.
        if node.kind == .liftBase || node.kind == .liftTop,
           let liftLabel = cache.liftLabelByNodeId[nodeId] {
            switch style {
            case .canonical, .bareName:
                return liftLabel
            case .withChainPosition:
                return liftLabel + (node.kind == .liftBase ? " · BASE" : " · TOP")
            }
        }

        // Bare-name asks for trail/lift identity only — no kind+elevation
        // fallback (the caller renders one separately if needed).
        if style == .bareName {
            if let groupId = cache.fallbackRunGroupForNode[nodeId],
               let title = cache.bareTitleByGroupId[groupId] {
                return title
            }
            return ""
        }

        // Junction / connector / trailhead with an incident named run —
        // surface that group's title so the user sees a real trail name
        // instead of the kind+elevation fallback.
        if let groupId = cache.fallbackRunGroupForNode[nodeId],
           let title = cache.displayTitleByGroupId[groupId] {
            return title
        }

        // Final fallback: kind + elevation.
        return Self.kindElevationLabel(for: node)
    }

    /// Label for an edge — returns the trail/lift it logically belongs
    /// to. Used by route step instructions and any UI that asks "what
    /// trail are you on right now". Resolves through `trailGroupId`
    /// so OSM-fragmented ways agree (a chain whose three OSM ways are
    /// "Frontside Run", "Frontside Run", "Frontside Lower" reads as
    /// the canonical group title throughout, not three different
    /// strings).
    func edgeLabel(_ edge: GraphEdge, style: Style = .canonical) -> String {
        if let groupId = edge.attributes.trailGroupId {
            switch style {
            case .canonical, .withChainPosition:
                // Edges don't have a meaningful chain-position (TOP /
                // BOTTOM is a node attribute), so `.withChainPosition`
                // collapses to the same display title as `.canonical`.
                if let title = cache.displayTitleByGroupId[groupId] { return title }
            case .bareName:
                if let title = cache.bareTitleByGroupId[groupId] { return title }
            }
        }
        // GroupId miss but the edge itself carries a name — use it before
        // falling through to a node-kind+elevation label.
        if let raw = edge.attributes.trailName, !raw.isEmpty {
            switch style {
            case .canonical, .withChainPosition:
                if let diff = edge.attributes.difficulty, edge.kind == .run {
                    return "\(raw) · \(diff.displayName)"
                }
                return raw
            case .bareName:
                return raw
            }
        }
        // No groupId, no raw name. Walk both endpoints — many OSM ways
        // are anonymous connectors between named chains, so the source
        // OR target node's `runGroupForNode` / `fallbackRunGroupForNode`
        // often resolves to a sensible name. Try source first (matches
        // pre-consolidation behaviour), fall back to target.
        if let title = inheritedRunGroupTitle(for: edge.sourceID, style: style) {
            return title
        }
        if let title = inheritedRunGroupTitle(for: edge.targetID, style: style) {
            return title
        }
        // Nothing inherited — return a difficulty-tagged generic label
        // for runs ("Black Run" / "Blue Run" / etc.) instead of the
        // useless "Junction (1234m)" the kind+elevation fallback would
        // produce. For lifts, fall through to the standard nodeLabel
        // path so existing lift-naming heuristics still apply.
        if edge.kind == .run, style != .bareName {
            if let diff = edge.attributes.difficulty {
                return "\(diff.displayName) Run"
            }
            return "Run"
        }
        return nodeLabel(edge.sourceID, style: style)
    }

    /// Returns the display title of the run group that includes `nodeId`
    /// (either as a chain-membership node or as a fallback junction
    /// adjacent to a named chain). Nil when neither cache has an entry.
    /// Used by `edgeLabel` to label unnamed connector edges with the
    /// chain they're part of.
    private func inheritedRunGroupTitle(for nodeId: String, style: Style) -> String? {
        if let groupId = cache.runGroupForNode[nodeId] {
            switch style {
            case .canonical, .withChainPosition:
                if let t = cache.displayTitleByGroupId[groupId] { return t }
            case .bareName:
                if let t = cache.bareTitleByGroupId[groupId] { return t }
            }
        }
        if let groupId = cache.fallbackRunGroupForNode[nodeId] {
            switch style {
            case .canonical, .withChainPosition:
                if let t = cache.displayTitleByGroupId[groupId] { return t }
            case .bareName:
                if let t = cache.bareTitleByGroupId[groupId] { return t }
            }
        }
        return nil
    }

    /// Convenience: nearest-node lookup → label.
    func locationLabel(near coord: CLLocationCoordinate2D, style: Style = .canonical) -> String? {
        guard let node = graph.nearestNode(to: coord) else { return nil }
        return nodeLabel(node.id, style: style)
    }

    /// Stable, OK-to-store-on-the-server label for a meeting node.
    /// Captured at request-send time and echoed by the receiver. Always
    /// uses `.canonical` style — receivers may render against a slightly
    /// different graph version, but a string captured under canonical
    /// rules stays human-readable and matches what *their* picker
    /// would say for the same node id on their copy of the graph.
    func meetingNodeLabel(_ nodeId: String) -> String {
        nodeLabel(nodeId, style: .canonical)
    }

    /// Display-title lookup by `trailGroupId`. Returns the same
    /// "Trail · Difficulty" form `nodeLabel(_:.canonical)` produces
    /// for a chain node — but bypasses the node-id ambiguity at
    /// shared junctions. Use this when you already know which chain
    /// you're labeling.
    ///
    /// (`nodeLabel(_:.canonical)` for a chain node looks up
    /// `runGroupForNode[nodeId]`, which collapses to a single group
    /// when a node sits at a junction shared between two chains —
    /// the row's identity is the summary's groupId, not the
    /// topNode's nearest group.)
    func runGroupTitle(forGroupId groupId: String) -> String? {
        cache.displayTitleByGroupId[groupId]
    }

    /// Picker-row title — the disambig'd "Trail · Difficulty · #N"
    /// form. Used **only** by `RoutingTestSheet` for the row labels
    /// in its list. Every other consumer wants the display title (no
    /// disambig) — see `runGroupTitle(forGroupId:)` /
    /// `nodeLabel(_:.canonical)` / `edgeLabel(_:.canonical)`.
    ///
    /// Why this is separate: the disambig "· #N" suffix exists to
    /// tell two disconnected chains with the same name+difficulty
    /// apart in a list view. Outside the picker (friend cards,
    /// meeting-node labels, map POIs, solver logs, profile HUD,
    /// route step instructions) it's pure visual noise — the user is
    /// reading about ONE trail at a time and "Frontside Run · Black
    /// · #2" is no clearer than "Frontside Run · Black".
    func pickerRowTitle(forGroupId groupId: String) -> String? {
        cache.pickerTitleByGroupId[groupId]
    }

    /// One picker entry per unique lift identity — named lifts dedupe by
    /// normalized name (lowest base wins); unnamed lifts get a stable
    /// "<Type> #N" index. Used by `RoutingTestSheet` so the picker rows
    /// share the exact same set of canonical lift labels every other
    /// surface in the app uses for the same nodes.
    var liftPickerEntries: [LiftPickerEntry] {
        cache.liftPickerEntries.map {
            LiftPickerEntry(
                nodeId: $0.nodeId,
                label: $0.label,
                elevation: graph.nodes[$0.nodeId]?.elevation ?? 0
            )
        }
    }

    struct LiftPickerEntry: Identifiable {
        let nodeId: String
        let label: String
        let elevation: Double
        var id: String { nodeId }
    }

    // MARK: - Helpers

    private static func kindElevationLabel(for node: GraphNode) -> String {
        let kind: String
        switch node.kind {
        case .liftBase:   kind = "Lift Base"
        case .liftTop:    kind = "Lift Top"
        case .junction:   kind = "Junction"
        case .trailHead:  kind = "Trail Head"
        case .trailEnd:   kind = "Trail End"
        case .midStation: kind = "Mid Station"
        }
        return "\(kind) · \(UnitFormatter.elevation(node.elevation))"
    }
}

// MARK: - Cache

/// Precomputed lookups for `MountainNaming`. Built once per graph.
/// All maps are O(1) on lookup; build cost is O(edges) — same as a
/// single call to the old `runTrailPickerTitlesByGroupId()`.
///
/// Class (not struct) so it can sit inside `NSCache` — process-wide
/// reuse across `MountainNaming` instances saves the rebuild on every
/// per-render consumer (`GeoJSONBuilder.poiFeatures`, route-step
/// instruction labels, etc.) for the price of an NSCache lookup.
fileprivate nonisolated final class NamingCache {
    /// `trailGroupId` → "Frontside Run · Black · #2" — picker rows only.
    /// The " · #N" disambig suffix is appended when two disconnected
    /// groups share the same name + difficulty after grouping. Useful
    /// in a list (the picker), noise everywhere else.
    let pickerTitleByGroupId: [String: String]

    /// `trailGroupId` → "Frontside Run · Black" — picker title minus the
    /// disambig suffix. **This is what every non-picker consumer uses**
    /// (friend cards, meeting-node labels, map POIs, solver logs, profile
    /// HUD). The user looking at a friend on "Frontside Run · Black"
    /// doesn't care that there's a disconnected second chain also named
    /// "Frontside Run · Black" elsewhere on the mountain — the disambig
    /// adds no information in that context, just visual clutter.
    let displayTitleByGroupId: [String: String]

    /// `trailGroupId` → "Frontside Run" — display title minus the
    /// difficulty suffix too. Used by `RouteInstructionBuilder` so
    /// consecutive same-trail edges merge into one instruction
    /// (the difficulty is shown separately in the instruction line).
    let bareTitleByGroupId: [String: String]

    /// node id → `trailGroupId` for any node that lies on a run edge
    /// in that group. Used for run-position lookups (top/bottom check).
    let runGroupForNode: [String: String]

    /// `trailGroupId` → top-elevation node id of the chain.
    let runGroupTopNode: [String: String]
    let runGroupBottomNode: [String: String]

    /// node id → "Peak Express" / "Gondola #1" — only populated for
    /// `liftBase` / `liftTop` nodes that lie on a lift edge.
    let liftLabelByNodeId: [String: String]

    /// Same as `runGroupForNode`, but also includes nodes that *touch*
    /// a run group via incidence (no run edge keys this node, but a
    /// neighbour's run edge does). Used for the picker-style fallback
    /// at junctions so a 3-way junction labels as the highest-elevation
    /// adjacent run rather than a generic "Junction · 3122 m".
    let fallbackRunGroupForNode: [String: String]

    /// One canonical entry per unique lift identity — named lifts dedupe
    /// by normalized name; unnamed lifts get a stable "<Type> #N" index.
    /// Built once at cache init so the picker doesn't re-walk
    /// `graph.edges`.
    let liftPickerEntries: [(nodeId: String, label: String)]

    init(
        pickerTitleByGroupId: [String: String],
        displayTitleByGroupId: [String: String],
        bareTitleByGroupId: [String: String],
        runGroupForNode: [String: String],
        runGroupTopNode: [String: String],
        runGroupBottomNode: [String: String],
        liftLabelByNodeId: [String: String],
        fallbackRunGroupForNode: [String: String],
        liftPickerEntries: [(nodeId: String, label: String)]
    ) {
        self.pickerTitleByGroupId = pickerTitleByGroupId
        self.displayTitleByGroupId = displayTitleByGroupId
        self.bareTitleByGroupId = bareTitleByGroupId
        self.runGroupForNode = runGroupForNode
        self.runGroupTopNode = runGroupTopNode
        self.runGroupBottomNode = runGroupBottomNode
        self.liftLabelByNodeId = liftLabelByNodeId
        self.fallbackRunGroupForNode = fallbackRunGroupForNode
        self.liftPickerEntries = liftPickerEntries
    }

    static func build(for graph: MountainGraph) -> NamingCache {
        // ── 1. Run groups — collect summaries and assemble picker titles
        let summaries = graph.runTrailGroupSummaries()
        let pickerTitles = graph.runTrailPickerTitlesByGroupId()
        var displayTitles: [String: String] = [:]
        var bareTitles: [String: String] = [:]
        var runGroupForNode: [String: String] = [:]
        var runGroupTop: [String: String] = [:]
        var runGroupBottom: [String: String] = [:]

        // Two-pass: terminal nodes (chain top/bottom) win over mid-chain
        // claims. A 3-way junction shared between trails A and B used to
        // key whichever chain iterated last, which mislabeled `nodeLabel`
        // for that node. By writing terminals second AND skipping mids
        // that are already claimed, we get a stable answer that prefers
        // "this is the start/end of trail X" over "this is somewhere on
        // trail Y."
        //
        // (Picker rows that already know their trailGroupId should call
        // `runGroupTitle(forGroupId:)` directly — that lookup is the
        // unambiguous one.)
        for s in summaries {
            let pickerTitle = pickerTitles[s.trailGroupId] ?? (s.displayName ?? "Trail")
            // Display title = picker title minus the disambig "· #N" suffix.
            // Used everywhere that's NOT the picker (friend cards, meeting
            // node labels, map POIs, solver logs, profile HUD).
            displayTitles[s.trailGroupId] = stripDisambigSuffix(from: pickerTitle)
            // Bare title = display title minus the difficulty too. Used by
            // route-instruction merging — the difficulty is rendered
            // separately by the instruction line.
            bareTitles[s.trailGroupId] = stripPickerDecorations(from: pickerTitle, difficulty: s.difficulty)
            runGroupTop[s.trailGroupId] = s.topNodeId
            runGroupBottom[s.trailGroupId] = s.bottomNodeId
        }
        // Pass 1: mid-chain nodes (no terminal claim yet). First-iteration
        // wins for these; later chains skip already-claimed nodes.
        for s in summaries {
            for nodeId in s.runNodeIds where nodeId != s.topNodeId && nodeId != s.bottomNodeId {
                if runGroupForNode[nodeId] == nil {
                    runGroupForNode[nodeId] = s.trailGroupId
                }
            }
        }
        // Pass 2: terminals overwrite. A node that's a terminal of one
        // chain AND mid of another gets the terminal's chain — that's
        // the one it most-naturally identifies with.
        for s in summaries {
            runGroupForNode[s.topNodeId] = s.trailGroupId
            runGroupForNode[s.bottomNodeId] = s.trailGroupId
        }

        // ── 2. Lifts — group by normalized name (lowest base wins per name);
        // unnamed lifts get a stable "<Type> #N" by edge-iteration order.
        var liftLabelByNodeId: [String: String] = [:]
        var liftPickerEntries: [(nodeId: String, label: String)] = []

        // Named: pick the lowest base elevation as the "primary" lift node;
        // also label its top counterpart with the same name.
        var namedLifts: [String: (sourceId: String, targetId: String, elevation: Double, displayName: String)] = [:]
        for edge in graph.edges where edge.kind == .lift {
            guard let name = edge.attributes.trailName, !name.isEmpty else { continue }
            let key = name.lowercased().trimmingCharacters(in: .whitespaces)
            let srcElev = graph.nodes[edge.sourceID]?.elevation ?? 0
            if let existing = namedLifts[key], existing.elevation <= srcElev {
                continue
            }
            namedLifts[key] = (edge.sourceID, edge.targetID, srcElev, name)
        }
        for (_, info) in namedLifts {
            liftLabelByNodeId[info.sourceId] = info.displayName
            liftLabelByNodeId[info.targetId] = info.displayName
            liftPickerEntries.append((nodeId: info.sourceId, label: info.displayName))
        }

        // Unnamed: stable index by first appearance in `graph.edges` (matches
        // the picker's `Type #N` numbering, which uses the same iteration).
        var unnamedCount = 0
        for edge in graph.edges where edge.kind == .lift {
            if let name = edge.attributes.trailName, !name.isEmpty { continue }
            unnamedCount += 1
            let typeName = edge.attributes.liftType?.displayName ?? "Lift"
            let label = "\(typeName) #\(unnamedCount)"
            // Only stamp if not already labeled (a node could be the source
            // of a named lift AND the target of an unnamed connector lift —
            // named wins because it ran first).
            if liftLabelByNodeId[edge.sourceID] == nil {
                liftLabelByNodeId[edge.sourceID] = label
            }
            if liftLabelByNodeId[edge.targetID] == nil {
                liftLabelByNodeId[edge.targetID] = label
            }
            liftPickerEntries.append((nodeId: edge.sourceID, label: label))
        }

        // ── 3. Fallback run group for junctions — for each non-run-group
        // node, find an incident run edge and key the node to that edge's
        // group. Prefer the highest-elevation adjacent group so a 3-way
        // junction picks the run that "starts" there rather than one that
        // runs through it.
        var fallbackForNode = runGroupForNode
        for edge in graph.edges where edge.kind == .run {
            guard let groupId = edge.attributes.trailGroupId else { continue }
            for nodeId in [edge.sourceID, edge.targetID] {
                guard fallbackForNode[nodeId] == nil else { continue }
                fallbackForNode[nodeId] = groupId
            }
        }

        return NamingCache(
            pickerTitleByGroupId: pickerTitles,
            displayTitleByGroupId: displayTitles,
            bareTitleByGroupId: bareTitles,
            runGroupForNode: runGroupForNode,
            runGroupTopNode: runGroupTop,
            runGroupBottomNode: runGroupBottom,
            liftLabelByNodeId: liftLabelByNodeId,
            fallbackRunGroupForNode: fallbackForNode,
            liftPickerEntries: liftPickerEntries
        )
    }

    /// Strips both the " · <Difficulty>" suffix AND the " · #N"
    /// picker-disambiguation suffix from a picker title, leaving the
    /// bare trail name only. The picker title format is one of:
    ///   "Name"
    ///   "Name · Difficulty"
    ///   "Name · Difficulty · #N"
    ///   "Name · #N"   (rare — only when difficulty is nil)
    ///
    /// `bareName` is what `RouteInstructionBuilder` consumes to merge
    /// consecutive same-trail edges into a single instruction. The
    /// disambig suffix is meaningful in the picker (where two
    /// disconnected chains with the same name need to be told apart)
    /// but **noise in route instructions** (the user doesn't care
    /// that this is "Unnamed Green Trail · #15" vs "· #16" — they're
    /// consecutive segments of the same logical trail).
    ///
    /// Symptom this fixes: a real Whistler route showed three
    /// consecutive "Ski Unnamed Green Trail · #15 / #16 / #9" lines
    /// because the merge condition compared the disambig'd bare names
    /// and they were all different. Strip the disambig too and they
    /// merge to one line.
    private static func stripPickerDecorations(
        from title: String,
        difficulty: RunDifficulty?
    ) -> String {
        var stripped = title

        // Difficulty suffix ("Name · Black" → "Name").
        if let difficulty {
            let diffMarker = " · \(difficulty.displayName)"
            if let range = stripped.range(of: diffMarker) {
                stripped.removeSubrange(range)
            }
        }

        return stripDisambigSuffix(from: stripped)
    }

    /// Drops only the trailing " · #N" picker disambig suffix. Leaves
    /// difficulty in place. This is what `displayTitleByGroupId` uses
    /// to produce "Frontside Run · Black" from "Frontside Run · Black
    /// · #2" — the form every non-picker consumer wants. Difficulty
    /// stays because friend cards / map POIs / meeting-node labels
    /// benefit from seeing it ("on Frontside Run · Black"), unlike
    /// route instructions which already render the difficulty
    /// separately as a parenthetical.
    private static func stripDisambigSuffix(from title: String) -> String {
        guard let hashRange = title.range(of: " · #", options: .backwards) else {
            return title
        }
        let afterHash = title[hashRange.upperBound...]
        guard !afterHash.isEmpty, afterHash.allSatisfy(\.isNumber) else {
            return title
        }
        var stripped = title
        stripped.removeSubrange(hashRange.lowerBound..<stripped.endIndex)
        return stripped
    }
}
