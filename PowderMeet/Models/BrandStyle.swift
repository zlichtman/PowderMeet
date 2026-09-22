//
//  BrandStyle.swift
//  PowderMeet
//
//  Per-brand topsheet styling for ski silhouettes. The picker is only
//  meaningful if "I picked Atomic" produces a different ski than "I
//  picked Black Crows" — without this layer, every silhouette is the
//  same grey shape with text. Each registered brand maps to a hand-
//  tuned color palette + pattern that *evokes* the brand\'s topsheet
//  design language without copying brand artwork (palette only, no
//  marks). Unknown brands fall through to the PowderMeet house style.
//

import SwiftUI

/// Visual recipe for one brand\'s topsheet. Read by `HorizontalSkiView`
/// inside SkiPairView; produced by `BrandStyle.resolve(brand:)` against
/// a hardcoded registry seeded from `skis_catalog`.
struct BrandStyle: Sendable, Hashable {
    /// Dominant topsheet color.
    let primary: Color
    /// Secondary / accent color used by the pattern.
    let secondary: Color
    /// Tertiary highlight — used for the leading tip-cap on every ski
    /// regardless of pattern, so the front of the ski always reads as
    /// "front" with a saturated accent.
    let tip: Color
    /// Foreground color for the topsheet label. Picked for contrast
    /// against the pattern\'s dominant region, not against `primary` —
    /// some brands (Faction, Armada) split the topsheet with light and
    /// dark panels and the label sits on the lighter half.
    let text: Color
    /// How `primary` and `secondary` compose into the topsheet body.
    let pattern: Pattern

    enum Pattern: Sendable, Hashable {
        /// Single solid color (`primary`). Ignores `secondary`.
        case solid
        /// Diagonal stripes — `secondary` over `primary` background.
        case diagonalStripe
        /// Vertical color split — leading panel `primary`, trailing
        /// panel `secondary`. Common ski-shop look (e.g. Volkl Mantra).
        case verticalSplit
        /// Two horizontal bands stacked (top half `primary`, bottom
        /// half `secondary`). Reads as a "stripe down the topsheet."
        case horizontalSplit
        /// Linear gradient leading → trailing, `primary` → `secondary`.
        case gradientLength
        /// Asymmetric block: tip third in `secondary`, rest `primary`.
        /// The brand-style equivalent of "color block on the tip."
        case tipBlock
        /// Three vertical bars (`primary` / `secondary` / `primary`)
        /// down the length. Reads as a tricolor flag.
        case tricolor
        /// PowderMeet house signature: multi-stop gradient body, mid-
        /// length accent stripe, distinct tip and tail caps. Reserved
        /// for the house default — every other brand uses one of the
        /// generic patterns above.
        case signature
    }

    // MARK: - Registry

    /// PowderMeet house default — used when a friend hasn\'t picked a
    /// ski yet, or for the in-app placeholder. Brand-red gradient so
    /// it still reads as "PowderMeet" without an actual logo glyph.
    static let powderMeet = BrandStyle(
        // Deep navy core fading into charcoal — premium "we built this"
        // look that doesn\'t collide with any of the brand presets.
        primary: Color(red: 0.06, green: 0.10, blue: 0.20),
        // Accent stripe color — PowderMeet brand red, saturated.
        secondary: Color(red: 0.95, green: 0.20, blue: 0.22),
        // Gold tip cap — feels custom-shop, not stock.
        tip: Color(red: 1.00, green: 0.82, blue: 0.20),
        text: .white,
        pattern: .signature
    )

