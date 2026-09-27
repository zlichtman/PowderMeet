//
//  SkiPerformanceProfileTests.swift
//  PowderMeetTests
//
//  Selected equipment may tune ETA conservatively, but it must never
//  weaken closure, difficulty, or terrain-ability gates.
//

import XCTest
@testable import PowderMeet

final class SkiPerformanceProfileTests: XCTestCase {

    private func profile(
        skillLevel: String = "intermediate",
        conditionMoguls: Double = 1
    ) -> UserProfile {
        UserProfile(
            id: UUID(),
            displayName: "Test Skier",
            skillLevel: skillLevel,
            speedGreen: 6,
            speedBlue: 8,
            speedBlack: 9,
            speedDoubleBlack: 10,
            speedTerrainPark: 7,
            conditionMoguls: conditionMoguls,
            conditionUngroomed: 1,
            conditionIcy: 1,
            conditionGladed: 1,
            onboardingCompleted: true
        )
    }

    private func equipment(
        id: UUID = UUID(),
        width: Int,
        category: String
    ) -> SkiPerformanceProfile {
        SkiPerformanceProfile(entry: SkiCatalogEntry(
            id: id,
            brand: "Test",
            model: "\(width)",
            category: category,
            waistWidthMm: width,
            topsheetAssetKey: nil
        ))
    }

