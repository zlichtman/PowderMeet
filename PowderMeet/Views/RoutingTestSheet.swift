//
//  RoutingTestSheet.swift
//  PowderMeet
//
//  Location picker: set YOUR LOCATION on the resort map.
//  Lists all named trails and lifts from the graph.
//

import SwiftUI
import CoreLocation

struct RoutingTestSheet: View {
    @Environment(ResortDataManager.self) private var resortManager
    @Environment(\.dismiss) private var dismiss

    @Binding var testMyNodeId: String?

    @State private var selectedId: String?
    @State private var searchText = ""
    @State private var filter: FilterKind = .all
    @State private var entries: [PickerEntry] = []

    enum FilterKind: String, CaseIterable {
        case all = "ALL"
        case trails = "TRAILS"
        case lifts = "LIFTS"
    }

    // MARK: - Picker Entry

    struct PickerEntry: Identifiable {
        let id: String          // unique ID (uses index suffix to avoid duplicates)
        let nodeId: String      // graph node ID to snap to
        /// Run grouping id when `kind == .trail` (matches map GeoJSON).
        let trailGroupId: String?
        let name: String
        let kind: Kind
        let difficulty: RunDifficulty?
        let elevation: Double

        enum Kind { case trail, lift }
    }

    // MARK: - Build Entries

    /// A run is "valid" (skiable + useful for testing) when it:
    ///   1. has a name (unnamed service roads and cat tracks fall out),
    ///   2. has a difficulty classification,
    ///   3. has enough length to be worth routing through (≥ 60m), and
    ///   4. is lift-served — either endpoint of the chain must touch a lift
    ///      edge, or a node in the chain must be a lift top/base.
    /// Everything else was surfacing as nonsense rows ("a trail that goes
    /// nowhere") and the solver would refuse to route from those picks.
    private static let minRunLengthMeters: Double = 60

    private func isLiftServed(_ summary: RunTrailGroupSummary, graph: MountainGraph) -> Bool {
        let chainNodes = summary.runNodeIds
        for nodeId in chainNodes {
            if let node = graph.nodes[nodeId],
               node.kind == .liftBase || node.kind == .liftTop {
                return true
            }
            let touchesLift = graph.edges.contains { e in
                e.kind == .lift && (e.sourceID == nodeId || e.targetID == nodeId)
            }
            if touchesLift { return true }
        }
        return false
    }

