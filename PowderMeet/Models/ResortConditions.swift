//
//  ResortConditions.swift
//  PowderMeet
//
//  Live weather + computed per-trail condition scores.
//  Fetched from Open-Meteo. Computed scores power the
//  GRM / MOG / GLD battery indicators on EdgeInfoCard.
//

import Foundation

// MARK: - Resort-level weather conditions

struct HourlyCondition: Sendable, Codable {
    let time: Date
    let temperatureC: Double
    let snowfallCm: Double
    let cloudCoverPercent: Int
    let weatherCode: Int
    let windSpeedKph: Double
    let visibilityKm: Double

    /// Short SF Symbol name suitable for a one-glance weather icon. Mirrors
    /// the code mapping used by `ResortConditions.weatherDescription`.
    var sfSymbol: String {
        switch weatherCode {
        case 0:                 return "sun.max.fill"
        case 1, 2:              return "cloud.sun.fill"
        case 3:                 return "cloud.fill"
        case 45, 48:            return "cloud.fog.fill"
        case 51...55:           return "cloud.drizzle.fill"
        case 61...65, 80...82:  return "cloud.rain.fill"
        case 71...75, 77, 85, 86: return "cloud.snow.fill"
        case 95...99:           return "cloud.bolt.rain.fill"
        default:                return "cloud.fill"
        }
    }

    /// True for any snow- or storm-related code — drives timeline tick tinting
    /// and whether to show a "❄" badge on the scrubber.
    var isSnowy: Bool { [71, 73, 75, 77, 85, 86].contains(weatherCode) || snowfallCm > 0.05 }

    /// True for thunder/squall codes — shown as a red tick on the timeline.
    var isStormy: Bool { (95...99).contains(weatherCode) || windSpeedKph > 50 }
}

struct ResortConditions: Sendable {
    let resortId: String
    let temperatureC: Double
    let windSpeedKph: Double
    let windGustsKph: Double
    /// Cumulative snowfall over the last 24h. `var` because the fast
    /// `current`-only fetch leaves it at 0 and the deferred hourly fetch
    /// backfills it once the past_days array arrives.
    var snowfallLast24hCm: Double
    /// Cumulative snowfall over the last 72h. Same backfill pattern as 24h —
    /// powers the moderate/low branches of `powderQuality`.
    var snowfallLast72hCm: Double
    let snowDepthCm: Double
    let weatherCode: Int
    let visibilityKm: Double        // km (Open-Meteo returns meters, converted)
    let cloudCoverPercent: Int      // 0–100
    let windDirectionDeg: Int       // 0–360°
    let stationElevationM: Double   // DEM elevation of the weather query point (meters)
    let fetchedAt: Date

    /// 7-day hourly forecast starting from ~3 days back; used by the timeline
    /// scrubber to show projected/past conditions at the selected instant.
    /// Empty if the fetch didn't include hourly data.
    var hourlyForecast: [HourlyCondition] = []

    /// Historical hourly archive (up to ~3 months back) for deep scrubs.
    /// Populated lazily by `ConditionsService.historicalConditions`.
    var hourlyHistory: [HourlyCondition] = []

    /// Returns the best-matching hourly sample for the given instant, blending
    /// across `hourlyForecast` and `hourlyHistory`. Nil if neither covers it.
    /// Open-Meteo returns both arrays already sorted by time, so we binary-search
    /// instead of scanning — TimelineView calls this per tick on every body eval.
    func atTime(_ date: Date) -> HourlyCondition? {
        let historyHit = Self.nearest(in: hourlyHistory, to: date)
        let forecastHit = Self.nearest(in: hourlyForecast, to: date)
        switch (historyHit, forecastHit) {
        case (nil, nil): return nil
        case (let h?, nil): return h
        case (nil, let f?): return f
        case (let h?, let f?):
            return abs(h.time.timeIntervalSince(date)) <= abs(f.time.timeIntervalSince(date)) ? h : f
        }
    }

