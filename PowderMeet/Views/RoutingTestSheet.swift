//
//  RoutingTestSheet.swift
//  PowderMeet
//
//  Demo Location picker — pick a graph node as your "current location"
//  for TestFlight demos. One combined list of trails + lifts sorted
//  peak → bottom by elevation. Visual treatment mirrors
//  `ResortPickerSheet` so the two pickers feel like a pair.
//
//  DEBUG-only: an EXPORT GRAPH FIXTURE button at the bottom drives the
//  golden-fixture regression workflow documented in CLAUDE.md.
//

import SwiftUI
import CoreLocation

struct RoutingTestSheet: View {
    @Environment(ResortDataManager.self) private var resortManager
    @Environment(\.dismiss) private var dismiss

    @Binding var testMyNodeId: String?

    /// Unique row id of the picked entry — `entry.id`, NOT `entry.nodeId`.
    /// Two trails can legitimately share a top node (both starting from
    /// the same lift top), so keying selection on the graph node id
    /// would highlight every row that shares that node — the
    /// "selecting one selects multiple" bug. Row id is unique by
    /// construction (`"trail_<trailGroupId>"` / `"lift_<nodeId>"`).
    @State private var selectedRowId: String?
    @State private var searchText = ""
    @State private var entries: [PickerEntry] = []

    // MARK: - Picker entry

    struct PickerEntry: Identifiable {
        let id: String          // unique id (de-duped via index suffix when needed)
        let nodeId: String      // graph node id to snap to
        let trailGroupId: String?
        let name: String
        let kind: Kind
        let difficulty: RunDifficulty?
        let elevation: Double

        enum Kind { case trail, lift }
    }

    // MARK: - Build entries

    /// A run is "valid" when it has a name + difficulty + ≥ 60 m length
    /// + lift-served. Below this bar the row points at terrain the
    /// solver refuses to route through, so it's dead weight in the
    /// picker.
    private static let minRunLengthMeters: Double = 60