    private func buildEntries() {
        guard let graph = resortManager.currentGraph else { return }
        let naming = MountainNaming(graph)
        var result: [PickerEntry] = []

        // ── Trails: one row per valid run chain, placed at the TOP of the
        // chain (that's where a skier realistically starts). Filters out
        // unnamed / unclassified / ultra-short / non-lift-served segments so
        // picking a row always yields a routable test location. Labels go
        // through `MountainNaming.nodeLabel(.canonical)` so the row text
        // matches every other surface in the app for the same node id.
        let summaries = graph.runTrailGroupSummaries()
        for s in summaries {
            let rawName = s.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawName.isEmpty else { continue }
            guard s.difficulty != nil else { continue }

            let totalMeters = s.orderedRunEdges.reduce(0.0) { $0 + $1.attributes.lengthMeters }
            guard totalMeters >= Self.minRunLengthMeters else { continue }

            guard isLiftServed(s, graph: graph) else { continue }

            let topElev = graph.nodes[s.topNodeId]?.elevation ?? 0
            // Picker rows want the disambig'd form ("· #N") so two
            // disconnected groups with the same name+difficulty are
            // distinguishable in the list. `pickerRowTitle` is the
            // ONLY API that returns the disambig'd version — every
            // other surface uses display title (no disambig) so
            // friend cards / meeting-node labels / map POIs / route
            // instructions read clean.
            let label = naming.pickerRowTitle(forGroupId: s.trailGroupId)
                ?? rawName
            result.append(PickerEntry(
                id: "trail_\(s.trailGroupId)",
                nodeId: s.topNodeId,
                trailGroupId: s.trailGroupId,
                name: label,
                kind: .trail,
                difficulty: s.difficulty,
                elevation: topElev
            ))
        }

        // ── Lifts: one row per unique lift identity. `MountainNaming`
        // already did the dedupe (lowest-base wins per normalized name)
        // and the stable "<Type> #N" numbering for unnamed lifts.
        for liftEntry in naming.liftPickerEntries {
            result.append(PickerEntry(
                id: "lift_\(liftEntry.nodeId)",
                nodeId: liftEntry.nodeId,
                trailGroupId: nil,
                name: liftEntry.label,
                kind: .lift,
                difficulty: nil,
                elevation: liftEntry.elevation
            ))
        }

        // Sort alphabetically
        entries = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Filtered

    private var filtered: [PickerEntry] {
        var result = entries
        switch filter {
        case .all: break
        case .trails: result = result.filter { $0.kind == .trail }
        case .lifts: result = result.filter { $0.kind == .lift }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) }
        }
        return result
    }

    // MARK: - Resolved Node

    /// The currently selected entry (if any)
    private var selectedEntry: PickerEntry? {
        guard let id = selectedId else { return nil }
        return entries.first { $0.nodeId == id }
    }

    /// Canonical graph node for the pick — one placement per run (chain bottom).
    private var resolvedNodeId: String? {
        selectedId
    }

    /// Matches list rows / profile HUD via `MountainNaming` —
    /// the single source of truth for node labels across the app.
    /// `.withChainPosition` adds TOP/BOTTOM (or BASE/TOP for lifts)
    /// so the selected-row HUD reflects which end of the chain the
    /// pick lands on.
    private var selectionDisplayTitle: String {
        guard let id = resolvedNodeId, let graph = resortManager.currentGraph else { return "" }
        return MountainNaming(graph).nodeLabel(id, style: .withChainPosition)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                HStack {
                    Text("SET YOUR LOCATION")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // ── Current selection ──
                    if let id = resolvedNodeId, let graph = resortManager.currentGraph {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(HUDTheme.accent)
                                Text(selectionDisplayTitle.uppercased())
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(HUDTheme.primaryText)
                                    .tracking(0.5)
                                    .lineLimit(1)
                                Spacer()
                                Text(UnitFormatter.elevation(graph.nodes[id]?.elevation ?? 0))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(HUDTheme.secondaryText)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                        }
                        .background(HUDTheme.accent.opacity(0.1))
                    }

                    #if DEBUG
                    // ── Diagnostics bar (dev only) ──
                    if let graph = resortManager.currentGraph {
                        diagnosticsBar(graph)
                    }
                    #endif

                    // ── Filter tabs ──
                    HStack(spacing: 0) {
                        ForEach(FilterKind.allCases, id: \.self) { kind in
                            Button {
                                filter = kind
                            } label: {
                                Text(kind.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(filter == kind ? .white : HUDTheme.secondaryText.opacity(0.5))
                                    .tracking(1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .background(filter == kind ? HUDTheme.accent : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(HUDTheme.inputBackground.opacity(0.3))

                    // ── Search ──
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                        TextField("", text: $searchText,
                                  prompt: Text("SEARCH").foregroundColor(HUDTheme.secondaryText.opacity(0.3)))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.primaryText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(HUDTheme.inputBackground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // ── Count ──
                    Text("\(filtered.count) \(filter == .lifts ? "LIFTS" : filter == .trails ? "TRAILS" : "TRAILS & LIFTS")")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                    // ── List ──
                    List(filtered) { entry in
                        // Strict 1:1 match on the entry's canonical `nodeId`.
                        // Loosening this to include `topNodeId` / `bottomNodeId`
                        // highlights every trail that shares an endpoint (common
                        // at the base of a big lift), producing the "multi-select"
                        // bug. External seeds (e.g. `testMyNodeId` pointing at a
                        // trail's top node) are normalized in `onAppear` below.
                        let isSelected = selectedId == entry.nodeId

                        Button {
                            selectedId = entry.nodeId
                        } label: {
                            HStack(spacing: 8) {
                                // Icon
                                if entry.kind == .lift {
                                    Image(systemName: "cablecar.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(HUDTheme.accentAmber)
                                        .frame(width: 14)
                                } else if let diff = entry.difficulty {
                                    Image(systemName: diff.icon)
                                        .font(.system(size: 9))
                                        .foregroundColor(HUDTheme.color(for: diff))
                                        .frame(width: 14)
                                } else {
                                    Circle()
                                        .fill(HUDTheme.accentGreen)
                                        .frame(width: 8, height: 8)
                                        .frame(width: 14)
                                }

                                Text(entry.name.uppercased())
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .monospaced))
                                    .foregroundColor(isSelected ? HUDTheme.accent : HUDTheme.primaryText)
                                    .tracking(0.3)
                                    .lineLimit(1)

                                Spacer()

                                Text(UnitFormatter.elevation(entry.elevation))
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundColor(HUDTheme.secondaryText)

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(HUDTheme.accent)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(isSelected ? HUDTheme.accent.opacity(0.08) : Color.clear)
                        .listRowSeparatorTint(HUDTheme.cardBorder.opacity(0.3))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)

                    // ── Bottom buttons ──
                    VStack(spacing: 8) {
                        if let nodeId = resolvedNodeId {
                            Button {
                                testMyNodeId = nodeId
                                dismiss()
                            } label: {
                                Text("SET LOCATION")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .tracking(2)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(HUDTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("SELECT A TRAIL OR LIFT")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                                .tracking(1)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(HUDTheme.cardBorder.opacity(0.3), lineWidth: 0.5)
                                )
                        }

                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(HUDTheme.mapBackground)
                }
            }
        .preferredColorScheme(.dark)
        .onAppear {
            buildEntries()
            selectedId = canonicalSelectedId(for: testMyNodeId)
        }
        // If the graph finishes loading *after* the sheet appeared — or if the
        // user changed resorts while this sheet was open — rebuild entries so
        // the list isn't stuck empty. Use the fingerprint, not node count:
        // enrichment can change run/lift attributes (open/closed, grooming,
        // names) without changing topology, and we want those reflected.
        .onChange(of: resortManager.currentGraph?.fingerprint) { _, _ in
            buildEntries()
            selectedId = canonicalSelectedId(for: testMyNodeId)
        }
    }

    /// Maps an arbitrary graph node id to the unique entry it belongs to (if
    /// any), returning that entry's canonical `nodeId`. Seeding the picker
    /// with any node that lives on a run chain should still highlight that
    /// run's single row.
    private func canonicalSelectedId(for seed: String?) -> String? {
        guard let seed, let graph = resortManager.currentGraph else { return nil }
        if entries.contains(where: { $0.nodeId == seed }) { return seed }
        if let summary = graph.runTrailGroupSummary(containingRunNode: seed),
           let entry = entries.first(where: { $0.trailGroupId == summary.trailGroupId }) {
            return entry.nodeId
        }
        return nil
    }

    // MARK: - Diagnostics Bar

    private func diagnosticsBar(_ graph: MountainGraph) -> some View {
        // Diagnostics intentionally read live graph state (post-enrichment),
        // not the frozen snapshot — this is the dev view for inspecting
        // exactly what's currently loaded. Routing through the shared
        // stats builder so the implementation matches the headline.
        let liveStats = graph.makeResortStats(resortId: resortManager.currentEntry?.id ?? "", snapshotDate: "")
        let runs = liveStats.namedRunsUnique
        let lifts = liveStats.namedLiftsUnique
        let nodeCount = graph.nodes.count
        let edgeCount = graph.edges.count
        let openCount = graph.edges.filter { $0.attributes.isOpen }.count
        let components = countComponents(graph)
        let sinks = countSinks(graph)

        return HStack(spacing: 4) {
            diagCell("\(runs)", "RUNS", .primary)
            diagCell("\(lifts)", "LIFTS", .primary)
            diagCell("\(nodeCount)", "NODES", .secondary)
            diagCell("\(edgeCount)", "EDGES", .secondary)
            diagCell("\(openCount)", "OPEN", .secondary)
            diagCell("\(components)", "COMP", components == 1 ? .good : .warn)
            diagCell("\(sinks)", "SINKS", sinks == 0 ? .good : .warn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(HUDTheme.cardBackground.opacity(0.6))
    }

    private enum DiagStyle { case primary, secondary, good, warn }

    private func diagCell(_ value: String, _ label: String, _ style: DiagStyle) -> some View {
        let valueColor: Color
        switch style {
        case .primary: valueColor = HUDTheme.primaryText
        case .secondary: valueColor = HUDTheme.secondaryText
        case .good: valueColor = HUDTheme.accentGreen
        case .warn: valueColor = HUDTheme.accentAmber
        }

        return VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
            Text(label)
                .font(.system(size: 6, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                .tracking(0.3)
        }
        .frame(maxWidth: .infinity)
    }

    private func countComponents(_ graph: MountainGraph) -> Int {
        var adj: [String: [String]] = [:]
        for edge in graph.edges {
            adj[edge.sourceID, default: []].append(edge.targetID)
            adj[edge.targetID, default: []].append(edge.sourceID)
        }
        var visited = Set<String>()
        var count = 0
        for nodeId in graph.nodes.keys where !visited.contains(nodeId) {
            count += 1
            var queue = [nodeId]
            visited.insert(nodeId)
            while !queue.isEmpty {
                let current = queue.removeFirst()
                for neighbor in adj[current] ?? [] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }
        return count
    }

    private func countSinks(_ graph: MountainGraph) -> Int {
        var outCount: [String: Int] = [:]
        for edge in graph.edges where edge.attributes.isOpen {
            outCount[edge.sourceID, default: 0] += 1
        }
        return graph.nodes.keys.filter { outCount[$0, default: 0] == 0 }.count
    }
}
