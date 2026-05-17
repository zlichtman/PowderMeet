//
//  HUDFont.swift
//  PowderMeet
//
//  The single semantic type scale for the HUD. Replaces ~441 ad-hoc
//  `.font(.system(size:…))` call sites that used 21 different sizes
//  and silently dropped the monospaced design at 137 of them.
//
//  A role maps to (size, weight, tracking). The DESIGN FAMILY is
//  resolved at render time from the active theme via
//  `HUDTheme.activeFontDesign`, so a theme swap repaints every text
//  routed through here — the exact Swift-Observation path
//  `HUDTheme.accent` already uses. `original` stays monospaced.
//
//  Call sites use `.hudType(.section)` in place of the old
//  `.font(.system(size: 11, weight: .bold, design: .monospaced))
//   .tracking(2)` pair.
//

import SwiftUI

/// Semantic text roles. Eight roles collapse the previous 21-value
/// size sprawl into a deliberate scale.
enum HUDType {
    case display    // 24 — hero numerals, splash, big brand
    case title      // 16 — sheet titles, card headlines
    case section    // 11 — SECTION HEADERS (tracking-heavy, uppercase)
    case body       // 12 — primary readable copy
    case bodyEmph   // 12 — emphasized body / inline values / CTA labels
    case label      //  9 — field labels, chips, captions-with-weight
    case caption    //  8 — timestamps, footnotes
    case metric     // 14 — stat-cell numerals

    var size: CGFloat {
        switch self {
        case .display:  return 24
        case .title:    return 16
        case .section:  return 11
        case .body:     return 12
        case .bodyEmph: return 12
        case .label:    return 9
        case .caption:  return 8
        case .metric:   return 14
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display:  return .bold
        case .title:    return .bold
        case .section:  return .bold
        case .body:     return .regular
        case .bodyEmph: return .semibold
        case .label:    return .medium
        case .caption:  return .regular
        case .metric:   return .bold
        }
    }

    /// Letter-spacing. Section headers and labels are uppercase chrome
    /// and want generous tracking; body copy stays tight.
    var tracking: CGFloat {
        switch self {
        case .section:        return 1.6
        case .label, .caption: return 1.0
        case .metric:         return 0.5
        case .title:          return 0.8
        default:              return 0.2
        }
    }
}

extension HUDTheme {
    /// The active theme's typeface family. Reading this in a view body
    /// registers a Swift Observation dependency on `activeTheme`, so a
    /// theme change repaints — same mechanism as `HUDTheme.accent`.
    static var activeFontDesign: Font.Design {
        ThemeManager.shared.activeTheme.fontDesign
    }

    /// Concrete `Font` for a semantic role, in the active theme's face.
    static func font(_ role: HUDType) -> Font {
        .system(size: role.size, weight: role.weight, design: activeFontDesign)
    }
}

extension View {
    /// Apply a semantic type role: font (size+weight+theme design) and
    /// the role's tracking, in one modifier. The canonical replacement
    /// for inline `.font(.system(...)).tracking(...)`.
    func hudType(_ role: HUDType) -> some View {
        self.font(HUDTheme.font(role)).tracking(role.tracking)
    }
}
