//
//  ResortPickerSheet.swift
//  PowderMeet
//

import SwiftUI

struct ResortPickerSheet: View {
    @Binding var selectedEntry: ResortEntry?
    /// Resorts whose bounding box contains the user's GPS, sorted nearest-
    /// first. When two or more match (Vail/Beaver Creek, Park City/Deer
    /// Valley), `ContentCoordinator.bootstrap` populates this and surfaces
    /// the picker so the user resolves the ambiguity rather than the app
    /// silently loading a wrong-resort graph. Empty in the normal case.
    var atYourLocationCandidates: [ResortEntry] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(ResortDataManager.self) private var resortManager
    @State private var searchText = ""

    /// The full catalog remains selectable; loading reports actual data failures.
    private var filtered: [ResortEntry] {
        ResortEntry.search(searchText)
    }

    /// All matching mountains grouped by region.
    private var grouped: [(region: String, resorts: [ResortEntry])] {
        let byRegion = Dictionary(grouping: filtered, by: \.region)
        let regionOrder = ResortEntry.regionOrder + byRegion.keys
            .filter { !ResortEntry.regionOrder.contains($0) }.sorted()
        return regionOrder.compactMap { r in
            guard let res = byRegion[r], !res.isEmpty else { return nil }
            return (region: r, resorts: res.sorted { $0.name < $1.name })
        }
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()
            MountainLinesTexture(placement: .panel).ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                header
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                // ── Search bar ──
                searchBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                // ── Resort list ──
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // "AT YOUR LOCATION" section — only renders when
                        // ContentCoordinator detected ≥2 catalog bboxes
                        // containing the user's GPS. Suppressed while the
                        // user is searching so the section doesn't ghost
                        // a typed query.
                        if !atYourLocationCandidates.isEmpty, searchText.isEmpty {
                            HUDSectionHeader(label: "AT YOUR LOCATION", accent: HUDTheme.accentAmber)
                                .padding(.horizontal, 20)
                                .padding(.top, 18)
                                .padding(.bottom, 8)
                            ForEach(atYourLocationCandidates) { resort in
                                resortRow(resort)
                            }
                            // Visual gap before the regional groupings start.
                            Spacer().frame(height: 8)
                        }
                        ForEach(grouped, id: \.region) { group in
                            HUDSectionHeader(label: ResortEntry.regionLabel(group.region), accent: HUDTheme.accent)
                                .padding(.horizontal, 20)
                                .padding(.top, 18)
                                .padding(.bottom, 8)
                            ForEach(group.resorts) { resort in
                                resortRow(resort)
                            }
                        }
                        if filtered.isEmpty {
                            VStack(spacing: 8) {
                                Text("NO MOUNTAINS FOUND")
                                    .hudType(.section).foregroundStyle(HUDTheme.primaryText)
                                Text("Try a mountain name, region, country, or pass.")
                                    .hudType(.body).foregroundStyle(HUDTheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity).padding(24)
                        }
                        Spacer().frame(height: 24)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        // The search field sits directly under the header — the keyboard
        // never overlaps it. Opting out of keyboard avoidance stops SwiftUI
        // from reflowing the whole sheet (and re-rasterizing the 2048²
        // MountainLinesTexture behind it) on every frame of the keyboard
        // animation — the "content rises + lags" regression from 055dc1e.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SELECT RESORT")
                    .hudType(.bodyEmph)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(2)
                Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "\(ResortEntry.catalog.count) MOUNTAINS"
                     : "\(filtered.count) MATCHES")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(1.5)
            }
            Spacer()
            HUDDoneButton()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(HUDTheme.secondaryText)
            TextField("", text: $searchText, prompt: Text("SEARCH RESORTS")
                .font(HUDTheme.font(.body))
                .foregroundColor(HUDTheme.textTertiary)
            )
            .hudType(.body)
            .foregroundColor(HUDTheme.primaryText)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            Button { searchText = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(HUDTheme.secondaryText)
                    .minimumInteractiveTarget()
            }
            .opacity(searchText.isEmpty ? 0 : 1)
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(HUDTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
        .animation(nil, value: searchText)
    }

    // MARK: - Section Header

    // MARK: - Resort Row

    private func resortRow(_ resort: ResortEntry) -> some View {
        let isSelected = resort.id == selectedEntry?.id

        return Button {
            selectedEntry = resort
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(isSelected ? HUDTheme.accent : HUDTheme.cardBorder)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(resort.name.uppercased())
                        .hudType(.section)
                        .foregroundColor(isSelected ? HUDTheme.accent : HUDTheme.primaryText)
                        .tracking(0.8)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        Text("\(resort.region) · \(resort.country.uppercased())")
                            .hudType(.caption)
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(1)

                        if isSelected, resortManager.currentGraph?.resortID == resort.id {
                            Text("  \(resortManager.runCount) RUNS · \(resortManager.liftCount) LIFTS")
                                .hudType(.caption)
                                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                    .lineLimit(1)
                }

                Spacer()

                // Pass badges (all resorts)
                HStack(spacing: 4) {
                    ForEach(Array(resort.passProducts).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { pass in
                        Text(pass.rawValue.uppercased())
                            .hudType(.caption)
                            .foregroundColor(pass == .epic ? HUDTheme.accentCyan : HUDTheme.accentAmber)
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                (pass == .epic ? HUDTheme.accentCyan : HUDTheme.accentAmber).opacity(0.1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(HUDTheme.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(isSelected ? HUDTheme.accent.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(resort.name), \(resort.region), \(resort.passLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}
