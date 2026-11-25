//
//  AppTheme.swift
//  PowderMeet
//
//  A theme is a small set of semantic colour roles. `HUDTheme` reads the
//  selected one, so views never name a palette. A theme is built from a
//  `ThemeSeed`: the handful of colours a Base16, Ghostty or Gogh palette
//  gives (background, foreground, accent, sixteen ANSI colours). The
//  derivation keeps Classic's tonal ladder and text contrast, and returns
//  nil for a palette this dark HUD cannot show readably.
//
//  Foundation only and nonisolated: the library derives a thousand of
//  these off the main actor, and the contrast rules can be checked from
//  the command line (see specs/12-DESIGN-BRIEF.md, Themes).
//

import Foundation

/// An sRGB colour, channels 0...1.
nonisolated struct ThemeRGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Six hex digits, with or without a leading `#`.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    static let white = ThemeRGB(1, 1, 1)
    static let black = ThemeRGB(0, 0, 0)

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1...21.
    func contrast(with other: ThemeRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `amount` 0 is this colour, 1 is `other`.
    func mixed(with other: ThemeRGB, _ amount: Double) -> ThemeRGB {
        ThemeRGB(
            r + (other.r - r) * amount,
            g + (other.g - g) * amount,
            b + (other.b - b) * amount
        )
    }

    /// Adds `delta` to every channel: the tonal step Classic uses, which
    /// keeps the hue of a tinted background.
    func lifted(by delta: Double) -> ThemeRGB {
        ThemeRGB(min(1, r + delta), min(1, g + delta), min(1, b + delta))
    }

    /// Hue in degrees and saturation 0...1 (HSV).
    var hueSaturation: (hue: Double, saturation: Double) {
        let high = max(r, g, b), low = min(r, g, b), span = high - low
        guard span > 0, high > 0 else { return (0, 0) }
        var hue: Double
        if high == r {
            hue = (g - b) / span
        } else if high == g {
            hue = 2 + (b - r) / span
        } else {
            hue = 4 + (r - g) / span
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, span / high)
    }
}

nonisolated enum ThemeFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case powdermeet, editorial, editor, ghostty, base16, gogh, custom

    var id: String { rawValue }
}

/// What a theme is built from, and what is saved for the selected theme
/// so launch needs no library load.
nonisolated struct ThemeSeed: Codable, Hashable, Sendable, Identifiable {
    var family: ThemeFamily
    var name: String
    var background: String
    var foreground: String
    var accent: String
    /// The card colour when the palette names one (Editorial, Editor, Custom).
    var surface: String?
    /// Sixteen ANSI colours, normal then bright, when the palette has them.
    var ansi: [String]?

    var id: String { "\(family.rawValue)/\(name)" }
}

nonisolated struct AppTheme: Hashable, Sendable, Identifiable {
    let seed: ThemeSeed

    // Surfaces, darkest to lightest.
    let background: ThemeRGB
    let header: ThemeRGB
    let input: ThemeRGB
    let card: ThemeRGB
    let border: ThemeRGB

    // Text tiers.
    let textPrimary: ThemeRGB
    let textSecondary: ThemeRGB
    let textTertiary: ThemeRGB

    /// Labels, selected states and filled buttons. Filled buttons draw
    /// white labels on it, so it is never lighter than white can read on.
    let accent: ThemeRGB

    // Status.
    let success: ThemeRGB
    let warning: ThemeRGB
    let danger: ThemeRGB
    let info: ThemeRGB

    /// Route colours. Every bundled theme keeps Classic's, because they
    /// must match the lines the map draws, and the map does not follow
    /// the theme.
    let routeYou: ThemeRGB
    let routeFriend: ThemeRGB

    var id: String { seed.id }
    var name: String { seed.name }
    var family: ThemeFamily { seed.family }

    /// The colours a preview strip shows.
    var swatches: [ThemeRGB] { [accent, success, warning, danger, info] }
}

// MARK: - Classic and the PowderMeet presets

