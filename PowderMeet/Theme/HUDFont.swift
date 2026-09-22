//
//  HUDFont.swift
//  PowderMeet
//
//  The single semantic type scale for the HUD. Replaces ~441 ad-hoc
//  `.font(.system(size:…))` call sites that used 21 different sizes
//  and silently dropped the monospaced design at 137 of them.
//
//  A role maps to size, weight and tracking. Every color theme uses
//  the original monospaced PowderMeet face, with Dynamic Type scaling.
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

    /// Dynamic Type category that best matches the semantic role. We retain
    /// the compact mountain-HUD proportions at the default size while letting
    /// iOS scale text for skiers who use larger accessibility settings.
    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .display:  return .title2
        case .title:    return .headline
        case .section:  return .subheadline
        case .body:     return .body
        case .bodyEmph: return .body
        case .label:    return .caption
        case .caption:  return .caption2
        case .metric:   return .headline
        }
    }
}

extension HUDTheme {
    /// Color choices never change the original branded typography.
    static var activeFontDesign: Font.Design { .monospaced }

    /// Concrete font for a semantic role.
    static func font(_ role: HUDType) -> Font {
        .system(size: role.size, weight: role.weight, design: activeFontDesign)
    }
}

extension View {
    /// Apply a semantic type role: font (size, weight and branded design) and
    /// the role's tracking, in one modifier. The canonical replacement
    /// for inline `.font(.system(...)).tracking(...)`.
    func hudType(_ role: HUDType) -> some View {
        modifier(HUDTypeModifier(role: role))
    }
}

private struct HUDTypeModifier: ViewModifier {
    let role: HUDType
    @ScaledMetric private var scaledSize: CGFloat

    init(role: HUDType) {
        self.role = role
        _scaledSize = ScaledMetric(
            wrappedValue: role.size,
            relativeTo: role.relativeTextStyle
        )
    }

    func body(content: Content) -> some View {
        content
            .font(.system(
                size: scaledSize,
                weight: role.weight,
                design: HUDTheme.activeFontDesign
            ))
            .tracking(role.tracking)
    }
}
