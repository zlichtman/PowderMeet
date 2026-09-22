//
//  SunExposureCalculator.swift
//  PowderMeet
//
//  Computes sun/shade status for trail segments based on:
//  - Time of day -> solar azimuth and altitude (with equation of time + longitude correction)
//  - Trail aspect (compass direction of the fall line)
//  - Aspect variance (attenuates exposure for winding trails)
//  - Cloud cover (attenuates sun intensity)
//  - Latitude and longitude of the resort
//

import Foundation
import CoreLocation

struct SunExposure {
    let sunAltitude: Double     // degrees above horizon
    let sunAzimuth: Double      // compass bearing of the sun
    let exposureFactor: Double  // 0.0 = full shade, 1.0 = full sun
    let snowCondition: SnowConditionModifier

    enum SnowConditionModifier: String {
        case hardPack
        case softPack
        case slush
        case normal
    }
}

// `nonisolated` — called from solver Dijkstra (detached compute). Pure trig.
nonisolated enum SunExposureCalculator {

    static func exposure(
        for edge: GraphEdge,
        at date: Date,
        resortLatitude: Double,
        resortLongitude: Double? = nil,
        temperatureC: Double = -2,
        cloudCoverPercent: Int = 0
    ) -> SunExposure {
        let solar = solarPosition(date: date, latitude: resortLatitude, longitude: resortLongitude)

        guard solar.altitude > 0 else {
            return SunExposure(
                sunAltitude: solar.altitude, sunAzimuth: solar.azimuth,
                exposureFactor: 0, snowCondition: .hardPack
            )
        }

        guard let aspect = edge.attributes.aspect else {
            return SunExposure(
                sunAltitude: solar.altitude, sunAzimuth: solar.azimuth,
                exposureFactor: 0.5, snowCondition: .normal
            )
        }

        var angleDiff = abs(solar.azimuth - aspect)
        if angleDiff > 180 { angleDiff = 360 - angleDiff }

        let exposureFactor = max(0, cos(angleDiff * .pi / 180))
        let intensityFactor = sin(solar.altitude * .pi / 180)
        // Attenuate by aspect variance: switchback trails (high variance) don't
        // consistently face the sun, so their effective exposure is reduced.
        let varianceAttenuation = 1.0 - (edge.attributes.aspectVariance * 0.7)
        // Cloud cover attenuation: overcast skies reduce direct sun exposure
        let cloudAttenuation = 1.0 - Double(cloudCoverPercent) / 100.0 * 0.7
        let effectiveExposure = exposureFactor * intensityFactor * varianceAttenuation * cloudAttenuation

        let condition: SunExposure.SnowConditionModifier
        if effectiveExposure > 0.7 && temperatureC > -1 {
            condition = .slush
        } else if effectiveExposure < 0.2 && temperatureC < -3 {
            condition = .hardPack
        } else if effectiveExposure > 0.3 {
            condition = .softPack
        } else {
            condition = .normal
        }

        return SunExposure(
            sunAltitude: solar.altitude, sunAzimuth: solar.azimuth,
            exposureFactor: effectiveExposure, snowCondition: condition
        )
    }

    /// Continuous routing physics derived from the same exposure signal used
    /// by the map. Display buckets remain useful labels, but must not create a
    /// step change in travel time at sunrise or at -1/-3°C: time-dependent
    /// Dijkstra requires leaving an edge later to never complete it earlier.
    static func routingSpeedMultiplier(
        exposure: SunExposure,
        temperatureC: Double
    ) -> Double {
        func unit(_ value: Double) -> Double { max(0, min(1, value)) }

        // Cold shaded snow firms progressively below -3°C, reaching the old
        // 0.8 floor by -5°C only in full shade.
        let coldSeverity = unit((-temperatureC - 3) / 2)
        let shadeSeverity = unit((0.25 - exposure.exposureFactor) / 0.25)
        let hardPackPenalty = 0.20 * coldSeverity * shadeSeverity

        // Warm sun-exposed snow softens progressively above -1°C. Full slush
        // penalty arrives only after both warmth and direct exposure are high.
        let warmSeverity = unit((temperatureC + 1) / 3)
        let sunSeverity = unit((exposure.exposureFactor - 0.35) / 0.35)
        let slushPenalty = 0.25 * warmSeverity * sunSeverity

        return max(0.75, 1 - max(hardPackPenalty, slushPenalty))
    }

    // MARK: - Solar Position

    struct SolarPosition {
        let altitude: Double
        let azimuth: Double
    }

    /// Calculates solar position from an absolute UTC instant, equation of time,
    /// and the mountain's longitude. This must never use the device timezone:
    /// users can inspect or plan a mountain while their phone is still set to a
    /// different zone, and routing physics must remain identical everywhere.
    static func solarPosition(date: Date, latitude: Double, longitude: Double? = nil) -> SolarPosition {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let utcHour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60.0
            + Double(calendar.component(.second, from: date)) / 3_600.0

        let declination = 23.45 * sin((360.0 / 365.0 * (284 + dayOfYear)) * .pi / 180)

        // Equation of time correction (minutes) — accounts for Earth's orbital eccentricity
        let b = (360.0 / 365.0 * (dayOfYear - 81)) * .pi / 180
        let eotMinutes = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)

        // In UTC, apparent solar noon is 12:00 minus longitude/15 and the
        // equation-of-time correction. East longitude is positive.
        let solarNoonUTC = 12.0
            - (longitude ?? 0) / 15.0
            - eotMinutes / 60.0
        let hourAngle = (utcHour - solarNoonUTC) * 15.0

        let latRad = latitude * .pi / 180
        let decRad = declination * .pi / 180
        let haRad = hourAngle * .pi / 180

        let sinAlt = sin(latRad) * sin(decRad)
            + cos(latRad) * cos(decRad) * cos(haRad)
        let altitude = asin(max(-1, min(1, sinAlt))) * 180 / .pi

        // atan2 stays defined near zenith, unlike dividing by cos(altitude).
        let azimuthRadians = atan2(
            sin(haRad),
            cos(haRad) * sin(latRad) - tan(decRad) * cos(latRad)
        )
        let azimuth = (azimuthRadians * 180 / .pi + 180)
            .truncatingRemainder(dividingBy: 360)

        return SolarPosition(altitude: altitude, azimuth: azimuth)
    }
}
