import Foundation

/// What the weather at the timeline's hour does to the map: falling snow,
/// wind lifting the new snow, cloud greying the light and poor visibility
/// closing the distance in. Each part is 0...1 in tenths, so scrubbing the
/// timeline changes the map only when the change would show, and every
/// change eases in on the style's own transitions.
public struct WeatherEffect: Sendable, Hashable {
    /// How hard it snows: 0 none, 1 heavy (3 mm of water an hour or more).
    public let snowfall: Double
    /// 0 calm, 1 at 15 m/s (54 km/h) or more.
    public let wind: Double
    /// Cloud cover.
    public let cloud: Double
    /// 0 clear air, 1 at 300 m of visibility or less.
    public let haze: Double
    /// Fresh snow on the ground, which a strong wind lifts into the air.
    public let freshSnow: Bool

    public init(snowfall: Double, wind: Double, cloud: Double, haze: Double, freshSnow: Bool) {
        func tenths(_ value: Double) -> Double { (max(0, min(1, value)) * 10).rounded() / 10 }
        self.snowfall = tenths(snowfall)
        self.wind = tenths(wind)
        self.cloud = tenths(cloud)
        self.haze = tenths(haze)
        self.freshSnow = freshSnow
    }

    /// From a forecast hour: `snowing` from its weather code, the rest from
    /// its figures.
    public init(
        snowing: Bool, precipMMH: Double, windMS: Double, cloudPct: Double, visibilityM: Double, snow24hCM: Double
    ) {
        let visibility = max(300, min(20_000, visibilityM))
        self.init(
            snowfall: snowing ? max(0.3, precipMMH / 3) : 0,
            wind: windMS / 15,
            cloud: cloudPct / 100,
            // Logarithmic: 20 km is clear, 2 km a little hazy, 300 m thick.
            haze: 1 - log(visibility / 300) / log(20_000 / 300),
            freshSnow: snow24hCM >= 5)
    }

    public static let clear = WeatherEffect(snowfall: 0, wind: 0, cloud: 0, haze: 0, freshSnow: false)

    /// Snow blown off the ground: strong wind over new snow, while none falls.
    var drift: Double {
        guard freshSnow, snowfall == 0 else { return 0 }
        return max(0, min(1, (wind - 0.4) / 0.6))
    }

    /// Anything moves on the map: falling or blowing snow.
    var hasParticles: Bool { snowfall > 0 || drift > 0 }

    /// The light and the sky only: what `MapStyle.applyLighting` needs.
    var skyKey: [Int] { [Int(cloud * 10), Int(haze * 10)] }
}

// MARK: Snow

/// What `SnowField` draws for one hour's weather: calm flakes falling down
/// the screen with a gentle slant, never swirling or streaming sideways.
struct SnowFall: Sendable, Hashable {
    /// Share of the most flakes the field ever holds, 0...1.
    var density: Double
    /// Flake size against the field's own sizes.
    var scale: Double
    /// Fall speed against the field's own speeds.
    var speed: Double
    /// Degrees off vertical the flakes drift by.
    var slant: Double
    var opacity: Double
    var colour: MapRGB
}

extension WeatherEffect {
    /// How long a change in the snow takes to ease in, and a clearing to
    /// thin it away.
    static let fade = 1.4

    /// White over the photo and the dark looks, a cold slate over
    /// Whiteout's white so the flakes still read.
    private static func flakeColour(on look: MapLook) -> MapRGB {
        switch look {
        case .satellite: MapRGB(hex: "ffffff")
        case .whiteout: MapRGB(hex: "6f86a3")
        case .blueprint: MapRGB(hex: "e6f6ff")
        case .holographic: MapRGB(hex: "fff0f0")
        }
    }

    /// The snowfall for this weather: always light, so the runs under it
    /// stay readable. Heavier snow is a little denser and bigger; wind
    /// speeds it a little and leans it a few degrees, no more, so it still
    /// reads as snow falling, not blowing past. Snow blown off the ground is
    /// finer, thinner and quicker.
    func snowFall(on look: MapLook) -> SnowFall {
        let colour = Self.flakeColour(on: look)
        if snowfall > 0 {
            return SnowFall(
                density: 0.45 + 0.55 * snowfall, scale: 0.85 + 0.25 * snowfall, speed: 1 + 0.3 * wind,
                slant: 4 + 10 * wind, opacity: 0.85, colour: colour)
        }
        return SnowFall(
            density: 0.25 + 0.3 * drift, scale: 0.7, speed: 1.3 + 0.3 * drift,
            slant: 12 + 6 * drift, opacity: 0.7, colour: colour)
    }
}
