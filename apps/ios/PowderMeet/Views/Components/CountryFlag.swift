import Foundation

/// A country's flag from its English name as the resort catalog writes it.
nonisolated enum CountryFlag {
    /// Names the catalog uses that are not the region's English name.
    private static let aliases = ["USA": "US", "UK": "GB", "South Korea": "KR", "Czechia": "CZ", "China": "CN"]

    private static let codes: [String: String] = {
        let english = Locale(identifier: "en_US")
        var codes: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            if let name = english.localizedString(forRegionCode: region.identifier) { codes[name] = region.identifier }
        }
        return codes.merging(aliases) { _, alias in alias }
    }()

    static func emoji(for country: String) -> String? {
        guard let code = codes[country] else { return nil }
        // A flag is the two regional-indicator letters of the ISO code.
        let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : nil
    }
}