    private func isLiftServed(_ summary: RunTrailGroupSummary, graph: MountainGraph) -> Bool {
        for nodeId in summary.runNodeIds {
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

        // Trails — one row per valid run chain at the chain's TOP.
        // Disambig'd label so two same-name groups stay distinguishable.
        let summaries = graph.runTrailGroupSummaries()
        for s in summaries {
            let rawName = s.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawName.isEmpty else { continue }
            guard s.difficulty != nil else { continue }

            let totalMeters = s.orderedRunEdges.reduce(0.0) { $0 + $1.attributes.lengthMeters }
            guard totalMeters >= Self.minRunLengthMeters else { continue }
            guard isLiftServed(s, graph: graph) else { continue }

            let topElev = graph.nodes[s.topNodeId]?.elevation ?? 0
            let label = naming.pickerRowTitle(forGroupId: s.trailGroupId) ?? rawName
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

        // Lifts — one row per unique lift identity. MountainNaming
        // already de-duped + numbered.
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

        // Defensive dedupe by row id. SwiftUI `ForEach` with duplicate
        // `Identifiable.id`s logs a warning and renders glitchy /
        // "ghost" rows that look like blank separators in the list.
        // The named/unnamed lift loops in MountainNaming should both
        // emit unique node ids, but if anything upstream regresses we
        // want the picker to stay clean.
        var seenIds: Set<String> = []
        let deduped = result.filter { entry in
            guard !seenIds.contains(entry.id) else { return false }
            seenIds.insert(entry.id)
            return true
        }

        // Peak → bottom: ties break by name so the order is stable
        // across rebuilds at the same fingerprint.
        entries = deduped.sorted { lhs, rhs in
            if lhs.elevation != rhs.elevation { return lhs.elevation > rhs.elevation }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Filtered

    private var filtered: [PickerEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                header
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                // ── Search ──
                searchBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                // ── Combined list (peak → bottom) ──
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            row(entry)
                        }
                        Spacer().frame(height: 96)  // keep last row above bottom CTA
                    }
                }
            }

            // ── Sticky bottom CTA ──
            VStack {
                Spacer()
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            buildEntries()
            selectedRowId = canonicalSelectedRowId(for: testMyNodeId)
        }
        // Resort change / enrichment finishing while sheet is open: rebuild
        // off the fingerprint (catches both topology and attribute changes).
        .onChange(of: resortManager.currentGraph?.fingerprint) { _, _ in
            buildEntries()
            selectedRowId = canonicalSelectedRowId(for: testMyNodeId)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("DEMO LOCATION")
                    .hudType(.bodyEmph)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(2)
                Text("\(filtered.count) TRAILS & LIFTS · PEAK → BOTTOM")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(1.5)
            }
            Spacer()
            HUDDoneButton()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(HUDTheme.secondaryText)
            TextField("", text: $searchText, prompt: Text("SEARCH TRAILS & LIFTS")
                .font(HUDTheme.font(.body))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
            )
            .hudType(.body)
            .foregroundColor(HUDTheme.primaryText)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            Button { searchText = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(HUDTheme.secondaryText)
            }
            .opacity(searchText.isEmpty ? 0 : 1)
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(HUDTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
        .animation(nil, value: searchText)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ entry: PickerEntry) -> some View {
        let isSelected = selectedRowId == entry.id
        Button {
            selectedRowId = entry.id
        } label: {
            HStack(spacing: 12) {
                // Type / difficulty icon — same width regardless of kind
                // so the name column lines up across the whole list.
                ZStack {
                    if entry.kind == .lift {
                        Image(systemName: "cablecar.fill")
                            .font(.system(size: 11))
                            .foregroundColor(HUDTheme.accentAmber)
                    } else if let diff = entry.difficulty {
                        Image(systemName: diff.icon)
                            .font(.system(size: 11))
                            .foregroundColor(HUDTheme.color(for: diff))
                    } else {
                        Circle()
                            .fill(HUDTheme.accentGreen)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 16, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name.uppercased())
                        .hudType(.section)
                        .foregroundColor(isSelected ? HUDTheme.accent : HUDTheme.primaryText)
                        .tracking(0.8)
                        .lineLimit(1)
                    Text(subtitle(for: entry))
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                        .lineLimit(1)
                }

                Spacer()

                Text(UnitFormatter.elevation(entry.elevation))
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(HUDTheme.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isSelected ? HUDTheme.accent.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Subtitle copy on each row — the type label, plus difficulty
    /// where it applies. Keeps the row to two clean lines.
    private func subtitle(for entry: PickerEntry) -> String {
        switch entry.kind {
        case .lift:
            return "LIFT"
        case .trail:
            if let d = entry.difficulty {
                return "TRAIL · \(d.rawValue.uppercased())"
            }
            return "TRAIL"
        }
    }

    // MARK: - Bottom CTA

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Subtle gradient so the sticky bar reads as separate from
            // the scroll content underneath without a hard divider.
            LinearGradient(
                colors: [HUDTheme.mapBackground.opacity(0), HUDTheme.mapBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 16)
            .allowsHitTesting(false)

            VStack(spacing: 8) {
                if let rowId = selectedRowId,
                   let entry = entries.first(where: { $0.id == rowId }) {
                    Button {
                        // entry.nodeId is the graph node we want the
                        // solver to treat as the user's position.
                        // Distinct from entry.id (which is the unique
                        // row id we use for selection state).
                        testMyNodeId = entry.nodeId
                        dismiss()
                    } label: {
                        Text("SET LOCATION")
                            .hudType(.bodyEmph)
                            .foregroundColor(.white)
                            .tracking(2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(HUDTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("PICK A TRAIL OR LIFT")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                        .tracking(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
                        )
                }

                #if DEBUG
                if let graph = resortManager.currentGraph {
                    exportFixtureButton(graph: graph)
                }
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .background(HUDTheme.mapBackground)
        }
    }

    // MARK: - Selection canonicalization

    /// Map an arbitrary seed graph-node id to the picker ROW id of the
    /// entry that owns it. Two cases handled:
    ///   1. seed is the canonical entry node (chain top for trails,
    ///      base for lifts) — return that entry's row id directly.
    ///   2. seed is an interior node of a trail chain — find the trail
    ///      group it belongs to, return that row's id.
    /// Returns the FIRST matching entry's row id when multiple entries
    /// share the same nodeId (e.g. two trails starting at the same lift
    /// top); the user can pick a different one explicitly if they meant
    /// the other.
    private func canonicalSelectedRowId(for seed: String?) -> String? {
        guard let seed, let graph = resortManager.currentGraph else { return nil }
        if let entry = entries.first(where: { $0.nodeId == seed }) {
            return entry.id
        }
        if let summary = graph.runTrailGroupSummary(containingRunNode: seed),
           let entry = entries.first(where: { $0.trailGroupId == summary.trailGroupId }) {
            return entry.id
        }
        return nil
    }

    // MARK: - Export graph fixture (DEBUG)
    //
    // Drives the per-resort golden-graph regression workflow documented
    // in CLAUDE.md "Future work → Test infrastructure". Visit each
    // catalog resort, tap this button, copy the resulting JSON out of
    // the simulator's Documents directory into
    // `PowderMeetTests/Fixtures/<resortId>.json`, and add a
    // parameterised test that reloads the fixture and asserts no drift.

    @State private var fixtureExportMessage: String?

    @ViewBuilder
    private func exportFixtureButton(graph: MountainGraph) -> some View {
        let resortId = resortManager.currentEntry?.id ?? "unknown"
        VStack(spacing: 4) {
            Button {
                exportGraphFixture(graph: graph, resortId: resortId)
            } label: {
                Text("EXPORT GRAPH FIXTURE")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.accent.opacity(0.7))
                    .tracking(1.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(HUDTheme.accent.opacity(0.35), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            if let msg = fixtureExportMessage {
                Text(msg)
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func exportGraphFixture(graph: MountainGraph, resortId: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(graph)
            let dir = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let url = dir.appendingPathComponent("\(resortId)-fixture.json")
            try data.write(to: url, options: .atomic)
            let kb = data.count / 1024
            fixtureExportMessage = "WROTE \(resortId)-fixture.json (\(kb) KB) — copy from simulator Documents/"
        } catch {
            fixtureExportMessage = "EXPORT FAILED: \(error.localizedDescription)"
        }
    }
}