nonisolated extension AppTheme {
    private static let classicText = (
        primary: ThemeRGB(0.95, 0.95, 0.96),
        secondary: ThemeRGB(0.54, 0.54, 0.57),
        tertiary: ThemeRGB(0.42, 0.44, 0.48)
    )
    static let classicSuccess = ThemeRGB(0.42, 0.88, 0.72)
    static let classicWarning = ThemeRGB(1.00, 0.72, 0.20)
    static let classicDanger = ThemeRGB(1.00, 0.28, 0.34)
    static let classicInfo = ThemeRGB(0.45, 0.84, 1.00)
    static let classicRouteYou = ThemeRGB(hex: "38D9FF") ?? .white
    static let classicRouteFriend = ThemeRGB(hex: "FF8A3D") ?? .white

    /// Classic's text and tonal ladder on a near-black, with an accent.
    private static func preset(
        _ name: String, accent: ThemeRGB, background: ThemeRGB, cardLift: Double = 0.070
    ) -> AppTheme {
        AppTheme(
            seed: ThemeSeed(family: .powdermeet, name: name, background: "", foreground: "", accent: ""),
            background: background,
            header: background.lifted(by: 0.010),
            input: background.lifted(by: cardLift * 0.43),
            card: background.lifted(by: cardLift),
            border: background.lifted(by: cardLift + 0.09),
            textPrimary: classicText.primary,
            textSecondary: classicText.secondary,
            textTertiary: classicText.tertiary,
            accent: accent,
            success: classicSuccess,
            warning: classicWarning,
            danger: classicDanger,
            info: classicInfo,
            routeYou: classicRouteYou,
            routeFriend: classicRouteFriend
        )
    }

    /// The default look: the PowderMeet red on black. Glass tinted with a
    /// solid-card grey such as #1E1E23 reads grey over a bright map, so the
    /// tint is a far deeper black and the red a touch richer.
    static let classic = preset(
        "PowderMeet", accent: ThemeRGB(0.910, 0.150, 0.160), background: ThemeRGB(0.020, 0.020, 0.024),
        cardLift: 0.022
    )

    /// The PowderMeet family is Classic alone.
    static let powdermeet: [AppTheme] = [classic]
}

// MARK: - Deriving a theme from a palette

nonisolated extension AppTheme {
    /// Contrast each text tier holds against the card, the lightest
    /// surface text sits on. The numbers are Classic's own.
    enum Contrast {
        static let primary = 7.0
        static let secondary = 4.6
        static let tertiary = 3.2
        /// Accent used as a label on a card, and a white label on an accent fill.
        static let accent = 3.0
        static let status = 4.5
    }

    /// Nil when the palette is light, or too bright for an accent to
    /// read on its cards while white still reads on the accent.
    init?(seed: ThemeSeed) {
        guard let background = ThemeRGB(hex: seed.background),
              let foreground = ThemeRGB(hex: seed.foreground),
              let seedAccent = ThemeRGB(hex: seed.accent) else { return nil }

        let card: ThemeRGB
        let input: ThemeRGB
        if let surfaceHex = seed.surface, let surface = ThemeRGB(hex: surfaceHex),
           surface.luminance >= background.luminance {
            card = surface
            input = background.mixed(with: surface, 0.45)
        } else {
            card = background.lifted(by: 0.070)
            input = background.lifted(by: 0.030)
        }

        // White on the accent needs luminance <= 0.30; the accent on the
        // card needs 3:1. Both hold only on a card this dark.
        let accentFloor = Contrast.accent * (card.luminance + 0.05) - 0.05
        guard accentFloor <= Self.accentCeiling else { return nil }

        let accent = seedAccent.luminance < accentFloor
            ? Self.blend(seedAccent, toward: .white) { $0.luminance >= accentFloor }
            : Self.readableUnderWhite(seedAccent)

        let primary = foreground.contrast(with: card) >= Contrast.primary
            ? foreground
            : Self.blend(foreground, toward: .white) { $0.contrast(with: card) >= Contrast.primary }
        guard primary.contrast(with: card) >= Contrast.primary else { return nil }
        func tier(_ target: Double) -> ThemeRGB {
            // The faintest mix toward the card that still holds `target`.
            Self.blend(card, toward: primary) { $0.contrast(with: card) >= target }
        }

        let ansi = (seed.ansi ?? []).compactMap(ThemeRGB.init(hex:))
        func status(_ indexes: [Int], hue: ClosedRange<Double>, wraps: Bool = false, fallback: ThemeRGB) -> ThemeRGB {
            for index in indexes where index < ansi.count {
                let candidate = ansi[index]
                let (h, s) = candidate.hueSaturation
                let inHue = wraps ? (h >= hue.upperBound || h <= hue.lowerBound) : hue.contains(h)
                if inHue, s >= 0.25, candidate.contrast(with: card) >= Contrast.status {
                    return candidate
                }
            }
            return Self.blend(fallback, toward: .white) { $0.contrast(with: card) >= Contrast.status }
        }

        self.init(
            seed: seed,
            background: background,
            header: background.lifted(by: 0.010),
            input: input,
            card: card,
            border: card.lifted(by: 0.090),
            textPrimary: primary,
            textSecondary: tier(Contrast.secondary),
            textTertiary: tier(Contrast.tertiary),
            accent: accent,
            // Bright ANSI first, then normal; only a colour that still
            // means the same thing (a green that is green) is taken.
            success: status([10, 2], hue: 80...170, fallback: Self.classicSuccess),
            warning: status([11, 3], hue: 25...65, fallback: Self.classicWarning),
            danger: status([9, 1], hue: 20...335, wraps: true, fallback: Self.classicDanger),
            info: status([14, 6, 12, 4], hue: 170...230, fallback: Self.classicInfo),
            routeYou: Self.classicRouteYou,
            routeFriend: Self.classicRouteFriend
        )
    }

    /// The lightest an accent may be for a white label to read on it.
    private static let accentCeiling = 1.05 / Contrast.accent - 0.05

    private static func readableUnderWhite(_ accent: ThemeRGB) -> ThemeRGB {
        blend(accent, toward: .black) { $0.luminance <= accentCeiling }
    }

    /// The colour nearest `start` on the way to `end` that satisfies
    /// `accept`; `end` itself if none does sooner.
    private static func blend(
        _ start: ThemeRGB, toward end: ThemeRGB, until accept: (ThemeRGB) -> Bool
    ) -> ThemeRGB {
        if accept(start) { return start }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if accept(start.mixed(with: end, middle)) { high = middle } else { low = middle }
        }
        return start.mixed(with: end, high)
    }
}

