import Foundation
import MapboxAdapter
import MountainCore

/// Wording for a WMO weather code, read off a `ConditionsSample`. Display only.
nonisolated enum MapWeather {
    static func kph(_ metersPerSecond: Double) -> Double { metersPerSecond * 3.6 }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61...65, 80...82: "cloud.rain.fill"
        case 71...75, 77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...55: "Drizzle"
        case 56, 57, 66, 67: "Freezing rain"
        case 61...65: "Rain"
        case 71...75: "Snow"
        case 77: "Snow grains"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95...99: "Storm"
        default: "—"
        }
    }

    // Samples carry the hour's precipitation and the 24-hour total but no
    // hourly snowfall rate, so the weather code decides.
    static func isSnowy(_ sample: ConditionsSample) -> Bool {
        [71, 73, 75, 77, 85, 86].contains(sample.weatherCode)
    }

    /// "1 cm/h": how hard it is snowing, from the hour's precipitation (mm of
    /// water an hour) at the usual ten to one; nil when nothing falls.
    static func snowfallRate(_ sample: ConditionsSample) -> String? {
        guard sample.precipMMH > 0.05 else { return nil }
        let cmPerHour = sample.precipMMH
        if UnitChoice.current.isMetric {
            return cmPerHour < 1 ? String(format: "%.1f cm/h", cmPerHour) : String(format: "%.0f cm/h", cmPerHour)
        }
        let inches = cmPerHour / 2.54
        return inches < 1 ? String(format: "%.1f in/h", inches) : String(format: "%.0f in/h", inches)
    }

    /// What the hour's weather does to the map (`WeatherEffect`).
    static func effect(_ sample: ConditionsSample) -> WeatherEffect {
        WeatherEffect(
            snowing: isSnowy(sample), precipMMH: sample.precipMMH, windMS: sample.windMS,
            cloudPct: sample.cloudPct, visibilityM: sample.visibilityM, snow24hCM: sample.snow24hCM)
    }

    static func isStormy(_ sample: ConditionsSample) -> Bool {
        (95...99).contains(sample.weatherCode) || kph(sample.windMS) > 50
    }
}
