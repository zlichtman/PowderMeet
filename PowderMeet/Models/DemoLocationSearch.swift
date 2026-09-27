import Foundation

/// Search-only normalization. Never rewrites a trail label or graph identity.
nonisolated enum DemoLocationSearch {
    static func matches(_ name: String, query: String) -> Bool {
        let tokens = query.components(separatedBy: .whitespacesAndNewlines)
            .map(normalized).filter { !$0.isEmpty }
        let searchable = normalized(name)
        return tokens.allSatisfy(searchable.contains)
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}