// MARK: - Bundled palettes with named surfaces

nonisolated extension AppTheme {
    private static func named(
        _ family: ThemeFamily, _ rows: [(String, String, String, String, String)]
    ) -> [AppTheme] {
        rows.compactMap { name, background, surface, foreground, accent in
            AppTheme(seed: ThemeSeed(
                family: family, name: name, background: background,
                foreground: foreground, accent: accent, surface: surface
            ))
        }
    }

    /// MacSpaces' own quiet palettes (its dark values).
    static let editorial: [AppTheme] = named(.editorial, [
        ("Noir", "0B0B0C", "18181A", "F2F2F2", "E8E8E8"),
        ("Midnight", "020714", "0C172B", "EEF5FF", "1F8CFF"),
        ("Rose", "141016", "1F1824", "F3EEF2", "FF6FA0"),
        ("Coral", "1B1529", "221B33", "F4E4D1", "EF705B"),
        ("Iris", "0E0D12", "15131B", "F5EFE5", "B794FC"),
        ("Cocoa", "1D1511", "2A1F19", "F0E1CF", "D9A57C"),
        ("Graphite", "17171A", "242428", "E2E0DC", "ABA9B2"),
        ("Moss", "111914", "1B271F", "DAE5DA", "9DBBA0"),
        ("Cherry", "1D0D12", "2D161D", "F5E0E4", "EC7D95"),
        ("Ember Glow", "1E0F0D", "301A16", "F6E2D4", "F0A678"),
        ("Lagoon", "06181D", "0F272E", "DCF1EF", "74D0C8"),
        ("Mulberry", "1A1020", "281A30", "F0E1EE", "D69CCF"),
        ("Ink", "0E1323", "192036", "FFF0CF", "93A2D8"),
    ])

    /// The editor favourites, with the surfaces MacSpaces gives them.
    static let editor: [AppTheme] = named(.editor, [
        ("Catppuccin", "1E1E2E", "313244", "CDD6F4", "CBA6F7"),
        ("Tokyo Night", "1A1B26", "24283B", "C0CAF5", "7AA2F7"),
        ("Rosé Pine", "191724", "1F1D2E", "E0DEF4", "EBBCBA"),
        ("Nord", "2E3440", "3B4252", "ECEFF4", "88C0D0"),
        ("Solarized", "002B36", "073642", "B6C8C8", "2AA198"),
        ("Everforest", "2D353B", "343F40", "D3C6AA", "A7C080"),
        ("Gruvbox", "282828", "3C3836", "EBDBB2", "FABD2F"),
        ("Monokai", "272822", "36372F", "F8F8F2", "A6E22E"),
        ("Ayu", "0B0E14", "131721", "BFBDB6", "E6B450"),
    ])
}
