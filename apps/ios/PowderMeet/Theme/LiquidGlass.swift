import SwiftUI

/// The app's Liquid Glass layer: one set of measurements, one theme tint, and
/// the few surfaces built from them (card, bar, chip, round control, field and
/// sheet backdrop), so every screen is made of the same family. The rules are
/// in `specs/12-DESIGN-BRIEF.md`, "Liquid Glass", and `specs/13-APP-MAP.md`
/// section 4. The glass itself is the system's (`glassEffect`), which also
/// gives reduce-transparency and increase-contrast behaviour; nothing here
/// draws a blur.
enum GlassLayout {
    /// From a floating element to the screen edge.
    static let inset: CGFloat = 12
    /// A page's or a sheet's side margin.
    static let pageInset: CGFloat = 16
    /// Between two floating elements, and from one to a bar.
    static let gap: CGFloat = 8
    /// Between two sections of a page.
    static let sectionGap: CGFloat = 24
    /// Every card, whatever it holds.
    static let cardRadius: CGFloat = 22
    static let cardPadding: CGFloat = 16
    /// A box inside a card (a stat, a stepper, a well).
    static let innerRadius: CGFloat = 12
    /// One row: icon, title, a detail line and the trailing value.
    static let rowHeight: CGFloat = 56
    /// The bottom bar and the resort bar: a capsule this tall.
    static let barHeight: CGFloat = 52
    /// Every chip, friend or status: a capsule this tall, its own glove target.
    static let chipHeight: CGFloat = 44
    static let chipPaddingH: CGFloat = 14
    /// A round icon control.
    static let iconButton: CGFloat = 44
}

enum HUDGlass {
    /// How much of the theme's card colour every glass surface carries. The one
    /// knob for legibility over the map: raise it and every surface in the app
    /// gets denser at once.
    static let strength = 0.62

    /// The theme's tint, the one expression every glass surface carries.
    /// Changing the theme changes all glass at once, and the text tiers keep
    /// the contrast they were derived for on the card colour.
    static var tint: Color { HUDTheme.cardBackground.opacity(strength) }

    /// A surface: bars, cards, sections, rows.
    static var surface: Glass { .regular.tint(tint) }

    /// A control (a button, a tappable row or chip): the same glass, answering
    /// a touch the way system controls do.
    static var control: Glass { surface.interactive() }

    /// A text field: the same glass a step denser, so what is typed reads at
    /// full contrast.
    static var field: Glass { .regular.tint(HUDTheme.cardBackground.opacity(min(1, strength + 0.2))) }

    /// A sheet's backdrop over the map: the theme's background colour through
    /// the same glass, so the cards on it read as one family.
    static var backdrop: Glass { .regular.tint(HUDTheme.mapBackground.opacity(strength - 0.17)) }

    /// A selected chip or card: a wash of the accent under its ring.
    static var selectedSurface: Glass { .regular.tint(HUDTheme.accent.opacity(0.32)) }

    /// A rule inside a card: a faint line of the text colour.
    static var hairline: Color { HUDTheme.primaryText.opacity(0.16) }

    /// A filled well inside a card (a control's box, an empty meter cell): a
    /// faint wash of the accent, so a box on glass carries the theme rather
    /// than reading as grey.
    static var well: Color { HUDTheme.accent.opacity(0.12) }
}

/// Written out rather than with `@Entry`: the target's default main-actor
/// isolation would otherwise isolate the key's `defaultValue`.
private nonisolated struct OnGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a glass card. Controls drawn there are wells and hairlines,
    /// never a second glass.
    nonisolated var isOnGlass: Bool {
        get { self[OnGlassKey.self] }
        set { self[OnGlassKey.self] = newValue }
    }
}

extension View {
    /// A card: 16 pt padding and 22 pt corners on theme glass. What it holds
    /// draws as content on glass (`isOnGlass`). `selected` rings it in the
    /// accent.
    func glassCard(padding: CGFloat = GlassLayout.cardPadding, selected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous)
        return self
            .environment(\.isOnGlass, true)
            .padding(padding)
            .glassEffect(selected ? HUDGlass.selectedSurface : HUDGlass.surface, in: shape)
            .overlay {
                if selected { shape.strokeBorder(HUDTheme.accent, lineWidth: 2) }
            }
    }

    /// A card that is itself a control (a tile, a tappable list row): the
    /// card's shape and padding on interactive glass.
    func glassCardControl(padding: CGFloat = GlassLayout.cardPadding, selected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous)
        return self
            .environment(\.isOnGlass, true)
            .padding(padding)
            .contentShape(shape)
            .glassEffect((selected ? HUDGlass.selectedSurface : HUDGlass.surface).interactive(), in: shape)
            .overlay {
                if selected { shape.strokeBorder(HUDTheme.accent, lineWidth: 2) }
            }
    }

    /// A bar: a capsule 52 pt tall (the resort bar).
    func glassBar(interactive: Bool = false) -> some View {
        self
            .environment(\.isOnGlass, true)
            .padding(.horizontal, GlassLayout.cardPadding)
            .frame(height: GlassLayout.barHeight)
            .contentShape(Capsule())
            .glassEffect(HUDGlass.surface.interactive(interactive), in: Capsule())
    }

    /// A chip: a capsule 44 pt tall. `interactive` for one that is a control;
    /// `selected` rings it in the accent over an accent wash.
    func glassChip(interactive: Bool = false, selected: Bool = false) -> some View {
        self
            .environment(\.isOnGlass, true)
            .padding(.horizontal, GlassLayout.chipPaddingH)
            .frame(height: GlassLayout.chipHeight)
            .glassEffect(
                (selected ? HUDGlass.selectedSurface : HUDGlass.surface).interactive(interactive),
                in: Capsule())
            .overlay {
                if selected { Capsule().strokeBorder(HUDTheme.accent, lineWidth: 2) }
            }
            .contentShape(Capsule())
    }

    /// A round glass control, 44 pt.
    func glassCircleControl(size: CGFloat = GlassLayout.iconButton) -> some View {
        self
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(HUDGlass.control, in: Circle())
    }

    /// A text field's box: denser glass, or a well when it sits on a card.
    func glassField() -> some View {
        modifier(GlassFieldModifier())
    }
}

private struct GlassFieldModifier: ViewModifier {
    @Environment(\.isOnGlass) private var isOnGlass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous)
        if isOnGlass {
            content.background(HUDGlass.well, in: shape)
        } else {
            content.glassEffect(HUDGlass.field, in: shape)
        }
    }
}
