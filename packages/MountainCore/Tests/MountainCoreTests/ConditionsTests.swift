import Foundation
import Testing
@testable import MountainCore

// Invariant I-05: the forecast reference cases (wind in m/s and visibility in
// metres, as the conditions document carries them).

private let start = Date(timeIntervalSinceReferenceDate: 0)

private func reading(
    _ offsetS: Double, temp: Double, wind: Double, visibility: Double, cloud: Double
) -> ConditionsSample {
    ConditionsSample(
        at: start.addingTimeInterval(offsetS), tempC: temp, windMS: wind,
        visibilityM: visibility, cloudPct: cloud
    )
}

private func conditions(current: ConditionsSample, hourly: [ConditionsSample]) -> Conditions {
    Conditions(
        resortID: "test", observedAt: start, expiresAt: start.addingTimeInterval(5_400),
        current: current, hourly: hourly
    )
}

@Test func hourlyWeatherInterpolatesAcrossANormalGap() {
    let c = conditions(
        current: reading(0, temp: -2, wind: 2, visibility: 20_000, cloud: 20),
        hourly: [
            reading(0, temp: -8, wind: 4, visibility: 16_000, cloud: 20),
            reading(3_600, temp: -4, wind: 12, visibility: 4_000, cloud: 80),
        ]
    )
    let halfway = c.sample(at: start.addingTimeInterval(1_800))
    #expect(abs(halfway.tempC - -6) < 0.001)
    #expect(abs(halfway.windMS - 8) < 0.001)
    #expect(abs(halfway.visibilityM - 10_000) < 0.001)
    #expect(halfway.cloudPct == 50)
}

@Test func forecastEndHoldsAnHourThenFadesToCurrent() {
    let c = conditions(
        current: reading(0, temp: 0, wind: 0, visibility: 20_000, cloud: 0),
        hourly: [reading(0, temp: -10, wind: 16, visibility: 1_000, cloud: 100)]
    )
    let held = c.sample(at: start.addingTimeInterval(60 * 60))
    let halfway = c.sample(at: start.addingTimeInterval(75 * 60))
    let justBefore = c.sample(at: start.addingTimeInterval(90 * 60 - 1))
    let after = c.sample(at: start.addingTimeInterval(90 * 60 + 1))
    #expect(abs(held.windMS - 16) < 0.001)
    #expect(abs(halfway.windMS - 8) < 0.001)
    #expect(abs(halfway.visibilityM - 10_500) < 0.001)
    // No cliff at the end of the fade.
    #expect(abs(justBefore.windMS - after.windMS) < 0.1)
    #expect(abs(justBefore.visibilityM - after.visibilityM) < 100)
    #expect(after.windMS == 0)
}

@Test func largeForecastGapUsesHoldFadeAndCurrentInsteadOfLongInterpolation() {
    let c = conditions(
        current: reading(0, temp: -2, wind: 5, visibility: 10_000, cloud: 50),
        hourly: [
            reading(0, temp: -10, wind: 16, visibility: 1_000, cloud: 100),
            reading(4 * 3_600, temp: 2, wind: 0, visibility: 20_000, cloud: 0),
        ]
    )
    let middle = c.sample(at: start.addingTimeInterval(2 * 3_600))
    let nearUpper = c.sample(at: start.addingTimeInterval(3 * 3_600))
    #expect(abs(middle.windMS - 5) < 0.001)
    #expect(abs(middle.visibilityM - 10_000) < 0.001)
    #expect(abs(nearUpper.windMS - 0) < 0.001)
    #expect(abs(nearUpper.visibilityM - 20_000) < 0.001)
}

@Test func statusFreshnessFollowsExpiry() {
    let status = ResortStatus(
        resortID: "test", observedAt: start, expiresAt: start.addingTimeInterval(75 * 60),
        source: .epic, groups: [:]
    )
    #expect(status.freshness(at: start.addingTimeInterval(74 * 60)) == .fresh)
    #expect(status.freshness(at: start.addingTimeInterval(75 * 60)) == .stale)
    #expect(status.freshness(at: start.addingTimeInterval(75 * 60 + 6 * 3_600 - 1)) == .stale)
    #expect(status.freshness(at: start.addingTimeInterval(75 * 60 + 6 * 3_600)) == .unavailable)
    #expect(StatusFreshness.of(nil, at: start) == .unavailable)
}

