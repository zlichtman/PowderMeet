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

    /// Filter passed through search box, then partitioned active / coming-soon.
    private var filtered: [ResortEntry] {
        searchText.isEmpty
            ? ResortEntry.catalog
            : ResortEntry.catalog.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.region.localizedCaseInsensitiveContains(searchText)
            }
    }

    /// Active resorts grouped by region — the main list.
    private var grouped: [(region: String, resorts: [ResortEntry])] {
        let active = filtered.filter { !$0.isComingSoon }
        let byRegion = Dictionary(grouping: active, by: \.region)
        return ResortEntry.regionOrder.compactMap { r in
            guard let res = byRegion[r], !res.isEmpty else { return nil }
            return (region: r, resorts: res.sorted { $0.name < $1.name })
        }
    }

    /// "Coming soon" tail — resorts whose OSM bbox has no piste/aerialway
    /// data today. Surfaced under their own header at the bottom so they
    /// aren't hidden, but they don't pollute the main browsing list.
    private var comingSoon: [ResortEntry] {
        filtered.filter { $0.isComingSoon }.sorted { $0.name < $1.name }
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
                            HUDSectionHeader(label: regionLabel(group.region), accent: HUDTheme.accent)
                                .padding(.horizontal, 20)
                                .padding(.top, 18)
                                .padding(.bottom, 8)
                            ForEach(group.resorts) { resort in
                                resortRow(resort)
                            }
                        }
                        if !comingSoon.isEmpty {
                            comingSoonHeader
                            ForEach(comingSoon) { resort in
                                comingSoonRow(resort)
                            }
                        }
                        Spacer().frame(height: 24)
                    }
                }
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
                Text("\(ResortEntry.catalog.count - ResortEntry.comingSoonIds.count) AVAILABLE · \(ResortEntry.comingSoonIds.count) COMING SOON")
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

                        if isSelected, resortManager.currentGraph != nil {
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
            .background(isSelected ? HUDTheme.accent.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Coming Soon

    private var comingSoonHeader: some View {
        HUDSectionHeader(label: "COMING SOON")
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 4)
    }

    /// Same row silhouette as `resortRow` but visually de-emphasized and
    /// non-tappable. No selection animation; tapping is disabled at the
    /// `Button` level so VoiceOver also reports the row as inactive.
    private func comingSoonRow(_ resort: ResortEntry) -> some View {
        HStack(spacing: 12) {
            Circle()
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(resort.name.uppercased())
                    .hudType(.section)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.8)
                    .lineLimit(1)
                Text("\(resort.region) · \(resort.country.uppercased()) · NO MAP DATA YET")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(1)
                    .lineLimit(1)
            }

            Spacer()

            Text("SOON")
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(HUDTheme.secondaryText.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .opacity(0.65)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resort.name), coming soon. No map data available yet.")
    }

    // MARK: - Region Labels

    private func regionLabel(_ code: String) -> String {
        switch code {
        case "AK": return "ALASKA"
        case "CA": return "CALIFORNIA"
        case "CO": return "COLORADO"
        case "ID": return "IDAHO"
        case "IN": return "INDIANA"
        case "MA": return "MASSACHUSETTS"
        case "ME": return "MAINE"
        case "MI": return "MICHIGAN"
        case "MN": return "MINNESOTA"
        case "MO": return "MISSOURI"
        case "MT": return "MONTANA"
        case "NH": return "NEW HAMPSHIRE"
        case "NM": return "NEW MEXICO"
        case "NY": return "NEW YORK"
        case "OH": return "OHIO"
        case "OR": return "OREGON"
        case "PA": return "PENNSYLVANIA"
        case "UT": return "UTAH"
        case "VT": return "VERMONT"
        case "WA": return "WASHINGTON"
        case "WI": return "WISCONSIN"
        case "WV": return "WEST VIRGINIA"
        case "WY": return "WYOMING"
        case "AB": return "ALBERTA"
        case "BC": return "BRITISH COLUMBIA"
        case "ON": return "ONTARIO"
        case "QC": return "QUÉBEC"
        case "JP": return "JAPAN"
        case "AU": return "AUSTRALIA"
        case "NZ": return "NEW ZEALAND"
        case "KR": return "SOUTH KOREA"
        case "CN": return "CHINA"
        case "CL": return "CHILE"
        case "AT": return "AUSTRIA"
        case "CH": return "SWITZERLAND"
        case "FR": return "FRANCE"
        case "IT": return "ITALY"
        case "AD": return "ANDORRA"
        default:   return code
        }
    }
}
