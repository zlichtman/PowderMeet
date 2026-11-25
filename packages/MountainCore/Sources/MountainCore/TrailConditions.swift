import Foundation

/// A run's surface as three 0...1 meters for the run card (the GRM, MOG and
/// GLD batteries), from the groomed state, the run's pitch and aspect, and the
/// weather at the hour.
///
/// What the inputs lack, so the scores are honest about less:
/// - Moguls: a bundle flags a run the map says is left to bump up
///   (`Edge.moguls`, from `piste:grooming=mogul`); any other ungroomed run may
///   or may not have bumps, so it starts low. Nothing reports how big the
///   bumps are today: only pitch, new snow and freeze-thaw move either base.
/// - Snow freshness: a sample from an older conditions row carries only the
///   last 24 hours of snowfall, so there an older storm scores as none.
public struct TrailConditions: Sendable, Hashable {
    /// 0 not groomed, 1 freshly groomed.
    public var grooming: Double
    /// 0 smooth, 1 heavy moguls.
    public var moguls: Double
    /// 0 poor glide, 1 perfect.
    public var glide: Double

    public init(grooming: Double, moguls: Double, glide: Double) {
        self.grooming = grooming
        self.moguls = moguls
        self.glide = glide
    }

    /// - Parameters:
    ///   - groomed: today's grooming report, or the map's default; nil unknown
    ///     (scored as not groomed).
    ///   - mogulRun: the bundle flags the run as left to bump up.
    ///   - averagePitchDeg: the run's mean pitch, degrees.
    ///   - aspectDeg: the way the slope faces, degrees from north; nil unknown.
    ///   - weather: the weather at the hour; nil when there is none.
    public static func score(
        groomed: Bool?, mogulRun: Bool = false, averagePitchDeg: Double, aspectDeg: Double?,
        weather: ConditionsSample?
    ) -> TrailConditions {
        let grooming: Double
        if groomed == true {
            let fresh = weather.map { min(0.15, $0.snow24hCM * 0.015) } ?? 0
            grooming = min(1, 0.85 + fresh)
        } else {
            grooming = 0
        }

        var moguls = 0.0
        if groomed != true {
            let pitch = min(0.25, max(0, averagePitchDeg) / 120)
            var smoothing = 0.0, freezeThaw = 0.0
            if let weather {
                if weather.snow24hCM > 15 {
                    smoothing = -0.3
                } else if weather.snow24hCM > 5 {
                    smoothing = -0.15
                }
                if weather.tempC > -2, weather.tempC < 2 { freezeThaw = 0.1 }
            }
            // A flagged run's bumps are there by design, so it starts 0.4 higher:
            // at least one more bar than the same run unflagged, and still one
            // bar under a deep new snowfall that smooths an ordinary run to none.
            let base = mogulRun ? 0.55 : 0.15
            moguls = max(0, min(1, base + pitch + smoothing + freezeThaw))
        }

        let glide: Double
        if let weather {
            // Only a slope turned to the south loses glide to the sun.
            let sunPenalty = aspectDeg.map { max(0, cos(($0 - 180) * .pi / 180)) * 0.2 } ?? 0.1
            let raw = freshness(weather) * 0.5 + temperatureGlide(weather.tempC) * 0.35 + (1 - sunPenalty) * 0.15
            glide = max(0, min(1, raw))
        } else {
            glide = 0.5
        }
        return TrailConditions(grooming: grooming, moguls: moguls, glide: glide)
    }

    /// Freshness from 24-hour snowfall, then the 72-hour total and the depth
    /// where the sample has them (06-SOLVER section 2.2).
    static func freshness(_ weather: ConditionsSample) -> Double {
        if weather.snow24hCM > 10 { return 1 }
        if weather.snow24hCM > 3 { return 0.85 }
        if let recent = weather.snow72hCM {
            if recent > 15 { return 0.65 }
            if recent > 5 { return 0.45 }
        }
        if let depth = weather.snowDepthCM {
            if depth > 100 { return 0.35 }
            if depth > 50 { return 0.2 }
        }
        return 0.1
    }

    /// Wax works best from -7 to -3 °C. Each outer branch starts at its
    /// neighbour's end value, so the meter never jumps across 0 °C or -15 °C.
    static func temperatureGlide(_ t: Double) -> Double {
        if t >= -7, t <= -3 { return 1 }
        if t > 0 { return max(0, 0.7 * (1 - t / 6)) }
        if t < -15 { return max(0, 0.7 * (1 - (-t - 15) / 12)) }
        if t > -3 { return 0.7 + (t / -3) * 0.3 }
        return 1 - ((-7 - t) / 8) * 0.3
    }
}
