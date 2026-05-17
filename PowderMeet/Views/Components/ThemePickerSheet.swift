//
//  ThemePickerSheet.swift
//  PowderMeet
//
//  Grid-based theme picker. Each cell is a compact column: icon on
//  top, name underneath, two peak/base color swatches under the name.
//  Themes are grouped into three sections — CORE (launch eight),
//  PURE COLORS (single-tone uniques), COMBOS (two-tone uniques) —
//  so the catalog reads as a curated palette rather than a 50-item
//  scroll wall.
//
//  Compared to the previous row-per-theme layout, the grid:
//    • Fits 5 themes per row instead of 1, so the whole catalog is
//      visible with minimal scrolling.
//    • Removes the dead horizontal space that an icon-left/name-right
//      row had (most of the row was empty between the icon and the
//      accent dot on the far edge).
//    • Surfaces the peak/base color split visually so the user knows
//      what they're choosing before tapping.
//
//  Header reads ICON · TEXT · BG (the three axes the theme controls).
//  Search bar filters across all 50 themes; while a search term is
//  active the section grouping collapses into a single result grid.
//

import SwiftUI
import UIKit

struct ThemePickerSheet: View {
    @State private var themeManager = ThemeManager.shared
    @State private var searchText: String = ""

    /// Five columns reads well across iPhone widths (~70pt cell on
    /// the smallest device, ~80pt on Pro Max). LazyVGrid flex-shares
    /// the available width so we don't need device-specific tuning.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 5
    )

    private var activeTheme: ThemeManager.Theme { themeManager.activeTheme }

    /// The device's *system* Light/Dark setting, sourced from the
    /// scene (see `SystemAppearance`) so it is NOT masked by the app's
    /// forced `.preferredColorScheme(.dark)` and updates live when the
    /// user flips Control Center. Each cell renders its icon under this
    /// scheme, so the swatch matches exactly how that icon looks on the
    /// home screen for the user's current iOS setting.
    @State private var appearance = SystemAppearance.shared
    private var systemColorScheme: ColorScheme { appearance.colorScheme }

    /// Resolve a preview imageset to the variant for `scheme`
    /// explicitly, instead of relying on the asset catalog reading the
    /// environment (which the sheet's forced dark scheme would mask).
    private func iconImage(_ name: String, _ scheme: ColorScheme) -> Image {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        if let base = UIImage(named: name),
           let resolved = base.imageAsset?.image(
               with: UITraitCollection(userInterfaceStyle: style)
           ) {
            return Image(uiImage: resolved)
        }
        return Image(name)
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()
            MountainLinesTexture(placement: .panel).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 16)
                    .padding(.bottom, 14)

                searchBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if searchActive {
                            grid(themes: filtered)
                        } else {
                            ForEach(Self.groups) { group in
                                section(
                                    title: group.title,
                                    themes: group.themes
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
        }
        // See ResortPickerSheet: keep the keyboard from reflowing the sheet
        // (and re-rasterizing the MountainLinesTexture) on focus.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Tracks the genuine Control-Center setting so the icon swatches
        // re-render the moment the user flips Light/Dark.
        .background(SceneAppearanceObserver())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("THEME")
                    .hudType(.bodyEmph)
                    .foregroundColor(activeTheme.accentColor)
                    .tracking(2)
                Text("\(ThemeManager.Theme.allCases.count) LOOKS · ICON · TEXT · BG")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(1.5)
            }
            Spacer()
            // DONE — matches the resort / ski picker family. Taps still
            // commit instantly (sheet stays open mid-browse); this just
            // gives the expected top-right dismiss affordance.
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
            TextField("", text: $searchText, prompt: Text("SEARCH THEMES")
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

    // MARK: - Section

    @ViewBuilder
    private func section(title: String, themes: [ThemeManager.Theme]) -> some View {
        if !themes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: title, count: themes.count)
                grid(themes: themes)
            }
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)
            Spacer()
            Text("\(count)")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText.opacity(0.7))
                .tracking(1)
        }
        .padding(.horizontal, 2)
    }

    private func grid(themes: [ThemeManager.Theme]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(themes, id: \.self) { theme in
                cell(theme)
            }
        }
    }

    // MARK: - Cell

    /// One grid cell — icon on top, name, peak/base swatches. Tap
    /// commits the theme. Selected state: tinted ring around the
    /// icon, accent label, faint accent-tinted card background.
    private func cell(_ theme: ThemeManager.Theme) -> some View {
        let isSelected = activeTheme == theme
        let accent = theme.accentColor
        return Button {
            ThemeManager.shared.activeTheme = theme
        } label: {
            VStack(spacing: 6) {
                iconImage(theme.previewImageName, systemColorScheme)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(isSelected ? accent : Color.white.opacity(0.10),
                                    lineWidth: isSelected ? 2 : 1)
                    )

                Text(theme.label)
                    .hudType(.caption)
                    // Render the name in the theme's own typeface so
                    // the picker previews the font, not just the color.
                    .fontDesign(theme.fontDesign)
                    .foregroundColor(isSelected ? accent : HUDTheme.primaryText)
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                swatches(for: theme)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.6) : Color.white.opacity(0.06),
                            lineWidth: isSelected ? 1.2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Two pill-shaped swatches showing the peak + base color pair.
    /// Single-tone themes (peak == base) render as one wider pill so
    /// the cell still telegraphs "one color" cleanly.
    @ViewBuilder
    private func swatches(for theme: ThemeManager.Theme) -> some View {
        if theme.isTwoTone {
            HStack(spacing: 3) {
                swatchPill(theme.peakColor)
                swatchPill(theme.baseColor)
            }
        } else {
            swatchPill(theme.peakColor, wider: true)
        }
    }

    private func swatchPill(_ color: Color, wider: Bool = false) -> some View {
        Capsule()
            .fill(color)
            .frame(width: wider ? 28 : 13, height: 5)
            .overlay(
                Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
    }

    // MARK: - Search / filtering

    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One section per `Theme.Section` (CORE · NATURE · SPECTRUM ·
    /// TECH). `Theme.section` is the single source of truth for
    /// membership; the curated order below only sequences themes
    /// WITHIN their section so kindred looks sit together (Aurora
    /// leads NATURE with its recolors, sunrise beside sunset). Any
    /// section member not listed is appended, so a theme can never
    /// vanish even if this order list drifts.
    private struct ThemeGroup: Identifiable {
        let title: String
        let themes: [ThemeManager.Theme]
        var id: String { title }
    }

    /// Hand-ordered sequence; filtered per section at build time.
    private static let curatedOrder: [ThemeManager.Theme] = [
        // CORE
        .original,
        // NATURE — Aurora + its four recolors lead, then scenic combos
        .aurora, .auroraDawn, .auroraEmber, .auroraIce, .auroraRose,
        .nebula, .stardust, .crevasse, .powder, .moonlit, .tidepool,
        .evergreen, .timber, .fireside, .sunset,
        // SPECTRUM — pure hues in rainbow (hue-angle) order:
        // red → orange → gold → lime → green → cyan → blue → violet
        // → magenta → pink.
        .cherry, .ember, .solar, .olive, .pine, .mintFrost, .emerald,
        .lagoon, .glacier, .bluebird, .sapphire, .lavender, .violet,
        .magenta, .rose,
        // TECH
        .retro, .retroIce, .infrared, .whiteout, .carbon,
    ]

    private static let groups: [ThemeGroup] = {
        ThemeManager.Theme.Section.allCases.compactMap { sec in
            let inSec = Set(ThemeManager.Theme.allCases.filter { $0.section == sec })
            let ordered = curatedOrder.filter { inSec.contains($0) }
            let rest = ThemeManager.Theme.allCases.filter {
                $0.section == sec && !ordered.contains($0)
            }
            let themes = ordered + rest
            return themes.isEmpty
                ? nil
                : ThemeGroup(title: sec.rawValue.uppercased(), themes: themes)
        }
    }()

    private var filtered: [ThemeManager.Theme] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ThemeManager.Theme.allCases }
        return ThemeManager.Theme.allCases.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed) ||
            $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