@Test func anOlderRowWithoutTheNewKeysStillDecodes() throws {
    let json = Data("""
    {"resort_id":"r","observed_at":"2026-01-14T18:00:00Z","expires_at":"2026-01-14T19:30:00Z",
     "source":"open-meteo",
     "current":{"at":"2026-01-14T18:00:00Z","temp_c":-4,"wind_ms":6,"gust_ms":11,
                "visibility_m":8000,"cloud_pct":70,"snow_24h_cm":12,"precip_mmh":0.4,"weather_code":71},
     "hourly":[]}
    """.utf8)
    let conditions = try Conditions.decode(json)
    #expect(conditions.elevationM == nil)
    #expect(conditions.recent.isEmpty)
    #expect(conditions.current.windDirDeg == nil)
}

@Test func windDirectionTurnsTheShortWayBetweenHours() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    func sample(_ offset: TimeInterval, _ direction: Double) -> ConditionsSample {
        ConditionsSample(
            at: start.addingTimeInterval(offset), tempC: 0, windMS: 5, visibilityM: 10_000,
            cloudPct: 0, windDirDeg: direction
        )
    }
    let conditions = Conditions(
        resortID: "r", observedAt: start, expiresAt: start.addingTimeInterval(5_400),
        current: sample(0, 350), hourly: [sample(0, 350), sample(3_600, 10)]
    )
    // Through north, not back round through south.
    #expect(conditions.sample(at: start.addingTimeInterval(1_800)).windDirDeg == 0)
}

@Test func freshnessCountsAnOlderStormAndADeepBaseWhenTheSampleHasThem() {
    func sample(snow72: Double? = nil, depth: Double? = nil) -> ConditionsSample {
        ConditionsSample(
            at: Date(timeIntervalSinceReferenceDate: 0), tempC: -5, windMS: 0, visibilityM: 10_000,
            cloudPct: 0, snowDepthCM: depth, snow72hCM: snow72
        )
    }
    #expect(TrailConditions.freshness(sample()) == 0.1)
    #expect(TrailConditions.freshness(sample(snow72: 20)) == 0.65)
    #expect(TrailConditions.freshness(sample(snow72: 8)) == 0.45)
    #expect(TrailConditions.freshness(sample(depth: 120)) == 0.35)
    #expect(TrailConditions.freshness(sample(snow72: 2, depth: 60)) == 0.2)
}

/// The glide meter used to read better just above freezing than just below,
/// and better at -16 °C than at -15 °C.
@Test func glideHasNoJumpAtFreezingOrDeepCold() {
    for edge in [0.0, -15.0] {
        let step = abs(TrailConditions.temperatureGlide(edge + 0.01) - TrailConditions.temperatureGlide(edge - 0.01))
        #expect(step < 0.01)
    }
    #expect(TrailConditions.temperatureGlide(-20) < TrailConditions.temperatureGlide(-15))
}

/// A run the map leaves to bump up reads higher on the Moguls meter than the
/// same run unflagged, even under a deep new snowfall; an edge from a bundle
/// built before the flag existed decodes as unflagged.
@Test func aFlaggedMogulRunReadsHigherAndAnOlderBundleEdgeDecodesUnflagged() throws {
    let deepSnow = ConditionsSample(
        at: Date(timeIntervalSinceReferenceDate: 0), tempC: -5, windMS: 0, visibilityM: 10_000,
        cloudPct: 0, snow24hCM: 20
    )
    for weather in [nil, deepSnow] {
        let plain = TrailConditions.score(groomed: false, averagePitchDeg: 20, aspectDeg: nil, weather: weather)
        let flagged = TrailConditions.score(
            groomed: false, mogulRun: true, averagePitchDeg: 20, aspectDeg: nil, weather: weather)
        #expect(flagged.moguls > plain.moguls)
    }

    let json = Data("""
        {"id": "w1:0", "from": "n1", "to": "n2", "kind": "run", "geometry": [[0, 0, 10], [0, 0.001, 0]],
         "length_m": 111.2, "vertical_m": -10, "groomed_default": false}
        """.utf8)
    let older = try JSONDecoder().decode(Edge.self, from: json)
    #expect(older.moguls == false)
    var flaggedJSON = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    flaggedJSON["moguls"] = true
    let flagged = try JSONDecoder().decode(Edge.self, from: JSONSerialization.data(withJSONObject: flaggedJSON))
    #expect(flagged.moguls)
}
