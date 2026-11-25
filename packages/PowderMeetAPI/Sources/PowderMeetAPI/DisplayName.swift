import Foundation

/// The display-name rules the server applies in `profile_update`
/// (`backend/supabase/migrations/0013_display_names.sql`), run on the phone so
/// the name field can say what is wrong before anything is sent. The server
/// stays the authority: it also checks uniqueness and its block list, which the
/// phone asks about through `display_name_available`.
///
/// The steps and the character lists are the SQL function
/// `display_name_normalize`, in the same order; `DisplayNameTests` holds the
/// cases the pgTAP file `080_display_names.test.sql` checks.
public enum DisplayName {
    public static let minLength = 2
    public static let maxLength = 24

    /// Why a name cannot be used, as far as the phone can tell.
    public enum Problem: Sendable, Hashable {
        case tooShort, tooLong
    }

    /// NFKC, every kind of space to one ASCII space, control and invisible
    /// characters removed, runs of spaces collapsed, ends trimmed.
    public static func normalize(_ raw: String) -> String {
        var scalars: [Unicode.Scalar] = []
        for scalar in raw.precomposedStringWithCompatibilityMapping.unicodeScalars {
            if isSpace(scalar) {
                scalars.append(" ")
            } else if !isInvisible(scalar) {
                scalars.append(scalar)
            }
        }
        var out = String.UnicodeScalarView()
        for scalar in scalars where !(scalar == " " && (out.last == " " || out.isEmpty)) {
            out.append(scalar)
        }
        if out.last == " " { out.removeLast() }
        return String(out)
    }

    /// Length in code points, as Postgres `char_length` counts it (not
    /// grapheme clusters: an emoji family is several).
    public static func length(_ normalized: String) -> Int {
        normalized.unicodeScalars.count
    }

    /// The normalised name, or what is wrong with it.
    public static func validate(_ raw: String) -> Result<String, ProblemError> {
        let name = normalize(raw)
        let count = length(name)
        if count < minLength { return .failure(ProblemError(problem: .tooShort)) }
        if count > maxLength { return .failure(ProblemError(problem: .tooLong)) }
        return .success(name)
    }

    /// True for a name only the sign-up trigger gives (`display_name_is_placeholder`
    /// in 0019): "Skier" and six digits, "Skier" and twelve hex digits of the
    /// user id, or the bare "Skier" of the first schema. Search never lists them.
    public static func isPlaceholder(_ name: String) -> Bool {
        if name == "Skier" { return true }
        guard name.hasPrefix("Skier ") else { return false }
        let tail = name.dropFirst(6).unicodeScalars
        if tail.count == 6 { return tail.allSatisfy { ("0"..."9").contains($0) } }
        if tail.count == 12 { return tail.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
        return false
    }

    public struct ProblemError: Error, Sendable, Hashable {
        public var problem: Problem
    }

    /// `[[:space:]]` plus the Unicode spaces the SQL lists.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    /// Control characters and invisible format characters.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0xAD, 0x34F, 0x61C, 0x115F, 0x1160, 0x17B4, 0x17B5,
             0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x2800, 0x3164,
             0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xFFF0...0xFFFB, 0xE0000...0xE007F:
            true
        default:
            false
        }
    }
}

/// The answer of `display_name_available(p_name)`.
public enum DisplayNameAvailability: String, Sendable, Hashable, Codable {
    case available
    case invalid
    case taken = "name_taken"
    case notAllowed = "name_not_allowed"
}
