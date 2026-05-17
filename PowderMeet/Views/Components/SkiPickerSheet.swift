//
//  SkiPickerSheet.swift
//  PowderMeet
//
//  Search-driven ski picker shown over the Activity → CALIBRATION → MY SKIS
//  row. Mirrors `ResortPickerSheet`'s look so the two pickers feel like one
//  family — same dark mapBackground, same monospaced header, same search
//  bar treatment, same brand-grouped section headers and selection rows.
//
//  Differs from ResortPicker in one spot: a preview `SkiPairView` sits at
//  the top of the sheet and updates as the user taps rows, *before* they
//  commit with DONE. So the user can scan brand options and see how each
//  reads as a topsheet before locking it in.
//

import SwiftUI

struct SkiPickerSheet: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(\.dismiss) private var dismiss

    /// Currently-persisted choice. Used to seed the draft selection when
    /// the sheet opens and to restore on dismiss-without-Save (the user
    /// dismisses with the swipe gesture or tapping outside).
    let currentSelectionId: UUID?

    @State private var allSkis: [SkiCatalogEntry] = []
    @State private var searchText: String = ""
    @State private var loadError: String?
    @State private var isSaving = false

    /// In-flight selection — what the preview ski pair shows. Persisted
    /// only when the user hits DONE.
    @State private var draftSelectionId: UUID?

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()
            MountainLinesTexture(placement: .panel).ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                header
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                // ── Live preview ──
                preview
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                // ── Search bar ──
                searchBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                // ── Catalog list ──
                content
            }
        }
        // See ResortPickerSheet: keep the keyboard from reflowing the sheet
        // (and re-rasterizing the MountainLinesTexture) on focus.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
        .task { await load() }
        .onAppear { draftSelectionId = currentSelectionId }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR SKIS")
                    .hudType(.bodyEmph)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(2)
                Text("\(allSkis.count) MODELS · \(brandCount) BRANDS")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(1.5)
            }
            Spacer()

            // DONE — saves draft and dismisses. Mirrors HUDDoneButton's
            // visual exactly so the two pickers (resort + skis) feel
            // identical; the only difference is a save step before dismiss.
            Button {
                Task { await saveAndDismiss() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().tint(HUDTheme.accent).scaleEffect(0.6)
                    }
                    Text("DONE")
                        .hudType(.section)
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1.5)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(HUDTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Preview

    private var preview: some View {
        SkiPairView(
            topLabel: previewTopLabel,
            bottomLabel: previewBottomLabel,
            entry: previewEntry
        )
    }

    /// Catalog row for the live preview. Drives both the brand topsheet
    /// styling and the silhouette proportions; nil → empty placeholder
    /// pill until the user picks something below.
    private var previewEntry: SkiCatalogEntry? {
        guard let id = draftSelectionId else { return nil }
        return allSkis.first(where: { $0.id == id })
    }

    private var previewTopLabel: String {
        guard let id = draftSelectionId,
              let entry = allSkis.first(where: { $0.id == id }) else {
            return "PICK A SKI"
        }
        return entry.displayName
    }

    private var previewBottomLabel: String {
        guard let id = draftSelectionId,
              let entry = allSkis.first(where: { $0.id == id }),
              let category = entry.category else {
            return "BROWSE BELOW"
        }
        if let waist = allSkis.first(where: { $0.id == id })?.waistWidthMm {
            return "\(category.uppercased()) · \(waist)mm"
        }
        return category.uppercased()
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(HUDTheme.secondaryText)
            TextField("", text: $searchText, prompt: Text("SEARCH BRAND OR MODEL")
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

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: 10) {
                Text("CATALOG UNAVAILABLE")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(1.5)
                Text(loadError)
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button {
                    Task { await load() }
                } label: {
                    Text("RETRY")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1.5)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if allSkis.isEmpty {
            ProgressView()
                .tint(HUDTheme.spinnerInteractive)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(grouped, id: \.brand) { group in
                        HUDSectionHeader(label: group.brand.uppercased(), accent: HUDTheme.accent)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 8)
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    }
                    Spacer().frame(height: 24)
                }
            }
        }
    }

    private func row(_ entry: SkiCatalogEntry) -> some View {
        let isSelected = entry.id == draftSelectionId
        return Button {
            // Tap updates the draft only — preview at top reflects the
            // change, but persistence waits for DONE.
            draftSelectionId = entry.id
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(isSelected ? HUDTheme.accent : HUDTheme.cardBorder)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.model.uppercased())
                        .hudType(.section)
                        .foregroundColor(isSelected ? HUDTheme.accent : HUDTheme.primaryText)
                        .tracking(0.8)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        if let cat = entry.category {
                            Text(cat.uppercased())
                                .hudType(.caption)
                                .foregroundColor(HUDTheme.secondaryText)
                                .tracking(1)
                        }
                        if let waist = entry.waistWidthMm {
                            Text((entry.category != nil ? "  " : "") + "\(waist)mm WAIST")
                                .hudType(.caption)
                                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                    .lineLimit(1)
                }

                Spacer()

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

    // MARK: - Filtering

    /// Filtered + brand-grouped list. Empty query → every entry. Match
    /// is case-insensitive against brand or model. Brands appear in the
    /// catalog's natural order (already brand-asc from the fetch).
    private var grouped: [BrandGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [SkiCatalogEntry]
        if trimmed.isEmpty {
            filtered = allSkis
        } else {
            filtered = allSkis.filter {
                $0.brand.localizedCaseInsensitiveContains(trimmed) ||
                $0.model.localizedCaseInsensitiveContains(trimmed)
            }
        }
        var seen: [String: [SkiCatalogEntry]] = [:]
        var order: [String] = []
        for entry in filtered {
            if seen[entry.brand] == nil { order.append(entry.brand) }
            seen[entry.brand, default: []].append(entry)
        }
        return order.map { BrandGroup(brand: $0, entries: seen[$0] ?? []) }
    }

    private var brandCount: Int {
        Set(allSkis.map(\.brand)).count
    }

    private struct BrandGroup {
        let brand: String
        let entries: [SkiCatalogEntry]
    }

    // MARK: - Network

    private func load() async {
        loadError = nil
        do {
            allSkis = try await supabase.fetchSkisCatalog()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveAndDismiss() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await supabase.setPreferredSkiId(draftSelectionId)
            dismiss()
        } catch {
            loadError = "Couldn\'t save: \(error.localizedDescription)"
        }
    }
}
