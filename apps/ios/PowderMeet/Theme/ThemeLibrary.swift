//
//  ThemeLibrary.swift
//  PowderMeet
//
//  The bundled terminal palettes: Ghostty's themes (the
//  iTerm2-Color-Schemes collection), Base16 (Tinted Theming) and Gogh,
//  all MIT; notices are in Resources/Themes/ACKNOWLEDGEMENTS.txt. The two
//  JSON files are MacSpaces' own, unchanged, so they can be refreshed by
//  copying. Each row is [name, background, foreground, accent, the
//  sixteen ANSI colours as one hex string].
//
//  Only palettes `AppTheme(seed:)` accepts are kept: dark ones whose
//  text and accent stay readable.
//

import Foundation

nonisolated enum ThemeLibrary {
    struct Unreadable: Error {}

    /// Ghostty, Base16 and Gogh, each in its file's order.
    static func load(from bundle: Bundle) throws -> [ThemeFamily: [AppTheme]] {
        guard let ghosttyURL = bundle.url(forResource: "ghostty-themes", withExtension: "json"),
              let packsURL = bundle.url(forResource: "theme-packs", withExtension: "json")
        else { throw Unreadable() }
        return try parse(ghostty: Data(contentsOf: ghosttyURL), packs: Data(contentsOf: packsURL))
    }

    static func parse(ghostty: Data, packs: Data) throws -> [ThemeFamily: [AppTheme]] {
        let decoder = JSONDecoder()
        let ghosttyRows = try decoder.decode([[String]].self, from: ghostty)
        let packRows = try decoder.decode([String: [[String]]].self, from: packs)
        return [
            .ghostty: themes(ghosttyRows, family: .ghostty),
            .base16: themes(packRows["Base16"] ?? [], family: .base16),
            .gogh: themes(packRows["Gogh"] ?? [], family: .gogh),
        ]
    }

    private static func themes(_ rows: [[String]], family: ThemeFamily) -> [AppTheme] {
        rows.compactMap { row in
            guard row.count == 5, row[4].count == 96 else { return nil }
            let inks = Array(row[4])
            return AppTheme(seed: ThemeSeed(
                family: family, name: row[0], background: row[1], foreground: row[2], accent: row[3],
                ansi: (0..<16).map { String(inks[$0 * 6..<$0 * 6 + 6]) }
            ))
        }
    }
}
