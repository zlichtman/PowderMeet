import SwiftUI

/// Picks the skis by name: the live preview pair with "match theme" beside
/// it, the search field, then the list whose first row is PowderMeet · Custom
/// and then every catalog ski, one glass card per brand. A catalog ski is
/// drawn with its own topsheet (the drawn one when the brand's image is off or
/// missing); custom gear with the PowderMeet ski. There is no skin choice. It edits the gear draft
/// directly, so a pick fills the routing fields (type and waist) the Gear page
/// shows underneath; saving is the caller's.
struct SkiPickerSheet: View {
    @Binding var draft: GearDraft
    @State private var searchText = ""

    /// Every search word must appear in the brand, model or category.
    private var filtered: [(brand: String, models: [SkiModel])] {
        let terms = Self.fold(searchText).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return SkiCatalog.brands }
        return SkiCatalog.brands.compactMap { group in
            let models = group.models.filter { model in
                let searchable = Self.fold("\(model.displayName) \(model.category.label)")
                return terms.allSatisfy { searchable.contains($0) }
            }
            return models.isEmpty ? nil : (brand: group.brand, models: models)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GlassLayout.sectionGap) {
                preview

                GlassSection {
                    row(
                        title: "PowderMeet · Custom", detail: "Set type, length and waist yourself",
                        isSelected: draft.skiKey == nil, thumbnail: .house
                    ) {
                        draft.skiKey = nil
                    }
                    .accessibilityLabel("PowderMeet, custom gear")
                }

                ForEach(filtered, id: \.brand) { group in
                    GlassSection(group.brand) {
                        ForEach(Array(group.models.enumerated()), id: \.element.key) { index, ski in
                            if index > 0 { GlassDivider() }
                            row(
                                title: ski.model, detail: ski.detail,
                                isSelected: draft.skiKey == ski.key, thumbnail: .topsheet(ski.key)
                            ) {
                                draft.choose(ski)
                            }
                            .accessibilityLabel("\(ski.displayName), \(ski.detail)")
                        }
                    }
                }
                if filtered.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass", title: "No ski matches",
                        detail: "Choose PowderMeet · Custom and enter type, length and waist yourself.")
                }
                Text("\(SkiCatalog.models.count) models · \(SkiCatalog.brands.count) brands")
                    .textRole(.caption)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, GlassLayout.pageInset)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $searchText, prompt: "Search brand or model")
    }

    // MARK: Preview

    /// The pair as it will be drawn and, on its right, the one link from skis
    /// to theme. The button's slot is always there at one size, so nothing
    /// moves when it appears or changes state.
    private var preview: some View {
        HStack(spacing: 12) {
            SkiPairView(
                topLabel: draft.ski?.displayName ?? "PowderMeet · Custom",
                bottomLabel: draft.ski?.detail ?? "Your type, length and waist",
                look: draft.look
            )
            SkiThemeMatchButton(ski: draft.ski)
                .frame(width: SkiThemeMatchButton.size.width, height: SkiThemeMatchButton.size.height)
        }
        .glassCard()
    }

    // MARK: Rows

    private func row(
        title: String, detail: String, isSelected: Bool, thumbnail: SkiLook, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .textRole(.body)
                        .foregroundStyle(isSelected ? HUDTheme.accent : HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                }
                Spacer(minLength: 8)
                SkiBody(look: thumbnail)
                    .frame(width: 96, height: 12)
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(HUDTheme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, GlassLayout.cardPadding)
            .frame(maxWidth: .infinity, minHeight: GlassLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The one link from skis to theme: a custom theme whose accent is the
/// topsheet's dominant colour. It is an ordinary custom theme, so the theme
/// picker lists it and switching away is the usual tap. A fixed-size control;
/// empty (and not a control) when the ski has no theme colour, such as custom
/// gear.
private struct SkiThemeMatchButton: View {
    let ski: SkiModel?

    static let size = CGSize(width: 76, height: 80)

    /// One slot: matching a second ski replaces the first match.
    private static let themeID = UUID(uuid: (0x5C, 0x1B, 0x0A, 0x6E, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0xC0, 0xDE))

    private var matched: CustomAppTheme? {
        guard let accentHex = ski?.accentHex else { return nil }
        return CustomAppTheme(id: Self.themeID, name: "My skis", accentHex: accentHex)
    }

    var body: some View {
        if let matched, let preview = matched.appTheme {
            button(matched, preview: preview)
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func button(_ matched: CustomAppTheme, preview: AppTheme) -> some View {
        let manager = ThemeManager.shared
        let isOn = manager.selectedCustomID == Self.themeID
            && manager.customThemes.contains { $0.id == Self.themeID && $0.accentHex == matched.accentHex }
        return Button {
            manager.saveCustom(matched)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(preview.accent))
                        .frame(width: 24, height: 24)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(HUDTheme.onAccent)
                    }
                }
                Text(isOn ? "Theme\nmatched" : "Match\ntheme")
                    .textRole(.caption)
                    .foregroundStyle(isOn ? HUDTheme.secondaryText : HUDTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize()
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .background(HUDGlass.well, in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isOn)
        .accessibilityLabel(isOn ? "Theme matches your skis" : "Match theme to these skis")
    }
}
