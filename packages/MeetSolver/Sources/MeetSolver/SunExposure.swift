import Foundation

/// Sun on a slope from an absolute instant and the mountain's own position. It
/// never reads the device time zone (invariant I-06).
enum SunExposure {
    struct SolarPosition {
        let altitudeDeg: Double
        let azimuthDeg: Double
    }

    /// 0 = full shade, 1 = full sun. An unknown aspect reads as a slope half
    /// turned to the sun, so it fades in from the horizon like any other and
    /// never jumps at sunrise (I-04).
    static func exposure(
        aspectDeg: Double?, at date: Date, latitude: Double, longitude: Double, cloudPct: Double
    ) -> Double {
        let solar = solarPosition(date: date, latitude: latitude, longitude: longitude)
        guard solar.altitudeDeg > 0 else { return 0 }
        let facing: Double
        if let aspectDeg {
            var difference = abs(solar.azimuthDeg - aspectDeg)
            if difference > 180 { difference = 360 - difference }
            facing = max(0, cos(difference * .pi / 180))
        } else {
            facing = 0.5
        }
        let intensity = sin(solar.altitudeDeg * .pi / 180)
        return facing * intensity * (1 - cloudPct / 100 * 0.7)
    }

    /// Continuous in both exposure and temperature, so leaving an edge later never
    /// completes it earlier. `hardPack` and `slush` switch the two halves off
    /// for the plain-weather search behind `WeatherFavour`; with both on the
    /// arithmetic is unchanged.
    static func speedMultiplier(
        exposure: Double, temperatureC: Double, hardPack: Bool = true, slush: Bool = true
    ) -> Double {
        func unit(_ value: Double) -> Double { max(0, min(1, value)) }
        let shaded = hardPack ? 0.20 * unit((-temperatureC - 3) / 2) * unit((0.25 - exposure) / 0.25) : 0
        let soft = slush ? 0.25 * unit((temperatureC + 1) / 3) * unit((exposure - 0.35) / 0.35) : 0
        return max(0.75, 1 - max(shaded, soft))
    }

    static func solarPosition(date: Date, latitude: Double, longitude: Double) -> SolarPosition {
        // Day of year and UTC hour by arithmetic from 2001-01-01T00:00Z.
        let seconds = date.timeIntervalSinceReferenceDate
        let dayIndex = (seconds / 86_400).rounded(.down)
        let utcHour = (seconds - dayIndex * 86_400) / 3_600
        let dayOfYear = Double(Self.dayOfYear(daysSince2001: Int(dayIndex)))

        let declination = 23.45 * sin((360.0 / 365.0 * (284 + dayOfYear)) * .pi / 180)
        let b = (360.0 / 365.0 * (dayOfYear - 81)) * .pi / 180
        let equationOfTimeMinutes = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)
        let solarNoonUTC = 12.0 - longitude / 15.0 - equationOfTimeMinutes / 60.0
        let hourAngle = (utcHour - solarNoonUTC) * 15.0

        let lat = latitude * .pi / 180
        let dec = declination * .pi / 180
        let ha = hourAngle * .pi / 180
        let sinAltitude = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)
        let altitude = asin(max(-1, min(1, sinAltitude))) * 180 / .pi
        let azimuth = (atan2(sin(ha), cos(ha) * sin(lat) - tan(dec) * cos(lat)) * 180 / .pi + 180)
            .truncatingRemainder(dividingBy: 360)
        return SolarPosition(altitudeDeg: altitude, azimuthDeg: azimuth)
    }

    /// 1-based ordinal day in the Gregorian year containing the given day.
    static func dayOfYear(daysSince2001 days: Int) -> Int {
        // 2001-01-01 begins a 400-year Gregorian cycle of 146,097 days.
        var remaining = ((days % 146_097) + 146_097) % 146_097
        var year = 2001
        while true {
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let length = leap ? 366 : 365
            if remaining < length { return remaining + 1 }
            remaining -= length
            year += 1
        }
    }
}
