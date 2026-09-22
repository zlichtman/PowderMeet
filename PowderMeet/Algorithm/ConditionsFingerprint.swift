//
//  ConditionsFingerprint.swift
//  PowderMeet
//
//  Deterministic stringifier for the (weather + surface) state at the
//  moment an edge was traversed. Audit Phase 2.1 — `profile_edge_speeds`
//  has a `conditions_fp` PK column that defaults to `'default'`; this
//  helper produces the values that populate the column at import /
//  live-record time, so future solver selection can read the matching
//  bucket instead of a single conflated rolling average.
//
//  Bucketing is intentionally coarse: a Whistler-cold day at -10°C and
//  a regular Vail morning at -2°C should land in different buckets, but
//  not -1°C vs -2°C — that just shreds the sample count without
//  meaningfully changing the predicted speed. Buckets:
//
//  - temperature: 5°C bins      (`tempC=-10`, `tempC=0`, `tempC=5`)
//  - wind speed:  10 km/h bins  (`wind=0`, `wind=20`, `wind=40`)
//  - fresh snow:  5 cm bins, ceil
//                 (`snow=0`, `snow=5`, `snow=15`)
//  - visibility:  3 km bins, capped at 15 km (`vis=3`, `vis=12`, `vis=15`)
//  - cloud cover: 25% bins      (`cloud=0`, `cloud=25`, `cloud=75`)
//  - surface:     three boolean flags from the matched edge — moguls,
//                 ungroomed, gladed. Surface is part of the fp because
//                 the same skier handles a moguled black very
//                 differently from a groomed black even with identical
//                 weather.
//
//  Output is a `|`-joined `key=value` string with components in fixed
//  alphabetical order so two clients producing the same fingerprint
//  always emit byte-identical strings.
//

import Foundation

nonisolated enum ConditionsFingerprint {

    /// `nil` is the "unknown" sentinel — caller should default to
    /// `"default"` so the legacy bucket rows continue to receive
    /// uncorrelated data. The non-default branch only fires when the
    /// caller has authoritative weather state to fingerprint against
    /// (live recorder reading the resort's current ConditionsService
    /// snapshot, importer for today's runs, etc.).
    static func fingerprint(
        temperatureC: Double?,
        windSpeedKph: Double?,
        snowfallLast24hCm: Double?,
        visibilityKm: Double?,
        cloudCoverPercent: Int?,
        surface: SurfaceFlags
    ) -> String {
        var parts: [String] = []

        if let t = temperatureC {
            parts.append("tempC=\(bucket(t, by: 5))")
        }
        if let w = windSpeedKph {
            parts.append("wind=\(bucket(w, by: 10))")
        }
        if let s = snowfallLast24hCm {
            parts.append("snow=\(bucketCeil(s, by: 5))")
        }
        if let v = visibilityKm {
            // Cap at 15 — anything past that is "clear day" to the eye
            // and we don't gain anything from finer bins.
            let capped = min(v, 15)
            parts.append("vis=\(bucket(capped, by: 3))")
        }
        if let c = cloudCoverPercent {
            parts.append("cloud=\(bucketInt(c, by: 25))")
        }
        // Surface flags — fixed key order so the output is stable.
        parts.append("moguls=\(surface.hasMoguls ? "1" : "0")")
        parts.append("ungroomed=\(surface.isUngroomed ? "1" : "0")")
        parts.append("gladed=\(surface.isGladed ? "1" : "0")")

        // Sort to guarantee deterministic ordering even if a future
        // edit reorders the appends above.
        parts.sort()
        return parts.joined(separator: "|")
    }

    /// Sentinel bucket for runs imported without authoritative weather
    /// state (e.g. an old Slopes file from last season — we don't
    /// re-fetch historical weather per row). The DB column already
    /// defaults to this string, so callers can use `defaultBucket` as
    /// the explicit "skip bucketing" flag rather than guessing.
    static let defaultBucket = "default"

    /// Surface flags — what the matched edge looked like at the time
    /// the run was made. Ordered fields so the call site at the
    /// importer can `.init(from: matchedRun)` without juggling.
    nonisolated struct SurfaceFlags {
        let hasMoguls: Bool
        let isUngroomed: Bool
        let isGladed: Bool

        static let unknown = SurfaceFlags(hasMoguls: false, isUngroomed: false, isGladed: false)
    }

    // MARK: - Bucketers

    /// Floor-to-bucket for Doubles. Negative values bucket toward
    /// negative infinity (so -2 → -5 with bin=5), keeping the math
    /// monotonic across freezing point.
    private static func bucket(_ value: Double, by binSize: Double) -> Int {
        Int((value / binSize).rounded(.down)) * Int(binSize)
    }

    /// Ceil-to-bucket — used for snowfall so a 4cm dump is bin "5"
    /// rather than "0", since the runs ARE on fresh snow even if it
    /// hasn't crossed the next threshold yet.
    private static func bucketCeil(_ value: Double, by binSize: Double) -> Int {
        Int((value / binSize).rounded(.up)) * Int(binSize)
    }

    private static func bucketInt(_ value: Int, by binSize: Int) -> Int {
        (value / binSize) * binSize
    }
}
