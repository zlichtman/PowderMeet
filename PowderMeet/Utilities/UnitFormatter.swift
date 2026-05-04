//
//  UnitFormatter.swift
//  PowderMeet
//
//  Locale-aware unit formatting. Follows Apple system settings
//  so users see °F / ft / mi / mph in US locale, and °C / m / km / km/h
//  in metric locales. No in-app setting — just respects the device.
//

import Foundation

// `nonisolated` — formatters are called from MountainNaming (now nonisolated)
// and other off-main-actor compute paths. Pure value formatting.
nonisolated enum UnitFormatter {

    // MARK: - Locale Detection

    /// True when the device uses metric measurement system.
    private static var isMetric: Bool {
        Locale.current.measurementSystem == .metric
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

    /// Formats elevation (stored in meters) with unit suffix.
    /// e.g. "2200M" or "7218FT"
    static func elevation(_ meters: Double) -> String {
        if isMetric {
            return "\(Int(meters))M"
        } else {
            let feet = meters * 3.28084
            return "\(Int(feet))FT"
        }
    }

    /// Formats elevation with label.
    /// e.g. "2200M ELEVATION" or "7218FT ELEVATION"
    static func elevationLabel(_ meters: Double) -> String {
        "\(elevation(meters)) ELEVATION"
    }

    // MARK: - Distance / Length

    /// Formats trail or route length (stored in meters).
    /// Shows smaller unit for short distances, larger for long.
    /// e.g. "850M" / "2.3KM" or "2789FT" / "1.4MI"
    static func distance(_ meters: Double) -> String {
        if isMetric {
            if meters >= 1000 {
                return String(format: "%.1fKM", meters / 1000)
            }
            return "\(Int(meters))M"
        } else {
            let feet = meters * 3.28084
            if feet >= 5280 {
                let miles = feet / 5280
                return String(format: "%.1fMI", miles)
            }
            return "\(Int(feet))FT"
        }
    }

    // MARK: - Vertical Drop

    /// Formats vertical drop (stored in meters).
    /// e.g. "450M" or "1476FT"
    static func verticalDrop(_ meters: Double) -> String {
        if isMetric {
            return "\(Int(meters))M"
        } else {
            let feet = meters * 3.28084
            return "\(Int(feet))FT"
        }
    }

    // MARK: - Wind Speed

    /// Formats wind speed (stored in km/h).
    /// e.g. "25 KPH" or "16 MPH"
    static func windSpeed(_ kph: Double) -> String {
        if isMetric {
            return String(format: "%.0f KPH", kph)
        } else {
            let mph = kph * 0.621371
            return String(format: "%.0f MPH", mph)
        }
    }

    // MARK: - Time

    /// Formats a duration in seconds as a compact string.
    /// Under one hour: "Xm Ys", one hour or more: "Xh Ym".
    /// Under one minute: "Xs".
    static func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins >= 60 {
            return "\(mins / 60)h \(mins % 60)m"
        }
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    // MARK: - Snowfall

    /// Formats snowfall (stored in cm).
    /// Returns nil if negligible (< 0.5 cm).
    /// e.g. "12CM NEW" or "5IN NEW"
    static func snowfall(_ cm: Double) -> String? {
        guard cm > 0.5 else { return nil }
        if isMetric {
            return String(format: "%.0fCM NEW", cm)
        } else {
            let inches = cm / 2.54
            return String(format: "%.0fIN NEW", inches)
        }
    }
}
