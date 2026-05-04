//
//  PhoneNormalizer.swift
//  PowderMeet
//
//  Turns a raw phone-number string (whatever shape the user typed it into
//  Contacts in) into the *set* of digits-only candidate keys that should
//  match it server-side. Generating multiple candidates per contact is
//  the cheapest way to bridge the "+1 604…" vs "(604)…" divide without
//  pulling in a full libphonenumber dependency.
//
//  Why a Set, not a single canonical form: at sign-up time, Supabase
//  stores whatever the user entered (typically E.164 like "+16045551234").
//  At contact-match time, the user's address book may carry the same
//  number as just "(604) 555-1234" (national form). We don't know which
//  side has the country code, so we send both candidates and let the SQL
//  side do a digit-only equality test against either.
//
//  Server-side mirror: `find_users_by_phones(phones text[])` strips
//  non-digits from `auth.users.phone` and tests `= ANY(phones)`. That
//  comparison succeeds when ANY of the candidates we emitted here lines
//  up with the canonicalized stored number.
//
//  Scope deliberately narrow:
//   - No libphonenumber, no NDC table, no carrier-format logic.
//   - Country dial-code table covers ~50 regions hand-picked for product
//     reach. A region not on the list still works for digits-already-
//     in-E.164 contacts; only "national-only without leading +" entries
//     in unknown regions silently fall back to digits-only matching.
//

import Foundation

enum PhoneNormalizer {

    /// Region → country dial code (E.164 prefix, no `+`). Long prefixes
    /// listed in full ("420" for CZ) so `dialCode(forE164Digits:)` can
    /// pick the longest match first and not confuse Czech Republic with
    /// US/CA.
    private static let regionDialCodes: [String: String] = [
        "US": "1", "CA": "1", "MX": "52",
        "GB": "44", "IE": "353", "FR": "33", "DE": "49", "IT": "39",
        "ES": "34", "PT": "351", "NL": "31", "BE": "32", "CH": "41",
        "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358",
        "PL": "48", "CZ": "420", "GR": "30", "HU": "36", "RO": "40",
        "RU": "7", "UA": "380", "TR": "90", "IL": "972", "AE": "971",
        "SA": "966", "EG": "20", "ZA": "27",
        "AU": "61", "NZ": "64",
        "JP": "81", "KR": "82", "CN": "86", "HK": "852", "TW": "886",
        "SG": "65", "MY": "60", "TH": "66", "VN": "84", "PH": "63",
        "ID": "62", "IN": "91", "PK": "92", "BD": "880",
        "BR": "55", "AR": "54", "CL": "56", "CO": "57", "PE": "51",
    ]

    /// All known dial codes sorted longest-first. Lets `dialCode(forE164Digits:)`
    /// match "420…" (CZ) before "4…" (nothing) without backtracking.
    private static let sortedDialCodes: [String] = {
        Array(Set(regionDialCodes.values)).sorted { $0.count > $1.count }
    }()

    /// Returns every match candidate worth shipping to the server for a
    /// raw contact-card phone string. Each candidate is digits-only,
    /// minimum 7 characters (shorter than that is almost always either a
    /// shortcode, an extension, or a partial entry that would create
    /// false-positive matches).
    ///
    /// `defaultRegion` is the 2-letter ISO region used to expand
    /// national-form numbers. Defaults to the device locale; tests pass
    /// an explicit value so behavior is deterministic regardless of
    /// where the simulator is set.
    static func candidates(
        for raw: String,
        defaultRegion: String? = Locale.current.region?.identifier
    ) -> Set<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let hasPlus = trimmed.hasPrefix("+") || trimmed.hasPrefix("00")
        let digits = trimmed.filter(\.isWholeNumber)
        guard digits.count >= 7 else { return [] }

        var out: Set<String> = []

        if hasPlus {
            // Already an international form. Trust the prefix; emit
            // both the full E.164 digits and a national-only fallback
            // (in case the matched account stored only the national
            // form — rare, but Supabase Auth's phone column is whatever
            // the user typed at sign-up, not enforced E.164).
            out.insert(digits)
            if let dial = dialCode(forE164Digits: digits) {
                let national = String(digits.dropFirst(dial.count))
                if national.count >= 7 { out.insert(national) }
            }
            return out
        }

        // No international prefix. Emit:
        //   1) the bare digits (covers a contact stored without country code
        //      against a sign-up that did the same),
        //   2) digits with the user's local dial code prepended (covers a
        //      national-form contact against an E.164 sign-up).
        out.insert(digits)

        guard let region = defaultRegion?.uppercased(),
              let dial = regionDialCodes[region] else {
            return out
        }

        // If the digits already look like they include the country code
        // (start with the local dial code AND have enough remaining
        // digits to be a real number), emit a national-only sibling so a
        // sign-up that stored just the local 10-digit form still hits.
        if digits.hasPrefix(dial), digits.count > dial.count + 6 {
            out.insert(String(digits.dropFirst(dial.count)))
        } else {
            // Otherwise treat the digits as national and prepend the
            // country code to produce the E.164-shaped candidate.
            out.insert(dial + digits)
        }

        return out
    }

    /// Best-effort: given a digits-only E.164 string, return the country
    /// dial-code prefix it starts with, or nil if no known prefix matches.
    /// Caller uses this to derive the national form when an inbound
    /// number is already in international shape.
    static func dialCode(forE164Digits digits: String) -> String? {
        sortedDialCodes.first { digits.hasPrefix($0) }
    }
}