    /// Binary-search the sample nearest to `date` in a time-sorted array.
    private static func nearest(in samples: [HourlyCondition], to date: Date) -> HourlyCondition? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time < date { lo = mid + 1 } else { hi = mid }
        }
        let candidate = samples[lo]
        if lo > 0 {
            let prev = samples[lo - 1]
            if abs(prev.time.timeIntervalSince(date)) < abs(candidate.time.timeIntervalSince(date)) {
                return prev
            }
        }
        return candidate
    }

    /// Always returns an hourly-shaped snapshot for any instant. Uses the
    /// best matching hourly sample when available; otherwise falls back to
    /// the resort's current readings. Lets the UI/overlays assume they
    /// always have something to render against while the scrubber moves.
    func hourlySnapshot(at date: Date) -> HourlyCondition {
        if let hit = atTime(date) { return hit }
        return HourlyCondition(
            time: date,
            temperatureC: temperatureC,
            snowfallCm: 0,
            cloudCoverPercent: cloudCoverPercent,
            weatherCode: weatherCode,
            windSpeedKph: windSpeedKph,
            visibilityKm: visibilityKm
        )
    }


    // MARK: - Altitude-Adjusted Temperature

    /// Standard environmental lapse rate: -6.5°C per 1000m altitude gain.
    /// Returns the estimated temperature at the given elevation in meters.
    func temperatureAtElevation(_ elevationM: Double) -> Double {
        let deltaM = elevationM - stationElevationM
        return temperatureC + deltaM * (ConditionScoreConstants.Elevation.lapseRateCelsiusPerKm
            / ConditionScoreConstants.Elevation.altitudeDivisorMeters)
    }

    // MARK: - Computed Scores (0.0 – 1.0)

    /// How fresh the snow is: 1.0 = new snow in last 24h, 0.0 = no snow in 7+ days.
    var snowFreshnessScore: Double {
        let f = ConditionScoreConstants.Snow.Freshness.self
        if snowfallLast24hCm > f.maxThresholdCm  { return 1.0 }
        if snowfallLast24hCm > f.highThresholdCm { return 0.85 }
        if snowfallLast72hCm > f.moderate72hCm   { return 0.65 }
        if snowfallLast72hCm > f.low72hCm        { return 0.45 }
        if snowDepthCm       > f.depthHighCm     { return 0.35 }
        if snowDepthCm       > f.depthLowCm      { return 0.20 }
        return 0.10
    }

    /// How good the temperature is for glide: peaks at -3°C to -7°C.
    var temperatureGlideScore: Double {
        let t = temperatureC
        let g = ConditionScoreConstants.Glide.Temperature.self
        if t >= g.optimalRangeMinC && t <= g.optimalRangeMaxC { return 1.0 }
        if t > g.warmBoundaryC                                 { return max(0, 1.0 - t / g.warmDenom) }
        if t < g.veryColdBoundaryC                             { return max(0, 1.0 - (-t - (-g.veryColdBoundaryC)) / g.veryColdDenom) }
        if t > g.coolTransitionC                               { return g.coolBaseline + ((t - g.warmBoundaryC) / g.coolTransitionC) * g.coolRange }
        return 1.0 - ((g.optimalRangeMinC - t) / g.coldDenom) * g.coolRange
    }

    // MARK: - Display Helpers

    var weatherDescription: String {
        switch weatherCode {
        case 0:        return "CLEAR"
        case 1, 2, 3:  return "PARTLY CLOUDY"
        case 45, 48:   return "FOG"
        case 51...55:  return "DRIZZLE"
        case 61...65:  return "RAIN"
        case 71...75:  return "SNOW"
        case 77:       return "SNOW GRAINS"
        case 80...82:  return "SHOWERS"
        case 85, 86:   return "SNOW SHOWERS"
        case 95...99:  return "STORM"
        default:       return "—"
        }
    }

    var isSnowing: Bool { [71,73,75,77,85,86].contains(weatherCode) }

    var temperatureDisplay: String {
        UnitFormatter.temperature(temperatureC)
    }

    var windDisplay: String {
        UnitFormatter.windSpeed(windSpeedKph)
    }

    var snowfallDisplay: String? {
        UnitFormatter.snowfall(snowfallLast24hCm)
    }
}

// MARK: - Per-trail computed scores

struct TrailConditionScore: Sendable {
    let groomingLevel: Double  // 0.0 = not groomed,  1.0 = freshly groomed
    let mogulLevel: Double     // 0.0 = smooth,        1.0 = heavy moguls
    let glideScore: Double     // 0.0 = poor glide,    1.0 = perfect glide

    // MARK: - Factory

