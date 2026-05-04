//
//  ResortPickerSheet.swift
//  PowderMeet
//

import SwiftUI

struct ResortPickerSheet: View {
    @Binding var selectedEntry: ResortEntry?
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
                        ForEach(grouped, id: \.region) { group in
                            sectionHeader(group.region)
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SELECT RESORT")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.accent)
                    .tracking(2)
                Text("\(ResortEntry.catalog.count - ResortEntry.comingSoonIds.count) AVAILABLE · \(ResortEntry.comingSoonIds.count) COMING SOON")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
            )
            .font(.system(size: 11, weight: .medium, design: .monospaced))
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

    private func sectionHeader(_ code: String) -> some View {
        HStack {
            Text(regionLabel(code))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.accent.opacity(0.6))
                .tracking(2)
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

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
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(isSelected ? HUDTheme.accent : HUDTheme.primaryText)
                        .tracking(0.8)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        Text("\(resort.region) · \(resort.country.uppercased())")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(1)

                        if isSelected, resortManager.currentGraph != nil {
                            Text("  \(resortManager.runCount) RUNS · \(resortManager.liftCount) LIFTS")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
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
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
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
        HStack {
            Text("COMING SOON")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.accentAmber.opacity(0.7))
                .tracking(2)
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
        }
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
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.8)
                    .lineLimit(1)
                Text("\(resort.region) · \(resort.country.uppercased()) · NO MAP DATA YET")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(1)
                    .lineLimit(1)
            }

            Spacer()

            Text("SOON")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.accentAmber)
                .tracking(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(HUDTheme.accentAmber.opacity(0.1))
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
