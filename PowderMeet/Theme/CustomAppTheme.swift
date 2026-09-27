import Foundation

struct CustomAppTheme: Codable, Identifiable, Equatable {
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

    var hasReadableSurfaces: Bool {
        [backgroundHex, surfaceHex].allSatisfy { hex in
            guard let rgb = UInt32(hex, radix: 16) else { return false }
            let channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)].map { value in
                let c = value / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
            return 1.05 / (luminance + 0.05) >= 7
        }
    }
}