    /// Computes trail condition scores from edge attributes and live weather.
    ///
    /// Data sources:
    /// - **Grooming**: `isGroomed` flag from enrichment APIs (Epic/MtnPowder) or OSM.
    ///   This is the best available data — resort grooming reports are updated daily
    ///   by the resort operations team via these feeds. Binary: groomed or not.
    ///
    /// - **Moguls**: Combination of the `hasMoguls` flag (from enrichment/OSM) and
    ///   trail gradient. Steeper ungroomed trails develop moguls faster. We factor in
    ///   snow age (fresh snow smooths moguls temporarily) and temperature (freeze-thaw
    ///   cycles harden moguls). No crowd data available.
    ///
    /// - **Glide**: Computed from live weather — snow freshness, temperature (ideal
    ///   -3°C to -7°C for wax performance), and sun exposure via trail aspect.
    ///   This is the most accurately computed score since it uses real weather data.
    static func compute(for edge: GraphEdge, conditions: ResortConditions?) -> TrailConditionScore {

        // ── Grooming ──
        // Source: Epic/MtnPowder enrichment sets `isGroomed` from daily resort reports.
        // For resorts without enrichment, falls back to OSM tag or difficulty-based default.
        // `isOfficiallyValidated` indicates the flag came from an authoritative source.
        let grooming: Double
        let g = ConditionScoreConstants.Snow.Grooming.self
        // Tri-state grooming: nil (unknown) is conservatively treated as
        // ungroomed for scoring since unknown-grooming trails in practice
        // skew ungroomed at most resorts we've audited.
        if edge.attributes.isGroomed == true {
            // Groomed trails degrade through the day — fresh snow helps
            if let c = conditions {
                let freshBonus = min(g.freshBonusMax, c.snowfallLast24hCm * g.freshBonusPerCm)
                grooming = min(g.maxScoreIfGroomed, g.baseScoreIfGroomed + freshBonus)
            } else {
                grooming = g.baseScoreIfGroomed
            }
        } else {
            grooming = 0.0
        }

        // ── Moguls ──
        // Base: `hasMoguls` flag from enrichment/OSM. If true, start at 0.6.
        // Gradient: steeper ungroomed trails build moguls faster.
        // Snow: fresh snow temporarily smooths moguls.
        // Temperature: freeze-thaw (near 0°C) hardens and defines moguls.
        let moguls: Double
        let m = ConditionScoreConstants.Moguls.self
        if edge.attributes.isGroomed == true {
            moguls = 0.0
        } else {
            let baseMogul: Double = edge.attributes.hasMoguls ? m.baseIfFlagged : m.baseIfNotFlagged
            let gradientFactor = min(m.gradientFactorCap, edge.attributes.averageGradient / m.gradientFactorDenom)

            // Fresh snow smooths moguls temporarily
            let snowSmoothing: Double
            if let c = conditions {
                if c.snowfallLast24hCm > m.FreshSnowSmoothing.heavyThresholdCm {
                    snowSmoothing = m.FreshSnowSmoothing.heavyFactor
                } else if c.snowfallLast24hCm > m.FreshSnowSmoothing.moderateThresholdCm {
                    snowSmoothing = m.FreshSnowSmoothing.moderateFactor
                } else {
                    snowSmoothing = 0
                }
            } else {
                snowSmoothing = 0
            }

            // Freeze-thaw hardens moguls
            let freezeThaw: Double
            if let c = conditions {
                let t = c.temperatureC
                freezeThaw = (t > m.FreezeThaw.minTempC && t < m.FreezeThaw.maxTempC) ? m.FreezeThaw.hardeningFactor : 0
            } else {
                freezeThaw = 0
            }

            moguls = max(0, min(1.0, baseMogul + gradientFactor + snowSmoothing + freezeThaw))
        }

        // ── Glide ──
        // Computed from live weather — most accurate score.
        // Snow freshness (50%), temperature for wax performance (35%),
        // sun exposure via aspect — south-facing = more sun = ice/slush (15%).
        let glide: Double
        let sc = ConditionScoreConstants.Glide.Scoring.self
        let sun = ConditionScoreConstants.Glide.Sun.self
        if let c = conditions {
            let sunPenalty: Double
            if let aspect = edge.attributes.aspect {
                let southFacing = abs(cos((aspect - sun.aspectOffsetDegrees) * .pi / 180.0))
                sunPenalty = southFacing * sun.penaltyScale
            } else {
                sunPenalty = sun.unknownAspectPenalty
            }
            let raw = c.snowFreshnessScore * sc.freshnessWeight
                    + c.temperatureGlideScore * sc.temperatureWeight
                    + (1.0 - sunPenalty) * sc.sunExposureWeight
            glide = max(0, min(1, raw))
        } else {
            glide = sc.defaultNoConditions
        }

        return TrailConditionScore(
            groomingLevel: grooming,
            mogulLevel: moguls,
            glideScore: glide
        )
    }
}
