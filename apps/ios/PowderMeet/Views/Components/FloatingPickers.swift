import MapScene
import MapboxAdapter
import PowderMeetAPI
import SwiftUI
import UIKit

/// The pick-one lists that float over the map (`MapSheet`), all in
/// one structure: the current choice in a bubble on top, the same glass rows,
/// the search at the foot.
struct FloatingPickerHost: View {
    @Environment(AppModel.self) private var model
    let picker: MapSheet

    var body: some View {
        switch picker {
        case .resortPicker: ResortPickerSheet { model.closeFloating() }
        case .themePicker: ThemeFloatingPicker { model.closeFloating() }
        case .iconPicker: IconFloatingPicker { model.closeFloating() }
        case .skiPicker: SkiFloatingPicker { model.closeFloating() }
        case .mapLookPicker: MapLookFloatingPicker { model.closeFloating() }
        case .goToPicker: GoToFloatingPicker { model.closeFloating() }
        case .badgePicker: BadgesFloatingPicker { model.closeFloating() }
        case .meetPlacePicker: MeetPlaceFloatingPicker { model.closeFloating() }
        }
    }
}

/// One row of a floating list: what it is drawn small, its name, one line
/// under it, and the accent ring when it is the current choice. One size.
struct FloatingRow<Leading: View>: View {
    let title: String
    var detail: String?
    var selected = false
    /// An asset drawn in place of the title's letters (the PowderMeet theme's
    /// wordmark); the title is still what VoiceOver reads.
    var titleImage: String?
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                if let titleImage {
                    Image(titleImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 16)
                        .foregroundStyle(HUDTheme.primaryText)
                        .accessibilityLabel(title)
                } else {
                    Text(title)
                        .textRole(.bodyEmph)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let detail {
                    Text(detail)
                        .textRole(.caption)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 36)
        .glassCardControl(padding: 14, selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Theme

/// The theme: one flat list: PowderMeet, then
/// every other theme alphabetically; a swatch and a name, nothing else. A
/// theme applies when tapped: the map behind is the preview.
struct ThemeFloatingPicker: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var manager = ThemeManager.shared
    @State private var library: [AppTheme] = []
    @State private var query = ""
    /// The order picked last time.
    @AppStorage("powdermeet.themes.sort") private var sortChoice = ThemeSort.name.rawValue

    /// By name; by the accent's place round the colour wheel; or by how dark
    /// the background is, darkest first.
    enum ThemeSort: String, Sendable {
        case name, colour, shade
    }

    private var sort: ThemeSort { ThemeSort(rawValue: sortChoice) ?? .name }

    private var needle: String { query.trimmingCharacters(in: .whitespaces) }
    private func matches(_ name: String) -> Bool { needle.isEmpty || name.localizedStandardContains(needle) }

    /// Everything but PowderMeet that matches the search. The thousand-odd
    /// themes are sorted once, off the main actor, when the list opens, not
    /// on every redraw (each tap applies a theme and redraws the list).
    private var others: [AppTheme] {
        needle.isEmpty ? library : library.filter { matches($0.name) }
    }

    var body: some View {
        FloatingPicker(
            title: manager.displayName, subtitle: "Theme",
            titleImage: manager.selectedCustomID == nil && manager.theme.id == AppTheme.classic.id
                ? "PowderMeetWordmark" : nil,
            leading: AnyView(ThemeSwatch(theme: manager.theme)),
            query: $query, prompt: "Search themes",
            sort: AnyView(FloatingSortButton(
                selection: Binding { sort } set: { sortChoice = $0.rawValue },
                options: [
                    (.name, "Name", "textformat"),
                    (.colour, "Colour", "paintpalette"),
                    (.shade, "Shade", "circle.lefthalf.filled"),
                ])),
            onClose: onClose
        ) {
            ForEach(manager.customThemes.filter { matches($0.name) }) { custom in
                if let theme = custom.appTheme {
                    Button { manager.selectCustom(custom) } label: {
                        FloatingRow(title: custom.name, selected: manager.selectedCustomID == custom.id) {
                            ThemeSwatch(theme: theme)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if matches(AppTheme.classic.name) { pick(.classic) }
            ForEach(others) { theme in pick(theme) }
        }
        .sensoryFeedback(.selection, trigger: manager.theme.id)
        .task(id: sortChoice) {
            let sort = sort
            library = await Task.detached(priority: .userInitiated) { () -> [AppTheme] in
                let bundled: [AppTheme]
                do {
                    let families = try ThemeLibrary.load(from: .main)
                    bundled = [ThemeFamily.ghostty, .base16, .gogh].flatMap { families[$0] ?? [] }
                } catch {
                    // The bundled list is unreadable: PowderMeet and the built-in themes remain.
                    bundled = []
                }
                // One of each name, alphabetical, then in the order asked for
                // (a stable sort, so equals stay alphabetical).
                var seen = Set<String>()
                let byName = (AppTheme.editorial + AppTheme.editor + bundled)
                    .filter { seen.insert($0.name.lowercased()).inserted }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                switch sort {
                case .name: return byName
                case .colour: return byName.map { ($0, Self.hue($0.accent)) }.sorted { $0.1 < $1.1 }.map(\.0)
                case .shade: return byName.map { ($0, Self.luminance($0.background)) }.sorted { $0.1 < $1.1 }.map(\.0)
                }
            }.value
        }
    }

    /// 0..<1 round the colour wheel; greys (no hue to speak of) sort last.
    private nonisolated static func hue(_ c: ThemeRGB) -> Double {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b), span = high - low
        guard span > 0.08 else { return 2 }
        let sixth: Double
        if high == c.r {
            sixth = ((c.g - c.b) / span).truncatingRemainder(dividingBy: 6)
        } else if high == c.g {
            sixth = (c.b - c.r) / span + 2
        } else {
            sixth = (c.r - c.g) / span + 4
        }
        return (sixth < 0 ? sixth + 6 : sixth) / 6
    }

    private nonisolated static func luminance(_ c: ThemeRGB) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    private func pick(_ theme: AppTheme) -> some View {
        Button { manager.select(theme) } label: {
            FloatingRow(
                title: theme.name, selected: manager.selectedCustomID == nil && manager.theme.id == theme.id,
                titleImage: theme.id == AppTheme.classic.id ? "PowderMeetWordmark" : nil
            ) {
                ThemeSwatch(theme: theme)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Map look

/// The map's style, in two parts. The ground: Satellite, Whiteout, Blueprint,
/// PowderMeet. What the runs' colours say: their rating, their steepest
/// pitch, the way they face, or how often this skier has skied them, each
/// with its own legend. Like the theme list it stays up after a pick: the
/// map behind repaints at once and is the preview.
struct MapLookFloatingPicker: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var manager = ThemeManager.shared

    var body: some View {
        FloatingPicker(
            title: manager.mapLook.title,
            titleImage: manager.mapLook.titleImage,
            secondTitle: manager.runOverlay.title,
            query: .constant(""), prompt: "", showsSearch: false, onClose: onClose
        ) {
            FloatingLabel("Map")
            // PowderMeet's own first in every list, chosen or not.
            ForEach([.holographic] + MapLook.allCases.filter { $0 != .holographic }, id: \.self) { look in
                Button { model.selectMapLook(look) } label: {
                    FloatingRow(title: look.title, selected: manager.mapLook == look, titleImage: look.titleImage) {
                        MapStyleIcon(look: look)
                    }
                }
                .buttonStyle(.plain)
            }
            FloatingLabel("Lines").padding(.top, 10)
            ForEach(RunOverlay.allCases, id: \.self) { overlay in
                Button { model.selectRunOverlay(overlay) } label: {
                    RunOverlayRow(overlay: overlay, selected: manager.runOverlay == overlay)
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: manager.mapLook)
        .sensoryFeedback(.selection, trigger: manager.runOverlay)
    }
}

extension MapLook {
    /// The mark that says what the look shows, as a maps app marks its modes.
    var icon: String {
        switch self {
        case .satellite: "globe.americas.fill"
        case .whiteout: "snowflake"
        case .blueprint: "pencil.and.ruler.fill"
        // The app's own mark, for the app's own look.
        case .holographic: "mountain.2.fill"
        }
    }

    /// The PowderMeet look is named by the wordmark, as the PowderMeet theme is.
    var titleImage: String? { self == .holographic ? "PowderMeetWordmark" : nil }

    /// The mark's own colour, the same in every theme: the look's, not the app's.
    var tint: Color {
        switch self {
        case .satellite: Color(red: 0.36, green: 0.78, blue: 0.47)
        case .whiteout: Color(red: 0.86, green: 0.91, blue: 0.97)
        case .blueprint: Color(red: 0.30, green: 0.72, blue: 1.0)
        case .holographic: Color(red: 0.91, green: 0.15, blue: 0.16)
        }
    }
}

extension RunOverlay {
    var title: String {
        switch self {
        case .difficulty: "Difficulty"
        case .steepness: "Steepness"
        case .aspect: "Facing"
        case .skied: "Run Completion"
        }
    }

    var icon: String {
        switch self {
        case .difficulty: "diamond.fill"
        case .steepness: "angle"
        case .aspect: "safari.fill"
        case .skied: "checklist"
        }
    }

    var tint: Color {
        switch self {
        case .difficulty: Color(red: 0.48, green: 0.72, blue: 1.0)
        case .steepness: Color(red: 0.98, green: 0.57, blue: 0.24)
        case .aspect: Color(red: 0.13, green: 0.83, blue: 0.93)
        case .skied: Color(red: 0.94, green: 0.27, blue: 0.27)
        }
    }
}

/// A style's mark on a small tile, in its own colour.
struct MapStyleIcon: View {
    let systemImage: String
    let tint: Color
    /// The PowderMeet look carries the app's own icon, the same picture the
    /// icon list shows for PowderMeet, not a drawn stand-in.
    var isAppIcon = false

    init(systemImage: String, tint: Color) {
        self.systemImage = systemImage
        self.tint = tint
    }

    init(look: MapLook) {
        systemImage = look.icon
        tint = look.tint
        isAppIcon = look == .holographic
    }

    var body: some View {
        if isAppIcon {
            IconThumb(icon: .original)
                .frame(width: 40, height: 36)
        } else {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 36)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// A colouring's legend: its colours in order, each over what it stands for.
struct RunOverlayLegend: View {
    let overlay: RunOverlay

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(overlay.legend.enumerated()), id: \.offset) { _, step in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: step.hex))
                        .frame(height: 6)
                    Text(step.label)
                        .textRole(.caption)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// On the map while the runs are coloured by anything but their rating: what
/// the colours mean, so the map can be read with the style list closed. A
/// tap opens that list.
struct RunOverlayMapLegend: View {
    @Environment(AppModel.self) private var model
    @State private var manager = ThemeManager.shared

    var body: some View {
        let overlay = manager.runOverlay
        if overlay != .difficulty {
            Button { model.openFloating(.mapLookPicker) } label: {
                HStack(spacing: 10) {
                    Image(systemName: overlay.icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(overlay.tint)
                        .accessibilityHidden(true)
                    RunOverlayLegend(overlay: overlay)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(HUDGlass.surface, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Runs coloured by \(overlay.title.lowercased())")
            .accessibilityHint("Opens map styles")
        }
    }
}

/// One way of colouring the runs: its mark, its name and, under the name,
/// its legend as the colours in order with their ends named.
private struct RunOverlayRow: View {
    let overlay: RunOverlay
    let selected: Bool

    var body: some View {
        let legend = overlay.legend
        HStack(spacing: 12) {
            MapStyleIcon(systemImage: overlay.icon, tint: overlay.tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(overlay.title)
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                if !legend.isEmpty { RunOverlayLegend(overlay: overlay) }
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 36)
        .glassCardControl(padding: 14, selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(overlay.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: App icon

/// The Home Screen icon, as rows: the icon, its name. Like the theme list it
/// stays up after a pick, so icons can be tried one after
/// another; the system's "icon changed" alert shows over it.
struct IconFloatingPicker: View {
    let onClose: () -> Void
    @State private var manager = ThemeManager.shared
    @State private var query = ""
    /// The order picked last time: the icons' own families, or by name.
    @AppStorage("powdermeet.icons.sort") private var byName = false

    private var icons: [AppIcon] {
        let matching = AppIcon.allCases.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        guard byName else { return matching }
        // PowderMeet's own stays first, as in every list.
        return matching.sorted {
            if ($0 == .original) != ($1 == .original) { return $0 == .original }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        FloatingPicker(
            title: manager.selectedIcon.title, subtitle: "App icon",
            // The PowderMeet icon is named by the wordmark, as the theme is.
            titleImage: manager.selectedIcon == .original ? "PowderMeetWordmark" : nil,
            leading: AnyView(IconThumb(icon: manager.selectedIcon)),
            query: $query, prompt: "Search icons",
            sort: AnyView(FloatingSortButton(
                selection: $byName,
                options: [(false, "Family", "square.grid.2x2"), (true, "Name", "textformat")])),
            onClose: close
        ) {
            ForEach(icons) { icon in
                // No `.disabled` while a change is under way: `selectIcon`
                // ignores a second pick itself, and a disabled row must not
                // pass a tap through to the dimmed map, which closes the list.
                Button { manager.selectIcon(icon) } label: {
                    FloatingRow(
                        title: icon.title, selected: manager.selectedIcon == icon,
                        titleImage: icon == .original ? "PowderMeetWordmark" : nil
                    ) {
                        IconThumb(icon: icon)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: manager.selectedIcon)
        .alert("Couldn't change icon", isPresented: Binding(
            get: { manager.iconError != nil }, set: { if !$0 { manager.iconError = nil } }
        )) { Button("OK") { manager.iconError = nil } } message: { Text(manager.iconError ?? "") }
    }

    /// While iOS changes the icon its alert takes the screen; nothing that
    /// happens under it (a tap reaching the map, the list's scroll settling)
    /// closes the list.
    private func close() {
        guard !manager.isChangingIcon else { return }
        onClose()
    }
}

/// An app icon drawn as the Home Screen shows it, 36 pt (`AppIcon.image`).
private struct IconThumb: View {
    let icon: AppIcon

    var body: some View {
        Group {
            if let image = icon.image {
                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
            } else {
                Image(systemName: "mountain.2.fill").resizable().aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: Skis

/// The skis by name: Custom first (the PowderMeet ski, with type, length and
/// waist set by hand on Gear), then every catalog ski under its brand. A pick
/// saves at once and fills the routing fields Gear shows. Every thumbnail at
/// one size and its true proportions, on the right.
struct SkiFloatingPicker: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var query = ""
    /// The order picked last time.
    @AppStorage("powdermeet.skis.sort") private var sortChoice = SkiSort.brand.rawValue

    /// Under each brand; under each type; one list by name; or narrowest
    /// underfoot first.
    enum SkiSort: String {
        case brand, type, name, width
    }

    private var sort: SkiSort { SkiSort(rawValue: sortChoice) ?? .brand }

    private var draft: GearDraft? { model.profile.map(GearDraft.init) }

    /// The matching skis in the groups the chosen order makes. Outside the
    /// brand order a row carries the brand in its name.
    private var filtered: [(brand: String, models: [SkiModel])] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let brands = terms.isEmpty ? SkiCatalog.brands : SkiCatalog.brands.compactMap { group in
            let models = group.models.filter { model in
                let searchable = "\(model.displayName) \(model.category.label)".lowercased()
                return terms.allSatisfy { searchable.contains($0) }
            }
            return models.isEmpty ? nil : (brand: group.brand, models: models)
        }
        let all = brands.flatMap(\.models)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        switch sort {
        case .brand:
            return brands
        case .type:
            return Dictionary(grouping: all, by: \.category.label)
                .sorted { $0.key < $1.key }
                .map { (brand: $0.key, models: $0.value) }
        case .name:
            return all.isEmpty ? [] : [(brand: "A to Z", models: all)]
        case .width:
            let narrowFirst = all.map { ($0, $0.waistMM) }.sorted { $0.1 < $1.1 }.map(\.0)
            return all.isEmpty ? [] : [(brand: "Narrowest first", models: narrowFirst)]
        }
    }

    var body: some View {
        FloatingPicker(
            title: draft?.ski?.displayName ?? "Custom", subtitle: draft?.ski?.detail ?? "Your skis",
            leading: AnyView(SkiThumb(look: draft?.look ?? .house).skiGlow()),
            query: $query, prompt: "Search brand or model",
            sort: AnyView(FloatingSortButton(
                selection: Binding { sort } set: { sortChoice = $0.rawValue },
                options: [
                    (.brand, "Brand", "tag"),
                    (.type, "Type", "square.grid.2x2"),
                    (.name, "Name", "textformat"),
                    (.width, "Width", "arrow.left.and.right"),
                ])),
            onClose: onClose
        ) {
            SkiGlowGroup()
            Button { choose(nil) } label: {
                row(title: "Custom", detail: "Type, length and waist by hand", look: .house, selected: draft?.skiKey == nil)
            }
            .buttonStyle(.plain)
            ForEach(filtered, id: \.brand) { group in
                FloatingLabel(group.brand).padding(.top, 10)
                ForEach(group.models) { ski in
                    Button { choose(ski) } label: {
                        row(
                            title: sort == .brand ? ski.model : ski.displayName, detail: ski.detail,
                            look: .topsheet(ski.key), selected: draft?.skiKey == ski.key)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(ski.displayName), \(ski.detail)")
                }
            }
        }
    }

    private func row(title: String, detail: String, look: SkiLook, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .textRole(.caption)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SkiThumb(look: look)
        }
        .frame(minHeight: 36)
        .glassCardControl(padding: 14, selected: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ ski: SkiModel?) {
        guard var draft else { return }
        if let ski { draft.choose(ski) } else { draft.skiKey = nil }
        // A new pair: the glow takes its colour.
        ThemeManager.shared.noteSkiAccent(ski?.accentHex)
        model.saveGear(draft)
    }
}

/// A ski's topsheet at one fixed size, its own proportions (long and thin).
struct SkiThumb: View {
    let look: SkiLook

    var body: some View {
        SkiBody(look: look)
            .frame(width: 112, height: 22)
            .accessibilityHidden(true)
    }
}

/// The skis' glow, at the head of the ski picker: one switch and, while it
/// is on, two buttons for its colour: Ski (the chosen ski's own) or Theme (the
/// app theme's accent). The picker's header pair shows it.
private struct SkiGlowGroup: View {
    @Environment(AppModel.self) private var model
    private var theme: ThemeManager { ThemeManager.shared }

    var body: some View {
        GlassSection {
            GlassToggleRow(
                icon: nil, title: "Glow",
                isOn: Binding(get: { theme.skiGlowOn }, set: { theme.setSkiGlow(on: $0) }))
            if theme.skiGlowOn {
                GlassDivider()
                HUDChoicePills(
                    choices: [HUDChoicePills<ThemeManager.SkiGlowSource>.Choice(value: .ski, label: "Ski"),
                              HUDChoicePills<ThemeManager.SkiGlowSource>.Choice(value: .theme, label: "Theme")],
                    selection: theme.skiGlowSource
                ) { theme.setSkiGlowSource($0) }
                .padding(GlassLayout.cardPadding)
                .accessibilityLabel("Glow colour")
            }
        }
        .onAppear {
            // The picker may open on a pair chosen before the glow followed it.
            if let key = model.profile.map(GearDraft.init)?.skiKey {
                theme.noteSkiAccent(SkiCatalog.model(key: key)?.accentHex)
            }
        }
    }
}
