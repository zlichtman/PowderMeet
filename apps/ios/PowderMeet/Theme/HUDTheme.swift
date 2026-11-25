//
//  HUDTheme.swift
//  PowderMeet
//

import MountainCore
import SwiftUI

enum HUDTheme {
    // MARK: - Theme
    //
    // Every themed token reads the selected `AppTheme` (see AppTheme.swift
    // for the roles and how a palette fills them). A view that reads one
    // in its body registers an Observation dependency on
    // `ThemeManager.theme` and re-renders when the theme changes. Classic
    // gives exactly the values these tokens had as constants. Reading
    // `units` here too makes the same views redraw when the units change,
    // since `UnitFormatter` (nonisolated) reads them from storage.
    private static var theme: AppTheme {
        let manager = ThemeManager.shared
        _ = manager.units
        return manager.theme
    }

    // MARK: - Backgrounds
    static var mapBackground: Color    { Color(theme.background) }
    static var cardBackground: Color   { Color(theme.card) }
    static var cardBorder: Color       { Color(theme.border) }

    // MARK: - Text
    // Two tiers, picked by role rather than by an opacity on the text:
    //   primaryText   — headlines, values, anything you must read
    //   secondaryText — supporting copy, subtitles, inactive labels
    static var primaryText: Color   { Color(theme.textPrimary) }
    static var secondaryText: Color { Color(theme.textSecondary) }

    // MARK: - Accents
    /// Primary UI accent. Filled buttons draw white labels on it, and
    /// every theme keeps it dark enough for that.
    static var accent: Color { Color(theme.accent) }
    /// Labels and icons on an `accent` fill. White in every theme, because
    /// every theme keeps its accent dark enough for it.
    static let onAccent = Color.white
    /// Labels and icons on a status-colour fill (success, warning, danger,
    /// info). Status colours are picked to stand out from the background, so
    /// the background colour reads on top of them in every theme.
    static var onStatus: Color { Color(theme.background) }
    // Status colours, named for the hue they have in Classic:
    // amber = warning, red = danger, green = success, cyan = info.
    static var accentAmber: Color { Color(theme.warning) }
    static var accentRed: Color   { Color(theme.danger) }
    static var accentGreen: Color { Color(theme.success) }
    static var accentCyan: Color  { Color(theme.info) }

    // MARK: - Spinner tint policy
    //
    // Two flavors of `ProgressView().tint(...)`, named so callers don't
    // have to remember which raw color belongs in which context:
    //
    //   - `spinnerForm`        — submit-style buttons that own their own
    //                             accent background already. White on the
    //                             button reads like a button-press. Sign
    //                             in / sign up / save / delete.
    //
    //   - `spinnerInteractive` — inline overlays sitting on top of HUD
    //                             cards (avatar overlay, edge-info skeleton,
    //                             solver placeholder). Accent because the
    //                             surrounding chrome is already neutral.
    //
    static let spinnerForm        = Color.white
    /// Computed so it tracks `accent` through theme changes.
    static var spinnerInteractive: Color { accent }

    // MARK: - Trail Colors
    // Fixed in every theme: green, blue and black are meaning, and they
    // match what the map draws. Blacks are off-white (#F5F5F7) rather
    // than pure white so the label pops on bright satellite basemap.
    static func color(for difficulty: Difficulty) -> Color {
        switch difficulty {
        case .green:       return Color(hex: "5DEA8C")
        case .blue:        return Color(hex: "7AB8FF")
        case .black:       return Color(hex: "F5F5F7")
        case .doubleBlack: return Color(hex: "FF5C6E")
        case .park:        return Color(hex: "FF8533")
        case .unknown:     return secondaryText
        }
    }

    // MARK: - Route Overlay Colors
    // Theme roles, but every bundled theme keeps Classic's cyan (you)
    // and orange (friend) so they match the route lines on the map.
    static var routeSkierA: Color { Color(theme.routeYou) }
    static var routeSkierB: Color { Color(theme.routeFriend) }
    static let routeMeeting     = Color(hex: "FBBF24")  // gold — meeting pin

    // MARK: - Map
    static let liftColor        = Color(red: 0.98, green: 0.82, blue: 0.42)
}

// MARK: - Color hex init

extension Color {
    init(_ rgb: ThemeRGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Init from a 6-digit hex string (e.g. `"4ADE80"`, optional leading `#`).
    /// Invalid input asserts in DEBUG and returns magenta in release so the
    /// mistake is visually obvious instead of silently falling back to a default.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        let scanner = Scanner(string: trimmed)
        let scanned = scanner.scanHexInt64(&int)
        if scanned && scanner.isAtEnd && trimmed.count == 6 {
            let r = Double((int >> 16) & 0xFF) / 255
            let g = Double((int >>  8) & 0xFF) / 255
            let b = Double( int        & 0xFF) / 255
            self.init(red: r, green: g, blue: b)
        } else {
            assertionFailure("Color(hex:) given invalid hex string \(hex.debugDescription)")
            self.init(red: 1, green: 0, blue: 1) // magenta = "you have a typo"
        }
    }
}
