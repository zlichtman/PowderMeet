//
//  UnitFormatter.swift
//  PowderMeet
//
//  Unit formatting. Settings → Appearance → Units picks metric, imperial
//  or the device's measurement system (the default), so users see °F / ft /
//  mi / mph or °C / m / km / km/h.
//

import Foundation

/// The units choice, stored on this phone (`ThemeManager.selectUnits` writes
/// it and redraws the screens). Skis stay in centimetres and millimetres
/// whatever it says.
nonisolated enum UnitChoice: String, Sendable, Hashable, CaseIterable {
    case device, metric, imperial

    static let key = "pm.display.units"

    static var current: UnitChoice {
        UserDefaults.standard.string(forKey: key).flatMap(UnitChoice.init(rawValue:)) ?? .device
    }

    /// Temperature, lengths, snowfall, height and weight. A UK phone reports
    /// `.uk`, not `.metric`, but skis in °C and metres, so only `.us` is imperial.
    var isMetric: Bool {
        switch self {
        case .device: Locale.current.measurementSystem != .us
        case .metric: true
        case .imperial: false
        }
    }

    /// Wind and ground speed. The UK keeps miles per hour on the road, so a UK
    /// phone gets mph beside its metres and °C.
    var isMetricSpeed: Bool {
        switch self {
        case .device: Locale.current.measurementSystem == .metric
        case .metric: true
        case .imperial: false
        }
    }
}

// `nonisolated` — formatters are called from MountainNaming (now nonisolated)
// and other off-main-actor compute paths. Pure value formatting.
nonisolated enum UnitFormatter {

    // MARK: - Locale Detection

    /// True when distances, speeds and temperatures are shown in metric.
    private static var isMetric: Bool {
        UnitChoice.current.isMetric
    }

    /// True when speeds are shown in km/h.
    private static var isMetricSpeed: Bool {
        UnitChoice.current.isMetricSpeed
    }

    // MARK: - Temperature

    /// Formats Celsius value in the user's preferred unit.
    /// e.g. "-5°C" or "23°F"
    static func temperature(_ celsius: Double) -> String {
        if isMetric {
            return String(format: "%.0f°C", celsius)
        } else {
            let fahrenheit = celsius * 9.0 / 5.0 + 32.0
            return String(format: "%.0f°F", fahrenheit)
        }
    }

    // MARK: - Elevation

    /// Formats elevation (stored in meters) with unit suffix, digits grouped.
    /// e.g. "2,200 m" or "7,218 ft"
    static func elevation(_ meters: Double) -> String {
        isMetric ? "\(whole(meters)) m" : "\(whole(meters * 3.28084)) ft"
    }

    /// A whole number with the locale's grouping: 811345 → "811,345".
    private static func whole(_ value: Double) -> String {
        Int(value).formatted(.number)
    }

    // MARK: - Distance / Length

    /// Formats trail or route length (stored in meters).
    /// Shows smaller unit for short distances, larger for long.
    /// e.g. "850 m" / "2.3 km" or "2,789 ft" / "1.4 mi"
    static func distance(_ meters: Double) -> String {
        if isMetric {
            if meters >= 1000 {
                return String(format: "%.1f km", meters / 1000)
            }
            return "\(whole(meters)) m"
        } else {
            let feet = meters * 3.28084
            if feet >= 5280 {
                let miles = feet / 5280
                return String(format: "%.1f mi", miles)
            }
            return "\(whole(feet)) ft"
        }
    }

    // MARK: - Visibility

    /// How far one can see (stored in metres), one decimal under one unit:
    /// "0.4 km" / "5 km" or "0.3 mi" / "3 mi".
    static func visibility(_ meters: Double) -> String {
        let value = isMetric ? meters / 1000 : meters / 1609.344
        let unit = isMetric ? "km" : "mi"
        return value < 1 ? String(format: "%.1f \(unit)", value) : String(format: "%.0f \(unit)", value)
    }

    // MARK: - Vertical Drop

    /// Formats vertical drop (stored in meters), digits grouped.
    /// e.g. "450 m" or "811,345 ft"
    static func verticalDrop(_ meters: Double) -> String {
        isMetric ? "\(whole(meters)) m" : "\(whole(meters * 3.28084)) ft"
    }

    // MARK: - Wind Speed

    /// Formats wind speed (stored in km/h).
    /// e.g. "25 KPH" or "16 MPH"
    static func windSpeed(_ kph: Double) -> String {
        if isMetricSpeed {
            return String(format: "%.0f km/h", kph)
        } else {
            let mph = kph * 0.621371
            return String(format: "%.0f mph", mph)
        }
    }

    // MARK: - Speed

    /// Formats a ground speed (stored in m/s) in the user's preferred unit.
    /// e.g. "12.5 KPH" or "27.9 MPH". Callers apply their own empty-state
    /// handling (e.g. an em-dash for zero).
    static func speed(_ metersPerSecond: Double) -> String {
        if isMetricSpeed {
            return String(format: "%.1f km/h", metersPerSecond * 3.6)
        } else {
            return String(format: "%.1f mph", metersPerSecond * 2.23694)
        }
    }

    // MARK: - Body

    /// A stored height in the device's units: "178 CM" or "5'10\"".
    static func height(_ cm: Int) -> String {
        if isMetric { return "\(cm) cm" }
        let inches = Int((Double(cm) / 2.54).rounded())
        return "\(inches / 12)'\(inches % 12)\""
    }

    /// The height one step (a centimetre, or an inch) up or down, in centimetres.
    static func steppedHeight(_ cm: Int, by direction: Int) -> Int {
        if isMetric { return cm + direction }
        let inches = Int((Double(cm) / 2.54).rounded()) + direction
        return Int((Double(inches) * 2.54).rounded())
    }

    /// A stored weight in the device's units: "74 KG" or "165 LB".
    static func weight(_ kg: Int) -> String {
        isMetric ? "\(kg) kg" : "\(Int((Double(kg) * 2.20462).rounded())) lb"
    }

    /// The weight one step (a kilogram, or five pounds) up or down, in kilograms.
    static func steppedWeight(_ kg: Int, by direction: Int) -> Int {
        if isMetric { return kg + direction }
        let pounds = (Int((Double(kg) * 2.20462 / 5).rounded()) + direction) * 5
        return Int((Double(pounds) / 2.20462).rounded())
    }

    // MARK: - Time

    /// Formats a duration in seconds as a compact string.
    /// Under one hour: "Xm Ys", one hour or more: "Xh Ym".
    /// Under one minute: "Xs".
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0,
              let totalSeconds = Int(exactly: seconds.rounded(.down)) else { return "Unavailable" }
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins >= 60 {
            return "\(mins / 60) h \(mins % 60) min"
        }
        if mins > 0 {
            return "\(mins) min \(secs) s"
        }
        return "\(secs) s"
    }

    // MARK: - Snowfall

    /// Formats snowfall (stored in cm).
    /// Returns nil if negligible (< 0.5 cm).
    /// e.g. "12CM NEW" or "5IN NEW"
    static func snowfall(_ cm: Double) -> String? {
        guard cm > 0.5 else { return nil }
        if isMetric {
            return String(format: "%.0f cm", cm)
        } else {
            let inches = cm / 2.54
            return String(format: "%.0f in", inches)
        }
    }
}
