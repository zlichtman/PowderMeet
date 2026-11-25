import Foundation

/// A theme the user made: three colours, with everything else derived
/// the way a bundled palette's is.
struct CustomAppTheme: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name = "My theme"
    var accentHex = "EB3333"
    var backgroundHex = "0F0F12"
    var surfaceHex = "212124"

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [accentHex, backgroundHex, surfaceHex].allSatisfy {
                $0.count == 6 && $0.allSatisfy(\.isHexDigit)
            }
    }

    /// Nil when the background or cards are too light for the HUD's text.
    var appTheme: AppTheme? {
        AppTheme(seed: ThemeSeed(
            family: .custom, name: name, background: backgroundHex,
            foreground: "F2F2F5", accent: accentHex, surface: surfaceHex
        ))
    }
}
