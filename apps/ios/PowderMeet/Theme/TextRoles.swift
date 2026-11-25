import SwiftUI

/// The app's one type scale: Apple's text styles (SF Pro, Dynamic Type), in
/// sentence or title case, standard weights, with no HUD lettering.
/// Every screen picks a role here, so the whole app changes together. Numbers
/// that tick (times, distances, ETAs) add `.monospacedDigit()` where they sit.
enum TextRole {
    /// Large numerals and the brand on full-screen states.
    case display
    /// A card's or a screen's headline.
    case title
    /// Section headers and emphasised small values.
    case section
    /// Readable copy.
    case body
    /// Row titles, names, button labels.
    case bodyEmph
    /// Detail lines under a title, chip details, field labels.
    case label
    /// The smallest print: timestamps, footnotes.
    case caption
    /// A stat's value.
    case metric

    var font: Font {
        switch self {
        case .display: .title2.weight(.bold)
        case .title: .title3.weight(.semibold)
        case .section: .subheadline.weight(.semibold)
        case .body: .body
        case .bodyEmph: .body.weight(.semibold)
        case .label: .footnote
        case .caption: .caption
        case .metric: .headline.monospacedDigit()
        }
    }
}

extension View {
    /// Sets the text in a role of the app's type scale.
    func textRole(_ role: TextRole) -> some View {
        font(role.font)
    }
}
