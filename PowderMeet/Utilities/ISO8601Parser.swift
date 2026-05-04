//
//  ISO8601Parser.swift
//  PowderMeet
//
//  Shared ISO 8601 timestamp parsing for activity-file parsers.
//  GPX, TCX, FIT all need the same dual-format dance: GPS-clean exports
//  emit `2024-03-12T12:30:00Z`, while Strava/Suunto-style exports emit
//  `2024-03-12T12:30:00.123Z`. `ISO8601DateFormatter` only matches one
//  format at a time — without a wrapper, every parser kept its own pair
//  of `nonisolated(unsafe)` formatters.
//
//  Apple docs: `ISO8601DateFormatter` is thread-safe for parsing, so a
//  single shared instance is fine across actors. The `nonisolated(unsafe)`
//  annotation is a Swift-6-isolation acknowledgement, not a real safety
//  loophole — there is no mutable state to race.
//

import Foundation

// `nonisolated` — called from XML parser delegates which run on background
// queues. Stored formatters are already `nonisolated(unsafe)`.
nonisolated enum ISO8601Parser {

    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Parse an ISO 8601 timestamp string. Tries the fractional-seconds
    /// flavor first (matches Strava / Suunto / Apple Health exports) and
    /// falls back to the plain flavor.
    static func parse(_ text: String) -> Date? {
        withFractional.date(from: text) ?? plain.date(from: text)
    }
}
