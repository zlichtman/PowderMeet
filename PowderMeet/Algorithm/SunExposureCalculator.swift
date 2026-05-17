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

    static func speedMultiplier(for condition: SunExposure.SnowConditionModifier) -> Double {
        switch condition {
        case .hardPack: return 0.8
        case .softPack: return 1.05
        case .slush:    return 0.75
        case .normal:   return 1.0
        }
    }

    // MARK: - Solar Position

    struct SolarPosition {
        let altitude: Double
        let azimuth: Double
    }

    /// Calculates solar position with equation of time and longitude correction.
    /// Without these corrections, solar noon can be off by up to 30 minutes
    /// at resorts far from their timezone's central meridian.
    static func solarPosition(date: Date, latitude: Double, longitude: Double? = nil) -> SolarPosition {
        let calendar = Calendar(identifier: .gregorian)
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60.0

        let declination = 23.45 * sin((360.0 / 365.0 * (284 + dayOfYear)) * .pi / 180)

        // Equation of time correction (minutes) — accounts for Earth's orbital eccentricity
        let b = (360.0 / 365.0 * (dayOfYear - 81)) * .pi / 180
        let eotMinutes = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)

        // Solar noon correction: equation of time + longitude offset from timezone meridian
        var solarNoon = 12.0 - eotMinutes / 60.0
        if let lon = longitude {
            // Timezone offset from UTC in hours
            let tzOffsetHours = Double(calendar.timeZone.secondsFromGMT(for: date)) / 3600.0
            // Standard meridian for this timezone
            let standardMeridian = tzOffsetHours * 15.0
            // Longitude correction: 4 minutes per degree
            solarNoon -= (lon - standardMeridian) * 4.0 / 60.0
        }

        let hourAngle = (hour - solarNoon) * 15.0

        let latRad = latitude * .pi / 180
        let decRad = declination * .pi / 180
        let haRad = hourAngle * .pi / 180

        let sinAlt = sin(latRad) * sin(decRad) + cos(latRad) * cos(decRad) * cos(haRad)
        let altitude = asin(sinAlt) * 180 / .pi

        let cosAz = (sin(decRad) - sin(latRad) * sinAlt) / (cos(latRad) * cos(altitude * .pi / 180))
        var azimuth = acos(max(-1, min(1, cosAz))) * 180 / .pi
        if hourAngle > 0 { azimuth = 360 - azimuth }

        return SolarPosition(altitude: altitude, azimuth: azimuth)
    }
}
