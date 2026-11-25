import SwiftUI

/// The lettering of the skier's own name on their profile card. The system's
/// designs only, so every one scales with Dynamic Type and needs no font file.
enum NameFont: String, CaseIterable, Hashable {
    case standard, bubbly, serif, mono

    var title: String {
        switch self {
        case .standard: "Standard"
        case .bubbly: "Bubbly"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }

    /// The name's font at the profile card's size.
    var font: Font {
        switch self {
        case .standard: .title2.weight(.bold)
        case .bubbly: .system(.title2, design: .rounded).weight(.heavy)
        case .serif: .system(.title2, design: .serif).weight(.bold)
        case .mono: .system(.title3, design: .monospaced).weight(.bold)
        }
    }
}
