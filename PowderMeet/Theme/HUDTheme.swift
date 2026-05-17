//
//  HUDTheme.swift
//  PowderMeet
//

import SwiftUI

enum HUDTheme {
    // MARK: - Backgrounds
    //
    // Every surface tier is derived from `activeTheme.bgRGB` via a
    // luminance offset (see ThemeManager.Theme.offset(by:)) so the
    // full tonal stack — bg < header < input < card < border —
    // inherits the active theme's hue while preserving the legacy
    // luminance ratios. On Original these all reduce numerically to
    // the previous static values (0.06, 0.09, 0.13, 0.22), so the
    // launch theme renders identically; every other theme picks up
    // the matching hue at every tier instead of just at the root.
    //
    // Views that read these in their body register a Swift Observation
    // dep on `activeTheme` transparently and re-render on theme swap.
    static var mapBackground: Color    { ThemeManager.shared.activeTheme.backgroundColor }
    static var cardBackground: Color   { ThemeManager.shared.activeTheme.cardBackground }
    static var cardBorder: Color       { ThemeManager.shared.activeTheme.cardBorder }
    static var inputBackground: Color  { ThemeManager.shared.activeTheme.inputBackground }
    static var headerBackground: Color { ThemeManager.shared.activeTheme.headerBackground.opacity(0.96) }
    static let headerBorder            = Color.white.opacity(0.12)

    /// Dim scrim drawn over content during a blocking operation
    /// (avatar upload spinner, full-screen loading). Tuned to dim
    /// without going pure-black, so the underlying HUD stays legible.
    static let modalScrim       = Color.black.opacity(0.55)

    // MARK: - Text (semantic tiers)
    // Four deliberate tiers replace the old 2 named greys + ~172
    // ad-hoc `.opacity(0.3–0.7)`-on-text values. Pick by ROLE, not
    // by eyeballing an opacity:
    //   textPrimary   — headlines, values, anything you must read
    //   textSecondary — supporting copy, subtitles, inactive labels
    //   textTertiary  — captions, timestamps, footnotes, hints
    //   textDisabled  — disabled controls, placeholders
    // Values for primary/secondary are pixel-identical to the old
    // constants so already-shipped screens don't shift.
    static let textPrimary   = Color(red: 0.95, green: 0.95, blue: 0.96)
    static let textSecondary = Color(red: 0.54, green: 0.54, blue: 0.57)
    static let textTertiary  = Color(red: 0.42, green: 0.44, blue: 0.48)
    static let textDisabled  = Color(red: 0.30, green: 0.31, blue: 0.34)

    // Back-compat aliases — 92+ existing sites keep compiling and
    // rendering identically; migrate opportunistically in Phases 4–5.
    // `dimText` is repurposed as the canonical disabled tier (it had
    // zero real uses before).
    static var primaryText: Color   { textPrimary }
    static var secondaryText: Color { textSecondary }
    static var dimText: Color       { textDisabled }

    // MARK: - Accents
    /// Primary UI accent. Computed so `ThemeManager` can swap it
    /// process-wide; `RootView` keys its body on
    /// `ThemeManager.shared.generation` so a theme change rebuilds
    /// the tree and every read of this re-evaluates.
    static var accent: Color { ThemeManager.shared.activeTheme.accentColor }
    static let accentAmber      = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let accentRed        = Color(red: 1.00, green: 0.28, blue: 0.34)
    static let accentGreen      = Color(red: 0.42, green: 0.88, blue: 0.72)
    static let accentCyan       = Color(red: 0.45, green: 0.84, blue: 1.00)

    // MARK: - Spinner tint policy
    //
    // Three flavors of `ProgressView().tint(...)` that recur all over
    // the app, named so callers don't have to remember which raw color
    // belongs in which context. Pick by what the spinner is *waiting
    // on*, not by where it's drawn:
    //
    //   - `spinnerDataLoad`    — backend / network / resort graph fetch.
    //                             Example: resort load bar, friends list
    //                             hydrate. Amber so the user reads it as
    //                             "we're working on data" — distinct from
    //                             interactive UI feedback.
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
    static let spinnerDataLoad    = accentAmber
    static let spinnerForm        = Color.white
    /// Computed so it tracks `accent` through theme changes.
    static var spinnerInteractive: Color { accent }

    // MARK: - Trail Colors
    // Blacks are off-white (#F5F5F7) rather than pure white so the label
    // pops on bright satellite basemap. Accent red stays for user-facing UI;
    // routes use cyan/orange for cleaner contrast on the photo-real imagery.
    static func color(for difficulty: RunDifficulty) -> Color {
        switch difficulty {
        case .green:       return Color(hex: "5DEA8C")
        case .blue:        return Color(hex: "7AB8FF")
        case .black:       return Color(hex: "F5F5F7")
        case .doubleBlack: return Color(hex: "FF5C6E")
        case .terrainPark: return Color(hex: "FF8533")
        }
    }

    // MARK: - Route Overlay Colors
    static let routeSkierA      = Color(hex: "38D9FF")  // cyan — user
    static let routeSkierB      = Color(hex: "FF8A3D")  // warm orange — friend
    static let routeMeeting     = Color(hex: "FBBF24")  // gold — meeting pin

    // MARK: - Map
    static let liftColor        = Color(red: 0.98, green: 0.82, blue: 0.42)
    static let liftDash: [CGFloat] = [8, 5]
    static let selectionGlow    = Color(red: 0.92, green: 0.25, blue: 0.25)
    static let glowRadius: CGFloat = 6
    static let mountainFill     = Color(red: 0.10, green: 0.10, blue: 0.11)

    // MARK: - Mapbox hex strings (for GeoJSON style layers)
    static func mapboxHex(for difficulty: RunDifficulty) -> String {
        switch difficulty {
        case .green:       return "#5DEA8C"
        case .blue:        return "#7AB8FF"
        case .black:       return "#F5F5F7"
        case .doubleBlack: return "#FF5C6E"
        case .terrainPark: return "#FF8533"
        }
    }
    static let mapboxLiftHex   = "#FFD166"
    static let mapboxRouteAHex = "#38D9FF"   // cyan — user
    static let mapboxRouteBHex = "#FF8A3D"   // warm orange — friend
    static let mapboxMeetHex   = "#FBBF24"

    // MARK: - Typography
    // DEPRECATED: prefer the semantic scale in HUDFont.swift —
    // `.hudType(.label/.section/.title/…)`. These fixed-monospaced
    // constants don't pick up the per-theme typeface; kept only until
    // the remaining call sites migrate (see plan Phases 4–5).
    static let labelFont   = Font.system(size: 9,  weight: .medium,   design: .monospaced)
    static let hudFont     = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let titleFont   = Font.system(size: 13, weight: .bold,     design: .monospaced)
    static let bodyFont    = Font.system(size: 11, weight: .regular,  design: .monospaced)
    static let captionFont = Font.system(size: 8,  weight: .regular,  design: .monospaced)

    /// Escape hatch for one-off chrome sizes that don't match the five
    /// presets above (e.g. the map-tab error overlay's 18pt headline,
    /// or 12pt bold subtitles on flow cards). Defaults to the
    /// monospaced HUD design family so callers don't accidentally drift
    /// to system default. Prefer the named presets when one fits.
    static func hud(
        _ size: CGFloat,
        _ weight: Font.Weight = .medium,
        monospaced: Bool = true
    ) -> Font {
        .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }
}

// MARK: - Color hex init

extension Color {
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