    private func makeRun(
        difficulty: RunDifficulty = .blue,
        isOpen: Bool = true,
        isGroomed: Bool? = true,
        hasMoguls: Bool = false
    ) -> GraphEdge {
        GraphEdge(
            id: "run",
            sourceID: "top",
            targetID: "bottom",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: difficulty,
                lengthMeters: 1_000,
                hasMoguls: hasMoguls,
                isGroomed: isGroomed,
                isOpen: isOpen
            )
        )
    }

    private func context(
        snow: Double,
        equipment: SkiPerformanceProfile?,
        solveTime: Date? = nil,
        history: [String: [String: PerEdgeSpeed]] = [:],
        datasetVersion: String? = nil
    ) -> TraversalContext {
        TraversalContext(
            solveTime: solveTime,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: snow,
            cloudCoverPercent: 0,
            edgeSpeedHistory: history,
            datasetVersion: datasetVersion,
            equipment: equipment
        )
    }

    private func observation(
        edgeID: String = "run",
        conditions: String = ConditionsFingerprint.defaultBucket,
        datasetVersion: String = "dataset-v1",
        equipmentKey: String = PerEdgeSpeed.neutralEquipmentKey,
        count: Int = 3,
        speed: Double
    ) -> PerEdgeSpeed {
        PerEdgeSpeed(
            resortId: "test",
            edgeId: edgeID,
            conditionsFp: conditions,
            datasetVersion: datasetVersion,
            equipmentKey: equipmentKey,
            observationCount: count,
            rollingSpeedMs: speed,
            rollingDurationS: 100,
            lastObservedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func exactConditions(for edge: GraphEdge, snow: Double) -> String {
        ConditionsFingerprint.fingerprint(
            temperatureC: 0,
            windSpeedKph: 0,
            snowfallLast24hCm: snow,
            visibilityKm: 20,
            cloudCoverPercent: 0,
            surface: .init(
                hasMoguls: edge.attributes.hasMoguls,
                isUngroomed: edge.attributes.isGroomed == false,
                isGladed: edge.attributes.isGladed
            )
        )
    }

    private func makeLift(
        liveWaitMinutes: Double? = nil,
        rideTimeSeconds: Double = 300,
        chargesLiftWait: Bool? = nil,
        weekdayWaitMinutes: Double? = 2,
        weekendWaitMinutes: Double? = 5
    ) -> GraphEdge {
        GraphEdge(
            id: "lift",
            sourceID: "base",
            targetID: "top",
            kind: .lift,
            geometry: [],
            attributes: EdgeAttributes(
                lengthMeters: 1_000,
                liftType: .chairLift,
                rideTimeSeconds: rideTimeSeconds,
                waitTimeMinutes: liveWaitMinutes,
                weekdayWaitMinutes: weekdayWaitMinutes,
                weekendWaitMinutes: weekendWaitMinutes,
                chargesLiftWait: chargesLiftWait,
                isOpen: true
            )
        )
    }

    private func liftContext(year: Int, month: Int, day: Int) -> TraversalContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let solveTime = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
        return TraversalContext(
            solveTime: solveTime,
            latitude: nil,
            longitude: 0,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )
    }

    private func liftContext(at time: Date) -> TraversalContext {
        TraversalContext(
            solveTime: time,
            latitude: nil,
            longitude: 0,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )
    }

    private func utcDate(hour: Int, minute: Int, second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 13,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    func testWideSkiReducesETAOnFreshUngroomedRun() throws {
        let skier = profile()
        let edge = makeRun(isGroomed: false)
        let narrowETA = try XCTUnwrap(skier.traverseTime(
            for: edge,
            context: context(snow: 15, equipment: equipment(width: 72, category: "carving"))
        ))
        let wideETA = try XCTUnwrap(skier.traverseTime(
            for: edge,
            context: context(snow: 15, equipment: equipment(width: 118, category: "powder"))
        ))

        XCTAssertLessThan(wideETA, narrowETA)
    }

    func testNarrowSkiReducesETASlightlyOnFirmGroomer() throws {
        let skier = profile()
        let edge = makeRun(isGroomed: true)
        let narrowETA = try XCTUnwrap(skier.traverseTime(
            for: edge,
            context: context(snow: 0, equipment: equipment(width: 72, category: "carving"))
        ))
        let wideETA = try XCTUnwrap(skier.traverseTime(
            for: edge,
            context: context(snow: 0, equipment: equipment(width: 118, category: "powder"))
        ))

        XCTAssertLessThan(narrowETA, wideETA)
    }

    func testCatalogCategoryAddsSmallDisciplineSpecificAdvantages() throws {
        let skier = profile(skillLevel: "expert")
        let parkRun = makeRun(difficulty: .terrainPark, isGroomed: true)
        let groomer = makeRun(isGroomed: true)

        let parkSkiETA = try XCTUnwrap(skier.traverseTime(
            for: parkRun,
            context: context(snow: 0, equipment: equipment(width: 95, category: "park"))
        ))
        let allMountainParkETA = try XCTUnwrap(skier.traverseTime(
            for: parkRun,
            context: context(snow: 0, equipment: equipment(width: 95, category: "all-mountain"))
        ))
        let raceSkiETA = try XCTUnwrap(skier.traverseTime(
            for: groomer,
            context: context(snow: 0, equipment: equipment(width: 78, category: "race"))
        ))
        let allMountainGroomerETA = try XCTUnwrap(skier.traverseTime(
            for: groomer,
            context: context(snow: 0, equipment: equipment(width: 78, category: "all-mountain"))
        ))

        XCTAssertLessThan(parkSkiETA, allMountainParkETA)
        XCTAssertLessThan(raceSkiETA, allMountainGroomerETA)
        XCTAssertGreaterThan(parkSkiETA / allMountainParkETA, 0.95)
        XCTAssertGreaterThan(raceSkiETA / allMountainGroomerETA, 0.95)
    }

    func testEquipmentSnowResponseIsContinuousAtFormerThresholds() {
        for ski in [equipment(width: 72, category: "race"),
                    equipment(width: 118, category: "powder"),
                    equipment(width: 95, category: "park")] {
            for edge in [makeRun(isGroomed: false),
                         makeRun(difficulty: .terrainPark, isGroomed: false)] {
                for threshold in [3.0, 8.0] {
                    XCTAssertEqual(
                        ski.speedMultiplier(for: edge, freshSnowCm: threshold - 0.0001),
                        ski.speedMultiplier(for: edge, freshSnowCm: threshold + 0.0001),
                        accuracy: 0.00001
                    )
                }
            }
        }
    }

    func testForecastAccumulationDoesNotMakeLaterArrivalFinishEarlierAtSkiThreshold() throws {
        let start = utcDate(hour: 10, minute: 0, second: 0)
        let ski = equipment(width: 118, category: "powder")
        let edge = makeRun(isGroomed: false)
        let ctx = TraversalContext(
            solveTime: start, latitude: nil, longitude: nil,
            temperatureCelsius: 0, stationElevationM: 0, windSpeedKmh: 0,
            visibilityKm: 20, freshSnowCm: 2, cloudCoverPercent: 0,
            hourlyWeather: [.init(time: start.addingTimeInterval(3600),
                                  temperatureCelsius: 0, windSpeedKmh: 0,
                                  visibilityKm: 20, cloudCoverPercent: 0, snowfallCm: 8)],
            equipment: ski
        )
        for crossing in [450.0, 2700.0] {
            let before = crossing - 0.01
            let after = crossing + 0.01
            let beforeETA = try XCTUnwrap(profile().traverseTime(
                for: edge, context: ctx, arrivalTimeOffsetSeconds: before))
            let afterETA = try XCTUnwrap(profile().traverseTime(
                for: edge, context: ctx, arrivalTimeOffsetSeconds: after))
            XCTAssertGreaterThan(after + afterETA, before + beforeETA)
        }
    }

    func testExactSameSkiPaceAppliesOnlyForecastEquipmentChange() throws {
        let start = utcDate(hour: 10, minute: 0, second: 0)
        let ski = equipment(width: 118, category: "powder")
        let edge = makeRun(isGroomed: false)
        let conditions = exactConditions(for: edge, snow: 2)
        func makeContext(ski: SkiPerformanceProfile?) -> TraversalContext {
            let row = observation(conditions: conditions,
                                  equipmentKey: ski?.observationEquipmentKey ?? PerEdgeSpeed.neutralEquipmentKey,
                                  speed: 10)
            return TraversalContext(
                solveTime: start, latitude: nil, longitude: nil,
                temperatureCelsius: 0, stationElevationM: 0, windSpeedKmh: 0,
                visibilityKm: 20, freshSnowCm: 2, cloudCoverPercent: 0,
                hourlyWeather: [.init(time: start.addingTimeInterval(3600),
                                      temperatureCelsius: 0, windSpeedKmh: 0,
                                      visibilityKm: 20, cloudCoverPercent: 0, snowfallCm: 10)],
                edgeSpeedHistory: [edge.id: [row.historyKey: row]],
                datasetVersion: "dataset-v1", equipment: ski
            )
        }
        let skier = profile()
        let equipped = makeContext(ski: ski)
        XCTAssertEqual(try XCTUnwrap(skier.traverseTime(for: edge, context: equipped)),
                       100, accuracy: 0.001)
        let neutralFuture = try XCTUnwrap(skier.traverseTime(
            for: edge, context: makeContext(ski: nil), arrivalTimeOffsetSeconds: 3600))
        let equippedFuture = try XCTUnwrap(skier.traverseTime(
            for: edge, context: equipped, arrivalTimeOffsetSeconds: 3600))
        let expectedRatio = ski.speedMultiplier(for: edge, freshSnowCm: 12)
            / ski.speedMultiplier(for: edge, freshSnowCm: 2)
        XCTAssertEqual(equippedFuture, neutralFuture / expectedRatio, accuracy: 0.001)
    }

    func testEquipmentCannotBypassDifficultyGate() {
        let beginner = profile(skillLevel: "beginner")
        let blackRun = makeRun(difficulty: .black)

        XCTAssertNil(beginner.traverseTime(
            for: blackRun,
            context: context(snow: 15, equipment: equipment(width: 118, category: "powder"))
        ))
    }

    func testEquipmentCannotBypassClosedStatus() {
        let skier = profile(skillLevel: "expert")
        let closedRun = makeRun(difficulty: .green, isOpen: false)

        XCTAssertNil(skier.traverseTime(
            for: closedRun,
            context: context(snow: 15, equipment: equipment(width: 118, category: "powder"))
        ))
    }

    func testAdvancedAbilityAllowsParkButNotDoubleBlack() throws {
        let advanced = profile(skillLevel: "advanced")
        let park = makeRun(difficulty: .terrainPark)
        let doubleBlack = makeRun(difficulty: .doubleBlack)

        XCTAssertNotNil(advanced.traverseTime(
            for: park,
            context: context(snow: 0, equipment: nil)
        ))
        XCTAssertNil(advanced.traverseTime(
            for: doubleBlack,
            context: context(snow: 0, equipment: nil)
        ))
    }

    func testMissingCategorySpeedNeverInventsTerrainPermission() {
        var expert = profile(skillLevel: "expert")
        expert.speedTerrainPark = nil

        XCTAssertFalse(expert.canTraverseRun(.terrainPark))
        XCTAssertNil(expert.traverseTime(
            for: makeRun(difficulty: .terrainPark),
            context: context(snow: 0, equipment: nil)
        ))
    }

    func testHeuristicLiftWaitCurveIsFIFOAcrossFormerBucketDrops() throws {
        let skier = profile()
        let lift = makeLift(weekdayWaitMinutes: nil, weekendWaitMinutes: nil)

        for boundaryHour in [12, 15] {
            let before = utcDate(hour: boundaryHour - 1, minute: 59, second: 59)
            let after = utcDate(hour: boundaryHour, minute: 0, second: 0)
            let beforeDuration = try XCTUnwrap(skier.traverseTime(
                for: lift,
                context: liftContext(at: before)
            ))
            let afterDuration = try XCTUnwrap(skier.traverseTime(
                for: lift,
                context: liftContext(at: after)
            ))

            let beforeCompletion = before.timeIntervalSinceReferenceDate + beforeDuration
            let afterCompletion = after.timeIntervalSinceReferenceDate + afterDuration
            XCTAssertGreaterThan(afterCompletion, beforeCompletion)
            XCTAssertLessThan(afterCompletion - beforeCompletion, 2)
        }
    }

    func testContinuousQueueCurveStillModelsPeakAndLateAfternoon() throws {
        let skier = profile()
        let lift = makeLift(weekdayWaitMinutes: nil, weekendWaitMinutes: nil)
        let peak = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: liftContext(at: utcDate(hour: 10, minute: 0, second: 0))
        ))
        let late = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: liftContext(at: utcDate(hour: 15, minute: 0, second: 0))
        ))

        XCTAssertGreaterThan(peak, late)
        XCTAssertEqual(peak - late, 54, accuracy: 0.001)
    }

    func testKnownResortCloseRejectsLiftReachedAfterClosing() throws {
        let skier = profile()
        let lift = makeLift(weekdayWaitMinutes: 1, weekendWaitMinutes: 1)
        let start = utcDate(hour: 15, minute: 58, second: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: 0,
            utcOffsetSeconds: 0,
            liftOpenHour: 8,
            liftCloseHour: 16,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )

        XCTAssertNotNil(skier.traverseTime(for: lift, context: context))
        XCTAssertNil(skier.traverseTime(
            for: lift,
            context: context,
            arrivalTimeOffsetSeconds: 120
        ))
        XCTAssertNil(skier.traverseTime(
            for: lift,
            context: context,
            arrivalTimeOffsetSeconds: 60
        ))
    }

    func testForecastLiftWindCurveRemainsFIFOWhenStormClears() throws {
        let skier = profile()
        let lift = makeLift(liveWaitMinutes: 2, rideTimeSeconds: 300)
        let start = utcDate(hour: 10, minute: 0, second: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: 0,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 100,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: 0,
                    windSpeedKmh: 100,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                ),
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: 0,
                    windSpeedKmh: 20,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                )
            ]
        )

        var priorCompletion = -Double.infinity
        for offset in stride(from: 0.0, through: 3_600.0, by: 15) {
            let duration = try XCTUnwrap(skier.traverseTime(
                for: lift,
                context: context,
                arrivalTimeOffsetSeconds: offset
            ))
            let completion = offset + duration
            XCTAssertGreaterThan(completion, priorCompletion)
            priorCompletion = completion
        }
    }

    func testForecastRunCostRemainsFIFOWhenWeatherClears() throws {
        let skier = profile()
        let run = makeRun()
        let start = utcDate(hour: 10, minute: 0, second: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: 0,
            temperatureCelsius: -2,
            stationElevationM: 0,
            windSpeedKmh: 70,
            visibilityKm: 0.5,
            freshSnowCm: 0,
            cloudCoverPercent: 100,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: -2,
                    windSpeedKmh: 70,
                    visibilityKm: 0.5,
                    cloudCoverPercent: 100
                ),
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: -2,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                )
            ]
        )

        var priorCompletion = -Double.infinity
        for offset in stride(from: 0.0, through: 3_600.0, by: 15) {
            let duration = try XCTUnwrap(skier.traverseTime(
                for: run,
                context: context,
                arrivalTimeOffsetSeconds: offset
            ))
            let completion = offset + duration
            XCTAssertGreaterThan(completion, priorCompletion)
            priorCompletion = completion
        }
    }

    func testSunRoutingPhysicsIsContinuousAcrossDisplayThresholds() {
        func exposure(_ factor: Double) -> SunExposure {
            SunExposure(
                sunAltitude: 30,
                sunAzimuth: 180,
                exposureFactor: factor,
                snowCondition: factor > 0.7 ? .slush : .softPack
            )
        }

        let belowSunThreshold = SunExposureCalculator.routingSpeedMultiplier(
            exposure: exposure(0.6999),
            temperatureC: 0
        )
        let aboveSunThreshold = SunExposureCalculator.routingSpeedMultiplier(
            exposure: exposure(0.7001),
            temperatureC: 0
        )
        let belowTemperatureThreshold = SunExposureCalculator.routingSpeedMultiplier(
            exposure: exposure(0.8),
            temperatureC: -1.0001
        )
        let aboveTemperatureThreshold = SunExposureCalculator.routingSpeedMultiplier(
            exposure: exposure(0.8),
            temperatureC: -0.9999
        )

        XCTAssertEqual(belowSunThreshold, aboveSunThreshold, accuracy: 0.001)
        XCTAssertEqual(
            belowTemperatureThreshold,
            aboveTemperatureThreshold,
            accuracy: 0.001
        )
    }

    func testColdSnowGlideIsContinuousAcrossFormerTemperatureBuckets() {
        for threshold in [-15.0, -8.0, -3.0] {
            let justBelow = TraversalConstants.Run.Ice.speedFactor(
                at: threshold - 0.0001
            )
            let justAbove = TraversalConstants.Run.Ice.speedFactor(
                at: threshold + 0.0001
            )
            XCTAssertEqual(justBelow, justAbove, accuracy: 0.001)
        }
        XCTAssertEqual(
            TraversalConstants.Run.Ice.speedFactor(at: -15),
            0.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TraversalConstants.Run.Ice.speedFactor(at: 0),
            1,
            accuracy: 0.001
        )
    }

    func testIcyAbilityPenaltyIsContinuousAtFreezingRiskBoundary() throws {
        var cautious = profile()
        cautious.conditionIcy = 0.2
        let run = makeRun()
        func eta(temperature: Double) throws -> Double {
            try XCTUnwrap(cautious.traverseTime(
                for: run,
                context: TraversalContext(
                    solveTime: nil,
                    latitude: nil,
                    longitude: nil,
                    temperatureCelsius: temperature,
                    stationElevationM: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    freshSnowCm: 0,
                    cloudCoverPercent: 0
                )
            ))
        }

        XCTAssertEqual(
            try eta(temperature: -3.0001),
            try eta(temperature: -2.9999),
            accuracy: 0.01
        )
        XCTAssertGreaterThan(
            try eta(temperature: -7),
            try eta(temperature: -3)
        )
    }

    func testLiftWindSlowsRideWithoutInventingExtraQueue() throws {
        let skier = profile()
        let lift = makeLift(liveWaitMinutes: 2, rideTimeSeconds: 300)
        let start = utcDate(hour: 10, minute: 0, second: 0)
        func context(wind: Double) -> TraversalContext {
            TraversalContext(
                solveTime: start,
                latitude: nil,
                longitude: 0,
                temperatureCelsius: 0,
                stationElevationM: 0,
                windSpeedKmh: wind,
                visibilityKm: 20,
                freshSnowCm: 0,
                cloudCoverPercent: 0
            )
        }

        let calm = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: context(wind: 0)
        ))
        let windy = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: context(wind: 80)
        ))

        XCTAssertEqual(calm, 420, accuracy: 0.001)
        XCTAssertEqual(windy, 570, accuracy: 0.001)
    }

    func testRunSunExposureUsesEdgeArrivalTime() throws {
        let skier = profile()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let solveTime = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 1,
            hour: 12
        )))
        let arrivalOffset: TimeInterval = 6 * 60 * 60
        let arrivalTime = solveTime.addingTimeInterval(arrivalOffset)
        let latitude = 45.0
        let longitude = -106.0
        let sunnyAspect = SunExposureCalculator.solarPosition(
            date: arrivalTime,
            latitude: latitude,
            longitude: longitude
        ).azimuth
        let run = GraphEdge(
            id: "sun-run",
            sourceID: "top",
            targetID: "bottom",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                aspect: sunnyAspect,
                isGroomed: true,
                isOpen: true
            )
        )
        let context = TraversalContext(
            solveTime: solveTime,
            latitude: latitude,
            longitude: longitude,
            temperatureCelsius: 2,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )

        let atSolve = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context
        ))
        let atArrival = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: arrivalOffset
        ))

        XCTAssertGreaterThan(atArrival, atSolve)
    }

    func testSolarPositionUsesMountainLongitudeAtAnAbsoluteInstant() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let mountainSolarNoon = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 21,
            hour: 19
        )))

        // 19:00 UTC is approximately solar noon at 105°W regardless of the
        // phone's current timezone. At 45°N near the solstice, the sun should
        // be high and almost due south.
        let position = SunExposureCalculator.solarPosition(
            date: mountainSolarNoon,
            latitude: 45,
            longitude: -105
        )

        XCTAssertEqual(position.altitude, 68.4, accuracy: 0.7)
        XCTAssertEqual(position.azimuth, 180, accuracy: 1.5)
    }

    func testSolarPositionChangesWithMountainLongitudeNotDeviceClock() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 21,
            hour: 19
        )))

        let westernMountain = SunExposureCalculator.solarPosition(
            date: instant,
            latitude: 45,
            longitude: -105
        )
        let easternMountain = SunExposureCalculator.solarPosition(
            date: instant,
            latitude: 45,
            longitude: -75
        )

        XCTAssertGreaterThan(westernMountain.altitude, easternMountain.altitude)
        XCTAssertGreaterThan(easternMountain.azimuth, 180)
    }

    func testMatchingEquipmentHistoryIsNotAppliedTwice() throws {
        let ski = equipment(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            width: 118,
            category: "powder"
        )
        let edge = makeRun()
        let learned = observation(
            equipmentKey: ski.observationEquipmentKey,
            speed: 10
        )
        let history = [edge.id: [learned.historyKey: learned]]

        let eta = try XCTUnwrap(profile().traverseTime(
            for: edge,
            context: context(
                snow: 0,
                equipment: ski,
                history: history,
                datasetVersion: "dataset-v1"
            )
        ))

        XCTAssertEqual(eta, 100, accuracy: 0.001)
    }

    func testNeutralHistoryReceivesCurrentEquipmentModel() throws {
        let ski = equipment(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            width: 118,
            category: "powder"
        )
        let edge = makeRun()
        let learned = observation(speed: 10)
        let history = [edge.id: [learned.historyKey: learned]]
        let expectedSpeed = 10 * ski.speedMultiplier(for: edge, freshSnowCm: 0)

        let eta = try XCTUnwrap(profile().traverseTime(
            for: edge,
            context: context(
                snow: 0,
                equipment: ski,
                history: history,
                datasetVersion: "dataset-v1"
            )
        ))

        XCTAssertEqual(eta, 1_000 / expectedSpeed, accuracy: 0.001)
    }

    func testHistoryFromAnotherSkiIsNeverBorrowed() throws {
        let currentSki = equipment(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            width: 72,
            category: "carving"
        )
        let otherSkiID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let edge = makeRun()
        let otherSki = observation(
            equipmentKey: PerEdgeSpeed.normalizedEquipmentKey(for: otherSkiID),
            speed: 20
        )
        let history = [edge.id: [otherSki.historyKey: otherSki]]
        let expectedSpeed = 8
            * currentSki.speedMultiplier(for: edge, freshSnowCm: 0)

        let eta = try XCTUnwrap(profile().traverseTime(
            for: edge,
            context: context(
                snow: 0,
                equipment: currentSki,
                history: history,
                datasetVersion: "dataset-v1"
            )
        ))

        XCTAssertEqual(eta, 1_000 / expectedSpeed, accuracy: 0.001)
        XCTAssertGreaterThan(eta, 100)
    }

    func testUntrustedCurrentSkiSampleFallsBackToTrustedNeutralHistory() {
        let ski = equipment(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            width: 100,
            category: "all-mountain"
        )
        let edge = makeRun()
        let thin = observation(
            equipmentKey: ski.observationEquipmentKey,
            count: 1,
            speed: 30
        )
        let neutral = observation(count: 4, speed: 9)
        let history = [edge.id: [
            thin.historyKey: thin,
            neutral.historyKey: neutral
        ]]

        let selected = context(
            snow: 0,
            equipment: ski,
            history: history,
            datasetVersion: "dataset-v1"
        ).observation(for: edge)

        XCTAssertEqual(selected?.equipmentKey, PerEdgeSpeed.neutralEquipmentKey)
        XCTAssertEqual(selected?.rollingSpeedMs, 9)
    }

    func testMismatchedConditionHistoryIsIgnoredIndependentOfDictionaryOrder() throws {
        let edge = makeRun()
        let a = observation(conditions: "a", count: 5, speed: 7)
        let z = observation(conditions: "z", count: 5, speed: 11)
        let first = [edge.id: [a.historyKey: a, z.historyKey: z]]
        let second = [edge.id: [z.historyKey: z, a.historyKey: a]]

        let selectedA = context(
            snow: 0,
            equipment: nil,
            history: first,
            datasetVersion: "dataset-v1"
        ).observation(for: edge)
        let selectedB = context(
            snow: 0,
            equipment: nil,
            history: second,
            datasetVersion: "dataset-v1"
        ).observation(for: edge)

        XCTAssertNil(selectedA)
        XCTAssertNil(selectedB)

        let etaA = try XCTUnwrap(profile().traverseTime(
            for: edge,
            context: context(
                snow: 0,
                equipment: nil,
                history: first,
                datasetVersion: "dataset-v1"
            )
        ))
        let etaB = try XCTUnwrap(profile().traverseTime(
            for: edge,
            context: context(
                snow: 0,
                equipment: nil,
                history: second,
                datasetVersion: "dataset-v1"
            )
        ))
        XCTAssertEqual(etaA, 125, accuracy: 0.001)
        XCTAssertEqual(etaB, etaA, accuracy: 0.001)
    }

    func testInvalidLearnedRowsCannotAffectMeanOrUncertainty() throws {
        let edge = makeRun()
        func row(edgeID: String = "run", speed: Double = 25,
                 duration: Double = 100, variance: Double = 4,
                 peak: Double? = nil, date: Date = .init(timeIntervalSinceReferenceDate: 0)) -> PerEdgeSpeed {
            PerEdgeSpeed(resortId: "test", edgeId: edgeID,
                         conditionsFp: ConditionsFingerprint.defaultBucket,
                         datasetVersion: "dataset-v1", observationCount: 5,
                         rollingSpeedMs: speed, rollingPeakMs: peak,
                         rollingDurationS: duration, rollingSpeedVarianceMs2: variance,
                         lastObservedAt: date)
        }
        let invalid = [
            row(edgeID: "another-trail"), row(speed: 31), row(speed: .infinity),
            row(duration: 0), row(duration: .nan),
            row(duration: GPXSpeedStats.maximumLearningDuration + 1),
            row(variance: -.leastNonzeroMagnitude), row(variance: .nan),
            row(variance: .infinity), row(variance: .greatestFiniteMagnitude),
            row(peak: .nan), row(peak: 31),
            row(date: Date(timeIntervalSinceReferenceDate: .nan))
        ]
        func cost(_ history: [String: [String: PerEdgeSpeed]]) throws -> RouteTraversalEvaluator.Cost {
            try XCTUnwrap(RouteTraversalEvaluator.evaluate(
                edge: edge, profile: profile(),
                context: context(snow: 0, equipment: nil, history: history, datasetVersion: "dataset-v1"),
                elapsedSeconds: 0, approachVariance: 0))
        }
        let baseline = try cost([:])
        for row in invalid {
            let history = [edge.id: [row.historyKey: row]]
            XCTAssertNil(context(snow: 0, equipment: nil, history: history,
                                 datasetVersion: "dataset-v1").observation(for: edge))
            let result = try cost(history)
            XCTAssertEqual(result.seconds, baseline.seconds, accuracy: 0.001)
            XCTAssertEqual(result.variance, baseline.variance, accuracy: 0.001)
        }
    }

    func testDownhillHistoryCannotSupplyLiftUncertainty() throws {
        let lift = makeLift()
        let row = PerEdgeSpeed(resortId: "test", edgeId: lift.id,
                               conditionsFp: ConditionsFingerprint.defaultBucket,
                               datasetVersion: "dataset-v1", observationCount: 5,
                               rollingSpeedMs: 10, rollingDurationS: 100,
                               rollingSpeedVarianceMs2: 4, lastObservedAt: .now)
        let ctx = context(snow: 0, equipment: nil,
                          history: [lift.id: [row.historyKey: row]], datasetVersion: "dataset-v1")
        XCTAssertNil(ctx.observation(for: lift))
        let result = try XCTUnwrap(RouteTraversalEvaluator.evaluate(
            edge: lift, profile: profile(), context: ctx, elapsedSeconds: 0, approachVariance: 0))
        XCTAssertEqual(result.variance, pow(result.seconds * 0.30, 2), accuracy: 0.001)
    }

    func testInvalidCurrentSkiHistoryFallsBackToValidNeutralCohort() throws {
        let ski = equipment(width: 118, category: "powder")
        let edge = makeRun()
        let invalid = observation(equipmentKey: ski.observationEquipmentKey, speed: 31)
        let valid = observation(speed: 8)
        let ctx = context(snow: 0, equipment: ski,
                          history: [edge.id: [invalid.historyKey: invalid, valid.historyKey: valid]],
                          datasetVersion: "dataset-v1")
        XCTAssertEqual(try XCTUnwrap(ctx.observation(for: edge)).rollingSpeedMs, 8)
    }

    func testExactMeasuredPaceDoesNotDoubleApplyTerrainOrWeather() throws {
        let edge = makeRun(isGroomed: false, hasMoguls: true)
        let learned = observation(
            conditions: exactConditions(for: edge, snow: 15),
            speed: 10
        )
        let history = [edge.id: [learned.historyKey: learned]]

        let eta = try XCTUnwrap(profile(conditionMoguls: 0.25).traverseTime(
            for: edge,
            context: context(
                snow: 15,
                equipment: nil,
                history: history,
                datasetVersion: "dataset-v1"
            )
        ))

        XCTAssertEqual(eta, 100, accuracy: 0.001)
    }

    func testUnattributedMeasuredPaceSkipsTerrainButAdaptsToCurrentWeather() throws {
        let edge = makeRun(isGroomed: false, hasMoguls: true)
        let learned = observation(speed: 10)
        let history = [edge.id: [learned.historyKey: learned]]

        func eta(mogulAbility: Double, snow: Double) throws -> Double {
            try XCTUnwrap(profile(conditionMoguls: mogulAbility).traverseTime(
                for: edge,
                context: context(
                    snow: snow,
                    equipment: nil,
                    history: history,
                    datasetVersion: "dataset-v1"
                )
            ))
        }

        let clearConfident = try eta(mogulAbility: 1, snow: 0)
        let clearCautious = try eta(mogulAbility: 0.1, snow: 0)
        let snowyCautious = try eta(mogulAbility: 0.1, snow: 15)

        XCTAssertEqual(clearConfident, 100, accuracy: 0.001)
        XCTAssertEqual(clearCautious, clearConfident, accuracy: 0.001)
        XCTAssertGreaterThan(snowyCautious, clearCautious)
    }

    func testHistoryFingerprintIncludesValuesAndIgnoresInsertionOrder() {
        let slower = observation(conditions: "a", count: 5, speed: 7)
        let faster = observation(conditions: "z", count: 5, speed: 11)
        let changed = observation(conditions: "a", count: 5, speed: 8)
        let forward = ["run": [
            slower.historyKey: slower,
            faster.historyKey: faster
        ]]
        let reverse = ["run": [
            faster.historyKey: faster,
            slower.historyKey: slower
        ]]
        let changedValue = ["run": [
            changed.historyKey: changed,
            faster.historyKey: faster
        ]]

        XCTAssertEqual(
            PerEdgeSpeed.historyFingerprint(forward),
            PerEdgeSpeed.historyFingerprint(reverse)
        )
        XCTAssertNotEqual(
            PerEdgeSpeed.historyFingerprint(forward),
            PerEdgeSpeed.historyFingerprint(changedValue)
        )
    }

    func testSolverContextSignatureIncludesTimeBucketAndEquipmentPhysics() {
        let firstSki = equipment(width: 72, category: "carving")
        let secondSki = equipment(width: 118, category: "powder")
        let morning = context(
            snow: 0,
            equipment: firstSki,
            solveTime: Date(timeIntervalSinceReferenceDate: 0)
        )
        let later = context(
            snow: 0,
            equipment: firstSki,
            solveTime: Date(timeIntervalSinceReferenceDate: 900)
        )
        let otherEquipment = context(
            snow: 0,
            equipment: secondSki,
            solveTime: Date(timeIntervalSinceReferenceDate: 0)
        )

        XCTAssertNotEqual(
            MeetingPointSolver.contextSignature(morning),
            MeetingPointSolver.contextSignature(later)
        )
        XCTAssertNotEqual(
            MeetingPointSolver.contextSignature(morning),
            MeetingPointSolver.contextSignature(otherEquipment)
        )
    }

    func testHourlyWeatherInterpolatesAtPredictedArrivalTime() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: -2,
            stationElevationM: 0,
            windSpeedKmh: 5,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 20,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: -8,
                    windSpeedKmh: 10,
                    visibilityKm: 16,
                    cloudCoverPercent: 20
                ),
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: -4,
                    windSpeedKmh: 50,
                    visibilityKm: 4,
                    cloudCoverPercent: 80
                )
            ]
        )

        let halfway = context.weather(at: start.addingTimeInterval(1_800))
        XCTAssertEqual(halfway.temperatureCelsius, -6, accuracy: 0.001)
        XCTAssertEqual(halfway.windSpeedKmh, 30, accuracy: 0.001)
        XCTAssertEqual(halfway.visibilityKm, 10, accuracy: 0.001)
        XCTAssertEqual(halfway.cloudCoverPercent, 50)
    }

    func testForecastEndFadesContinuouslyBackToCurrentReading() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: -10,
                    windSpeedKmh: 60,
                    visibilityKm: 1,
                    cloudCoverPercent: 100
                )
            ]
        )

        let held = context.weather(at: start.addingTimeInterval(60 * 60))
        let halfway = context.weather(at: start.addingTimeInterval(75 * 60))
        let justBeforeFallback = context.weather(
            at: start.addingTimeInterval(90 * 60 - 1)
        )
        let fallback = context.weather(at: start.addingTimeInterval(90 * 60 + 1))

        XCTAssertEqual(held.windSpeedKmh, 60, accuracy: 0.001)
        XCTAssertEqual(halfway.windSpeedKmh, 30, accuracy: 0.001)
        XCTAssertEqual(halfway.visibilityKm, 10.5, accuracy: 0.001)
        XCTAssertEqual(justBeforeFallback.windSpeedKmh, fallback.windSpeedKmh, accuracy: 0.1)
        XCTAssertEqual(justBeforeFallback.visibilityKm, fallback.visibilityKm, accuracy: 0.1)
    }

    func testLargeForecastGapUsesHoldFadeAndFallbackInsteadOfLongInterpolation() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: -2,
            stationElevationM: 0,
            windSpeedKmh: 20,
            visibilityKm: 10,
            freshSnowCm: 0,
            cloudCoverPercent: 50,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: -10,
                    windSpeedKmh: 60,
                    visibilityKm: 1,
                    cloudCoverPercent: 100
                ),
                .init(
                    time: start.addingTimeInterval(4 * 60 * 60),
                    temperatureCelsius: 2,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                )
            ]
        )

        let middle = context.weather(at: start.addingTimeInterval(2 * 60 * 60))
        let nearUpper = context.weather(at: start.addingTimeInterval(3 * 60 * 60))

        XCTAssertEqual(middle.windSpeedKmh, 20, accuracy: 0.001)
        XCTAssertEqual(middle.visibilityKm, 10, accuracy: 0.001)
        XCTAssertEqual(nearUpper.windSpeedKmh, 0, accuracy: 0.001)
        XCTAssertEqual(nearUpper.visibilityKm, 20, accuracy: 0.001)
    }

    func testRunWeatherPenaltyUsesPredictedArrivalForecast() throws {
        let skier = profile()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                ),
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: 0,
                    windSpeedKmh: 60,
                    visibilityKm: 0.5,
                    cloudCoverPercent: 100
                )
            ]
        )
        let run = makeRun()

        let now = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: 0
        ))
        let anHourLater = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: 3_600
        ))

        XCTAssertGreaterThan(anHourLater, now)
    }

    func testExactMeasuredPaceAdaptsToForecastWithoutDoubleCountingCurrentWeather() throws {
        let skier = profile()
        let run = makeRun()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let learned = observation(
            conditions: exactConditions(for: run, snow: 0),
            speed: 10
        )
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                ),
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: 0,
                    windSpeedKmh: 60,
                    visibilityKm: 0.5,
                    cloudCoverPercent: 100
                )
            ],
            edgeSpeedHistory: [run.id: [learned.historyKey: learned]],
            datasetVersion: "dataset-v1"
        )

        let now = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: 0
        ))
        let anHourLater = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: 3_600
        ))

        XCTAssertEqual(now, 100, accuracy: 0.001)
        XCTAssertGreaterThan(anHourLater, now)
    }

    func testForecastSnowfallAccumulatesOnlyForElapsedIntervalOverlap() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 3,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0,
                    snowfallCm: 4
                ),
                .init(
                    time: start.addingTimeInterval(7_200),
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0,
                    snowfallCm: 6
                )
            ]
        )

        XCTAssertEqual(
            context.effectiveFreshSnowCm(at: start.addingTimeInterval(1_800)),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            context.effectiveFreshSnowCm(at: start.addingTimeInterval(5_400)),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            context.effectiveFreshSnowCm(at: start.addingTimeInterval(-60)),
            3,
            accuracy: 0.001
        )
    }

    func testFutureLearnedPaceFingerprintUsesAccumulatedForecastSnow() throws {
        let run = makeRun(isGroomed: false)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let current = observation(
            conditions: exactConditions(for: run, snow: 0),
            speed: 8
        )
        let snowy = observation(
            conditions: exactConditions(for: run, snow: 5),
            speed: 6
        )
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0,
                    snowfallCm: 5
                )
            ],
            edgeSpeedHistory: [run.id: [
                current.historyKey: current,
                snowy.historyKey: snowy
            ]],
            datasetVersion: "dataset-v1"
        )

        XCTAssertEqual(
            try XCTUnwrap(context.observation(for: run, at: start)).rollingSpeedMs,
            8
        )
        XCTAssertEqual(
            try XCTUnwrap(context.observation(
                for: run,
                at: start.addingTimeInterval(3_600)
            )).rollingSpeedMs,
            6
        )
    }

    func testForecastSnowfallChangesUngroomedArrivalETA() throws {
        let skier = profile()
        let run = makeRun(isGroomed: false)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start.addingTimeInterval(3_600),
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0,
                    snowfallCm: 30
                )
            ]
        )

        let now = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: 0
        ))
        let afterStormHour = try XCTUnwrap(skier.traverseTime(
            for: run,
            context: context,
            arrivalTimeOffsetSeconds: 3_600
        ))

        XCTAssertGreaterThan(afterStormHour, now)
    }

    func testTraverseSnowPenaltyIsContinuousAndProgressive() throws {
        let skier = profile()
        let traverse = GraphEdge(
            id: "snowy-connector",
            sourceID: "a",
            targetID: "b",
            kind: .traverse,
            geometry: [],
            attributes: EdgeAttributes(lengthMeters: 150, isOpen: true)
        )
        func eta(snow: Double) throws -> Double {
            try XCTUnwrap(skier.traverseTime(
                for: traverse,
                context: context(snow: snow, equipment: nil)
            ))
        }

        let justBelowStart = try eta(snow: 4.99)
        let justAboveStart = try eta(snow: 5.01)
        let deepSnow = try eta(snow: 25)

        XCTAssertEqual(justBelowStart, justAboveStart, accuracy: 0.1)
        XCTAssertGreaterThan(deepSnow, justAboveStart)
    }

    func testSolverContextSignatureIncludesHourlyForecast() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func forecastContext(wind: Double) -> TraversalContext {
            TraversalContext(
                solveTime: start,
                latitude: nil,
                longitude: nil,
                temperatureCelsius: 0,
                stationElevationM: 0,
                windSpeedKmh: 0,
                visibilityKm: 20,
                freshSnowCm: 0,
                cloudCoverPercent: 0,
                hourlyWeather: [
                    .init(
                        time: start.addingTimeInterval(3_600),
                        temperatureCelsius: 0,
                        windSpeedKmh: wind,
                        visibilityKm: 20,
                        cloudCoverPercent: 0
                    )
                ]
            )
        }

        XCTAssertNotEqual(
            MeetingPointSolver.contextSignature(forecastContext(wind: 10)),
            MeetingPointSolver.contextSignature(forecastContext(wind: 40))
        )
    }

    func testSolverContextSignatureIncludesForecastSnowfall() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func forecastContext(snowfall: Double) -> TraversalContext {
            TraversalContext(
                solveTime: start,
                latitude: nil,
                longitude: nil,
                temperatureCelsius: 0,
                stationElevationM: 0,
                windSpeedKmh: 0,
                visibilityKm: 20,
                freshSnowCm: 0,
                cloudCoverPercent: 0,
                hourlyWeather: [
                    .init(
                        time: start.addingTimeInterval(3_600),
                        temperatureCelsius: 0,
                        windSpeedKmh: 0,
                        visibilityKm: 20,
                        cloudCoverPercent: 0,
                        snowfallCm: snowfall
                    )
                ]
            )
        }

        XCTAssertNotEqual(
            MeetingPointSolver.contextSignature(forecastContext(snowfall: 0)),
            MeetingPointSolver.contextSignature(forecastContext(snowfall: 5))
        )
    }

    func testSolverForecastIsAnchoredToFreshCurrentReading() throws {
        let graph = MountainGraph(resortID: "test", nodes: [:], edges: [])
        let solver = MeetingPointSolver(graph: graph)
        let solveTime = Date(timeIntervalSinceReferenceDate: 1_800)
        solver.solveTime = solveTime
        solver.temperatureC = -1.3
        solver.windSpeedKmh = 17
        solver.visibilityKm = 12.2
        solver.cloudCoverPercent = 37
        solver.hourlyWeather = [
            HourlyCondition(
                time: solveTime,
                temperatureC: -10,
                snowfallCm: 0,
                cloudCoverPercent: 100,
                weatherCode: 3,
                windSpeedKph: 60,
                visibilityKm: 1
            )
        ]

        let context = solver.makeContext()
        let normalizedSolveTime = try XCTUnwrap(context.solveTime)
        let weather = context.weather(at: normalizedSolveTime)

        XCTAssertEqual(weather.temperatureCelsius, -1.5, accuracy: 0.001)
        XCTAssertEqual(weather.windSpeedKmh, 15, accuracy: 0.001)
        XCTAssertEqual(weather.visibilityKm, 12, accuracy: 0.001)
        XCTAssertEqual(weather.cloudCoverPercent, 40)
    }

    func testCanonicalLiftWaitUsesResortLocalArrivalWeekday() throws {
        let skier = profile()
        let lift = makeLift()
        let sunday = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: liftContext(year: 2026, month: 8, day: 2)
        ))
        let monday = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: liftContext(year: 2026, month: 8, day: 3)
        ))

        XCTAssertGreaterThan(sunday, monday)
    }

    func testLiftHoursPreferAuthoritativeDSTOffsetOverLongitudeApproximation() throws {
        let skier = profile()
        let lift = makeLift()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 15,
            hour: 13,
            minute: 30
        )))
        func context(offset: Int?) -> TraversalContext {
            TraversalContext(
                solveTime: instant,
                latitude: 39.6,
                longitude: -105,
                utcOffsetSeconds: offset,
                temperatureCelsius: 0,
                stationElevationM: 0,
                windSpeedKmh: 0,
                visibilityKm: 20,
                freshSnowCm: 0,
                cloudCoverPercent: 0
            )
        }

        // Colorado is UTC-6 after the March DST transition: 13:30 UTC is
        // 07:30 local and inside the solver's conservative lift window.
        // Longitude/15 alone yields UTC-7 (06:30) and incorrectly closes it.
        XCTAssertNotNil(skier.traverseTime(
            for: lift,
            context: context(offset: -6 * 3_600)
        ))
        XCTAssertNil(skier.traverseTime(
            for: lift,
            context: context(offset: nil)
        ))
    }

    func testSolverContextSignatureIncludesResortUTCOffset() {
        let instant = Date(timeIntervalSinceReferenceDate: 0)
        func context(offset: Int) -> TraversalContext {
            TraversalContext(
                solveTime: instant,
                latitude: 39.6,
                longitude: -105,
                utcOffsetSeconds: offset,
                temperatureCelsius: 0,
                stationElevationM: 0,
                windSpeedKmh: 0,
                visibilityKm: 20,
                freshSnowCm: 0,
                cloudCoverPercent: 0
            )
        }

        XCTAssertNotEqual(
            MeetingPointSolver.contextSignature(context(offset: -6 * 3_600)),
            MeetingPointSolver.contextSignature(context(offset: -7 * 3_600))
        )
    }

    func testLiveLiftWaitWinsOverCanonicalWeekdayBaselines() throws {
        let skier = profile()
        let lift = makeLift(liveWaitMinutes: 1)
        let sunday = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: liftContext(year: 2026, month: 8, day: 2)
        ))
        let monday = try XCTUnwrap(skier.traverseTime(
            for: lift,
            context: liftContext(year: 2026, month: 8, day: 3)
        ))

        XCTAssertEqual(sunday, monday, accuracy: 0.001)
    }

    func testSplitLiftChargesPhysicalQueueExactlyOnce() throws {
        let skier = profile()
        let context = liftContext(year: 2026, month: 8, day: 3)
        let whole = try XCTUnwrap(skier.traverseTime(
            for: makeLift(
                liveWaitMinutes: 1,
                rideTimeSeconds: 300,
                chargesLiftWait: true
            ),
            context: context
        ))
        let entry = try XCTUnwrap(skier.traverseTime(
            for: makeLift(
                liveWaitMinutes: 1,
                rideTimeSeconds: 150,
                chargesLiftWait: true
            ),
            context: context
        ))
        let continuation = try XCTUnwrap(skier.traverseTime(
            for: makeLift(
                liveWaitMinutes: 1,
                rideTimeSeconds: 150,
                chargesLiftWait: false
            ),
            context: context
        ))

        XCTAssertEqual(continuation, 150, accuracy: 0.001)
        XCTAssertEqual(entry + continuation, whole, accuracy: 0.001)
    }

    func testLegacyLiftWithoutQueueMarkerStillChargesOneQueue() throws {
        let skier = profile()
        let context = liftContext(year: 2026, month: 8, day: 3)
        let legacy = try XCTUnwrap(skier.traverseTime(
            for: makeLift(liveWaitMinutes: 1, chargesLiftWait: nil),
            context: context
        ))
        let explicitEntry = try XCTUnwrap(skier.traverseTime(
            for: makeLift(liveWaitMinutes: 1, chargesLiftWait: true),
            context: context
        ))

        XCTAssertEqual(legacy, explicitEntry, accuracy: 0.001)
    }

    func testEdgeLearningFromDifferentDatasetVersionIsIgnored() throws {
        let edge = makeRun()
        let observation = PerEdgeSpeed(
            resortId: "test",
            edgeId: edge.id,
            conditionsFp: ConditionsFingerprint.defaultBucket,
            datasetVersion: "old-dataset",
            observationCount: 10,
            rollingSpeedMs: 30,
            rollingDurationS: 10,
            lastObservedAt: .now
        )
        let skier = profile()
        let versionedContext = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            edgeSpeedHistory: [edge.id: [observation.historyKey: observation]],
            datasetVersion: "current-dataset"
        )

        let eta = try XCTUnwrap(skier.traverseTime(for: edge, context: versionedContext))
        XCTAssertEqual(eta, 125, accuracy: 0.001, "Must fall back to the profile's 8 m/s speed")
    }

    func testLastKnownGoodSkiCatalogRoundTripsForOfflineRouting() throws {
        let entry = SkiCatalogEntry(
            id: UUID(),
            brand: "Atomic",
            model: "Bent 110",
            category: "powder",
            waistWidthMm: 110,
            topsheetAssetKey: "atomic-bent-110"
        )
        let data = try JSONEncoder().encode([entry])

        XCTAssertEqual(SupabaseManager.validatedSkiCatalogCache(data), [entry])
    }

    func testSkiCatalogCacheRejectsCorruptionDuplicatesAndImpossibleWidths() throws {
        XCTAssertNil(SupabaseManager.validatedSkiCatalogCache(Data("not json".utf8)))

        let id = UUID()
        let valid = SkiCatalogEntry(
            id: id,
            brand: "Atomic",
            model: "Bent 110",
            category: "powder",
            waistWidthMm: 110,
            topsheetAssetKey: nil
        )
        let duplicate = SkiCatalogEntry(
            id: id,
            brand: "Atomic",
            model: "Bent 110 Duplicate",
            category: "powder",
            waistWidthMm: 110,
            topsheetAssetKey: nil
        )
        let impossible = SkiCatalogEntry(
            id: UUID(),
            brand: "Broken",
            model: "Width",
            category: nil,
            waistWidthMm: 500,
            topsheetAssetKey: nil
        )

        XCTAssertNil(SupabaseManager.validatedSkiCatalogCache(
            try JSONEncoder().encode([valid, duplicate])
        ))
        XCTAssertNil(SupabaseManager.validatedSkiCatalogCache(
            try JSONEncoder().encode([impossible])
        ))
    }
}
