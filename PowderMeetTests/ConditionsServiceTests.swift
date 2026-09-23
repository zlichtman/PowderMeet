import XCTest
@testable import PowderMeet

final class ConditionsServiceTests: XCTestCase {
    func testHourlyOnlyCacheRecordNeverMasqueradesAsCurrentWeather() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var record = ConditionsCacheRecord(
            conditions: conditions(fetchedAt: now, temperatureC: 0),
            currentFetchedAt: nil,
            hourlyFetchedAt: nil
        )
        record.mergeHourly(
            samples: [hourly(at: now, snowfallCm: 3)],
            last24: 7,
            last72: 12,
            utcOffsetSeconds: -21_600,
            fetchedAt: now
        )

        XCTAssertNil(record.currentSnapshot(at: now, lifetime: 1_800))

        record.mergeCurrent(
            conditions(fetchedAt: now, temperatureC: -8),
            fetchedAt: now,
            lifetime: 1_800
        )
        let merged = record.currentSnapshot(at: now, lifetime: 1_800)
        XCTAssertEqual(merged?.temperatureC, -8)
        XCTAssertEqual(merged?.snowfallLast24hCm, 7)
        XCTAssertEqual(merged?.hourlyForecast.count, 1)
    }

    func testFreshCurrentSnapshotDropsExpiredHourlySnow() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = now.addingTimeInterval(-1_801)
        var old = conditions(fetchedAt: stale, temperatureC: -3)
        old.hourlyForecast = [hourly(at: stale, snowfallCm: 20)]
        old.snowfallLast24hCm = 20
        old.snowfallLast72hCm = 35
        var record = ConditionsCacheRecord(
            conditions: old,
            currentFetchedAt: stale,
            hourlyFetchedAt: stale
        )

        record.mergeCurrent(
            conditions(fetchedAt: now, temperatureC: -9),
            fetchedAt: now,
            lifetime: 1_800
        )

        XCTAssertEqual(record.conditions.temperatureC, -9)
        XCTAssertEqual(record.conditions.snowfallLast24hCm, 0)
        XCTAssertEqual(record.conditions.snowfallLast72hCm, 0)
        XCTAssertTrue(record.conditions.hourlyForecast.isEmpty)
        XCTAssertNil(record.hourlyFetchedAt)
    }

    func testCurrentCacheHitSanitizesHourlyComponentThatExpiredFirst() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var cached = conditions(
            fetchedAt: now.addingTimeInterval(-60),
            temperatureC: -7
        )
        cached.hourlyForecast = [hourly(at: now, snowfallCm: 25)]
        cached.snowfallLast24hCm = 25
        cached.snowfallLast72hCm = 40
        let record = ConditionsCacheRecord(
            conditions: cached,
            currentFetchedAt: now.addingTimeInterval(-60),
            hourlyFetchedAt: now.addingTimeInterval(-1_801)
        )

        let snapshot = try XCTUnwrap(
            record.currentSnapshot(at: now, lifetime: 1_800)
        )
        XCTAssertEqual(snapshot.temperatureC, -7)
        XCTAssertTrue(snapshot.hourlyForecast.isEmpty)
        XCTAssertEqual(snapshot.snowfallLast24hCm, 0)
        XCTAssertEqual(snapshot.snowfallLast72hCm, 0)
    }

    func testCacheAgeUsesOldestWeatherComponent() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let record = ConditionsCacheRecord(
            conditions: conditions(fetchedAt: now, temperatureC: -5),
            currentFetchedAt: now.addingTimeInterval(-60),
            hourlyFetchedAt: now.addingTimeInterval(-1_200)
        )

        XCTAssertEqual(
            try XCTUnwrap(record.oldestComponentAge(at: now)),
            1_200,
            accuracy: 0.001
        )
    }

    func testPrecedingSnowfallUsesExactIntervalsAndExcludesFutureSnow() {
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        let samples = [
            hourly(at: end.addingTimeInterval(-25 * 3_600), snowfallCm: 10),
            hourly(at: end.addingTimeInterval(-23 * 3_600), snowfallCm: 4),
            hourly(at: end.addingTimeInterval(30 * 60), snowfallCm: 8),
            hourly(at: end.addingTimeInterval(60 * 60), snowfallCm: 100),
        ]

        XCTAssertEqual(
            ConditionsService.precedingSnowfallCm(samples: samples, endingAt: end, hours: 24),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConditionsService.precedingSnowfallCm(samples: samples, endingAt: end, hours: 72),
            18,
            accuracy: 0.001
        )
    }

    func testPrecedingSnowfallProratesWindowBoundaryAndDoesNotFillGaps() {
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        let samples = [
            // The sample interval is [end - 24.5h, end - 23.5h], so half
            // overlaps the 24-hour window.
            hourly(at: end.addingTimeInterval(-23.5 * 3_600), snowfallCm: 6),
            // A deliberately missing 22 hours must not be extrapolated.
            hourly(at: end.addingTimeInterval(-30 * 60), snowfallCm: 2),
        ]

        XCTAssertEqual(
            ConditionsService.precedingSnowfallCm(samples: samples, endingAt: end, hours: 24),
            5,
            accuracy: 0.001
        )
    }

    func testPrecedingSnowfallClampsNegativeValuesAndNonpositiveWindows() {
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        let samples = [hourly(at: end, snowfallCm: -3)]

        XCTAssertEqual(
            ConditionsService.precedingSnowfallCm(samples: samples, endingAt: end, hours: 24),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConditionsService.precedingSnowfallCm(samples: samples, endingAt: end, hours: 0),
            0,
            accuracy: 0.001
        )
    }

    func testOpenMeteoUnixHourlyTimesAreAbsoluteAndOffsetIsRetained() throws {
        let timestamp = 1_773_586_800.0
        let json = """
        {
          "elevation": 2000,
          "utc_offset_seconds": -21600,
          "hourly": {
            "time": [\(Int(timestamp))],
            "temperature_2m": [-5],
            "snowfall": [2.5],
            "cloud_cover": [80],
            "weather_code": [71],
            "wind_speed_10m": [20],
            "visibility": [5000]
          }
        }
        """

        let response = try JSONDecoder().decode(
            OpenMeteoResponse.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(response.utcOffsetSeconds, -21_600)
        XCTAssertEqual(
            try XCTUnwrap(response.hourly.time.first).timeIntervalSince1970,
            timestamp,
            accuracy: 0.001
        )
    }

    func testLegacyHourlyStringFallbackIsDeterministicGMT() throws {
        let json = """
        {
          "hourly": {
            "time": ["2026-03-15T14:00"],
            "snowfall": [0]
          }
        }
        """
        let response = try JSONDecoder().decode(
            OpenMeteoResponse.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 15,
            hour: 14
        )))

        XCTAssertEqual(response.hourly.time, [expected])
    }

    func testLiveDisplayFallsBackToCurrentReadingBeforeHourlyMerge() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let current = conditions(fetchedAt: now.addingTimeInterval(-120), temperatureC: -11)

        let live = try XCTUnwrap(current.displaySample(at: now, now: now))
        XCTAssertEqual(live.temperatureC, -11)
        XCTAssertEqual(live.time, current.fetchedAt)

        // Scrubbed away from now, a current reading is not a forecast.
        XCTAssertNil(current.displaySample(at: now.addingTimeInterval(3 * 3_600), now: now))
        XCTAssertNil(current.displaySample(at: now.addingTimeInterval(-3 * 3_600), now: now))
    }

    func testLiveDisplayPrefersCoveringHourlySampleAndRejectsStaleCurrent() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var withHourly = conditions(fetchedAt: now, temperatureC: -11)
        withHourly.hourlyForecast = [hourly(at: now.addingTimeInterval(600), snowfallCm: 2)]
        XCTAssertEqual(withHourly.displaySample(at: now, now: now)?.snowfallCm, 2)

        let stale = conditions(fetchedAt: now.addingTimeInterval(-2 * 3_600), temperatureC: -4)
        XCTAssertNil(stale.displaySample(at: now, now: now))
    }

    private func hourly(at time: Date, snowfallCm: Double) -> HourlyCondition {
        HourlyCondition(
            time: time,
            temperatureC: -5,
            snowfallCm: snowfallCm,
            cloudCoverPercent: 50,
            weatherCode: 71,
            windSpeedKph: 10,
            visibilityKm: 10
        )
    }

    private func conditions(fetchedAt: Date, temperatureC: Double) -> ResortConditions {
        ResortConditions(
            resortId: "test-resort",
            temperatureC: temperatureC,
            windSpeedKph: 10,
            windGustsKph: 15,
            snowfallLast24hCm: 0,
            snowfallLast72hCm: 0,
            snowDepthCm: 100,
            weatherCode: 71,
            visibilityKm: 10,
            cloudCoverPercent: 50,
            windDirectionDeg: 180,
            stationElevationM: 2_000,
            fetchedAt: fetchedAt
        )
    }
}