    /// Map of brand name (case-insensitive) → style. Each entry is
    /// hand-tuned to match the brand\'s identifiable color signature:
    /// the goal is "a skier who knows the brands recognizes it without
    /// reading the label."
    private static let registry: [String: BrandStyle] = [
        // — Atomic — bold red/orange, diagonal slash motif
        "atomic": BrandStyle(
            primary: Color(red: 0.92, green: 0.18, blue: 0.10),
            secondary: Color(red: 1.00, green: 0.55, blue: 0.05),
            tip: .white,
            text: .white,
            pattern: .diagonalStripe
        ),

        // — Black Crows — matte white body with deep black accent
        "black crows": BrandStyle(
            primary: Color(white: 0.92),
            secondary: Color(white: 0.06),
            tip: Color(red: 0.85, green: 0.20, blue: 0.20),
            text: Color(white: 0.06),
            pattern: .tipBlock
        ),

        // — Faction — saturated geometric blocks
        "faction": BrandStyle(
            primary: Color(red: 0.10, green: 0.22, blue: 0.45),
            secondary: Color(red: 0.95, green: 0.78, blue: 0.10),
            tip: Color(red: 0.95, green: 0.30, blue: 0.40),
            text: .white,
            pattern: .verticalSplit
        ),

        // — Rossignol — French tricolor (blue / white / red)
        "rossignol": BrandStyle(
            primary: Color(red: 0.10, green: 0.28, blue: 0.62),
            secondary: Color(red: 0.88, green: 0.15, blue: 0.20),
            tip: .white,
            text: .white,
            pattern: .tricolor
        ),

        // — K2 — silver/black with bold yellow stripe
        "k2": BrandStyle(
            primary: Color(white: 0.18),
            secondary: Color(red: 1.00, green: 0.85, blue: 0.05),
            tip: Color(red: 1.00, green: 0.85, blue: 0.05),
            text: .white,
            pattern: .horizontalSplit
        ),

        // — Salomon — matte white with red triangle accent
        "salomon": BrandStyle(
            primary: Color(white: 0.95),
            secondary: Color(red: 0.88, green: 0.18, blue: 0.18),
            tip: Color(red: 0.88, green: 0.18, blue: 0.18),
            text: Color(white: 0.10),
            pattern: .tipBlock
        ),

        // — Volkl — German yellow/black checker vibe
        "volkl": BrandStyle(
            primary: Color(red: 1.00, green: 0.80, blue: 0.05),
            secondary: Color(white: 0.06),
            tip: Color(white: 0.06),
            text: Color(white: 0.06),
            pattern: .verticalSplit
        ),

        // — Nordica — orange / white striping
        "nordica": BrandStyle(
            primary: Color(red: 0.97, green: 0.45, blue: 0.05),
            secondary: Color(white: 0.92),
            tip: Color(white: 0.06),
            text: .white,
            pattern: .diagonalStripe
        ),

        // — Head — red/white with diagonal slash
        "head": BrandStyle(
            primary: Color(red: 0.85, green: 0.10, blue: 0.10),
            secondary: Color(white: 0.95),
            tip: .white,
            text: .white,
            pattern: .diagonalStripe
        ),

        // — Blizzard — cyan/blue gradient (alpine sky)
        "blizzard": BrandStyle(
            primary: Color(red: 0.10, green: 0.45, blue: 0.82),
            secondary: Color(red: 0.45, green: 0.82, blue: 1.00),
            tip: .white,
            text: .white,
            pattern: .gradientLength
        ),

        // — DPS — silver / black minimal
        "dps": BrandStyle(
            primary: Color(white: 0.30),
            secondary: Color(white: 0.10),
            tip: Color(red: 0.95, green: 0.30, blue: 0.20),
            text: .white,
            pattern: .gradientLength
        ),

        // — Armada — bright multicolor abstract
        "armada": BrandStyle(
            primary: Color(red: 0.10, green: 0.10, blue: 0.10),
            secondary: Color(red: 0.95, green: 0.30, blue: 0.55),
            tip: Color(red: 0.20, green: 0.85, blue: 0.85),
            text: .white,
            pattern: .verticalSplit
        ),

        // — Line — bold pink/black playful
        "line": BrandStyle(
            primary: Color(red: 0.95, green: 0.22, blue: 0.50),
            secondary: Color(white: 0.06),
            tip: Color(red: 1.00, green: 0.85, blue: 0.05),
            text: .white,
            pattern: .horizontalSplit
        ),

        // — Stockli — Swiss white with red accent
        "stockli": BrandStyle(
            primary: Color(white: 0.95),
            secondary: Color(red: 0.85, green: 0.10, blue: 0.10),
            tip: Color(red: 0.85, green: 0.10, blue: 0.10),
            text: Color(white: 0.10),
            pattern: .tipBlock
        ),

        // — ON3P — earth tones (forest)
        "on3p": BrandStyle(
            primary: Color(red: 0.20, green: 0.30, blue: 0.18),
            secondary: Color(red: 0.55, green: 0.40, blue: 0.18),
            tip: Color(red: 0.95, green: 0.78, blue: 0.20),
            text: .white,
            pattern: .horizontalSplit
        ),

        // — Dynastar — red/orange gradient (volcanic)
        "dynastar": BrandStyle(
            primary: Color(red: 0.85, green: 0.15, blue: 0.10),
            secondary: Color(red: 1.00, green: 0.55, blue: 0.10),
            tip: .white,
            text: .white,
            pattern: .gradientLength
        ),

        // — Fischer — Austrian blue/yellow
        "fischer": BrandStyle(
            primary: Color(red: 0.10, green: 0.30, blue: 0.62),
            secondary: Color(red: 1.00, green: 0.82, blue: 0.10),
            tip: Color(red: 1.00, green: 0.82, blue: 0.10),
            text: .white,
            pattern: .verticalSplit
        ),

        // — Elan — silver/charcoal minimal
        "elan": BrandStyle(
            primary: Color(white: 0.85),
            secondary: Color(white: 0.30),
            tip: Color(red: 0.20, green: 0.50, blue: 0.85),
            text: Color(white: 0.10),
            pattern: .gradientLength
        ),

        // — Moment — black with cyan accent
        "moment": BrandStyle(
            primary: Color(white: 0.10),
            secondary: Color(red: 0.20, green: 0.65, blue: 0.95),
            tip: Color(red: 0.20, green: 0.65, blue: 0.95),
            text: .white,
            pattern: .tipBlock
        ),

        // — J Skis — pop-art bright
        "j skis": BrandStyle(
            primary: Color(red: 0.20, green: 0.45, blue: 0.95),
            secondary: Color(red: 0.95, green: 0.78, blue: 0.10),
            tip: Color(red: 0.95, green: 0.30, blue: 0.55),
            text: .white,
            pattern: .horizontalSplit
        ),

        // — Icelantic — earth-tones / topographic
        "icelantic": BrandStyle(
            primary: Color(red: 0.45, green: 0.32, blue: 0.20),
            secondary: Color(red: 0.85, green: 0.65, blue: 0.30),
            tip: Color(red: 0.95, green: 0.85, blue: 0.50),
            text: .white,
            pattern: .gradientLength
        ),

        // — Voile — military green / desert
        "voile": BrandStyle(
            primary: Color(red: 0.30, green: 0.38, blue: 0.20),
            secondary: Color(red: 0.65, green: 0.55, blue: 0.30),
            tip: Color(red: 0.95, green: 0.78, blue: 0.30),
            text: .white,
            pattern: .horizontalSplit
        ),

        // — Black Diamond — caution black/yellow
        "black diamond": BrandStyle(
            primary: Color(white: 0.06),
            secondary: Color(red: 1.00, green: 0.82, blue: 0.05),
            tip: Color(red: 1.00, green: 0.82, blue: 0.05),
            text: Color(red: 1.00, green: 0.82, blue: 0.05),
            pattern: .diagonalStripe
        ),

        // — PowderMeet — house default registered explicitly so users
        // who pick "PowderMeet House" from the catalog get the same
        // visual as the implicit default.
        "powdermeet": powderMeet,
    ]

    /// Lookup a registered brand. Case + whitespace insensitive;
    /// unknown brands fall through to the PowderMeet house default.
    static func resolve(brand: String) -> BrandStyle {
        let key = brand.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return registry[key] ?? powderMeet
    }
}
