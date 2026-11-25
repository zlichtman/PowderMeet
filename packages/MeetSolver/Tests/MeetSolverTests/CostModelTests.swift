import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// The per-edge cost model, on reference scenarios. Per-edge condition cohorts,
// ski-keyed learned history and cache signatures have no input to run against
// (the pace model is two factors and the cache key is the whole input); the
// list is in `specs/06-SOLVER.md` section 7. Equipment is a pace input
// (`ProfileLimitsTests`), and live lift waits are covered below.

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// Thursday 13 August 2026 at the given UTC time: the lift-queue test day.
private func thursday(_ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date { utc(2026, 8, 13, h, mi, s) }

/// The performance-test skier: a pace on file for every category.
private func racer(_ ability: Ability = .intermediate, park: Double? = 7) -> SkierProfile {
    var speeds: [Difficulty: Double] = [.green: 6, .blue: 8, .black: 9, .doubleBlack: 10]
    speeds[.park] = park
    let limit: Difficulty = switch ability {
    case .beginner: .green
    case .intermediate: .blue
    case .advanced: .black
    case .expert: .doubleBlack
    }
    return SkierProfile(userID: UUID(), ability: ability, maxDifficulty: limit, baselineSpeedMS: speeds)
}

/// One edge between two nodes, in a resort on the prime meridian in UTC.
private struct Lab {
    var bundle: ResortBundle
    var edge: Edge

    static func run(
        difficulty: Difficulty = .blue, groomed: Bool? = true, aspect: Double? = nil,
        lat: Double = 40, lon: Double = 0, group: String? = nil
    ) -> Lab {
        var m = Mountain()
        m.timezone = "UTC"
        let top = m.node("top", lon: lon - 0.001, lat: lat), bottom = m.node("bottom", lon: lon + 0.001, lat: lat)
        let edge = m.run("run", top, bottom, length: 1_000, difficulty: difficulty, groomed: groomed,
                         aspect: aspect, group: group)
        return Lab(bundle: m.bundle(), edge: edge)
    }

    static func lift(
        ride: Double = 300, hours: [OperatingHours] = [], timezone: String = "UTC", lon: Double = 0,
        group: String? = nil
    ) -> Lab {
        var m = Mountain()
        m.timezone = timezone
        let base = m.node("base", lon: lon - 0.001), top = m.node("top", lon: lon + 0.001)
        let edge = m.lift("w1:0", base, top, ride: ride, length: 1_000, hours: hours, group: group)
        return Lab(bundle: m.bundle(), edge: edge)
    }

    func model(
        at: Date, _ profile: SkierProfile = racer(), conditions: Conditions? = nil,
        status: ResortStatus? = nil, pace: PaceModel? = nil
    ) -> CostModel {
        let who = SkierInput(
            id: profile.userID, profile: profile,
            pace: pace ?? PaceModel(ownerID: profile.userID, computedAt: at, stopsPerKm: 0),
            origin: .node(edge.from)
        )
        return CostModel(
            input: SolveInput(bundle: bundle, status: status, conditions: conditions, at: at,
                              skiers: (who, who)),
            skier: who
        )
    }

    func eta(
        at: Date, _ profile: SkierProfile = racer(), conditions: Conditions? = nil,
        offset: Double = 0
    ) -> Double? {
        model(at: at, profile, conditions: conditions).traverseTime(edge, elapsedS: offset)
    }
}

private let night = utc(2026, 1, 15, 2)   // dark at the prime meridian: no sun term

@Test func abilityAndClosureAreHardGates() {
    #expect(Lab.run(difficulty: .black).eta(at: night, racer(.beginner)) == nil)
    let lab = Lab.run(difficulty: .green, group: "trail:shut")
    #expect(lab.eta(at: night, racer(.expert)) != nil)
    let closed = lab.model(at: night, racer(.expert), status: status(closed: ["trail:shut"], at: night))
    #expect(closed.traverseTime(lab.edge) == nil)
    // The relaxed probe explains an ability failure; it never opens a closure.
    #expect(closed.traverseTime(lab.edge, ignoreAbility: true) == nil)
}

@Test func advancedAbilityAllowsParkButNotDoubleBlack() {
    #expect(Lab.run(difficulty: .park).eta(at: night, racer(.advanced)) != nil)
    #expect(Lab.run(difficulty: .doubleBlack).eta(at: night, racer(.advanced)) == nil)
    #expect(Lab.run(difficulty: .park).eta(at: night, racer(.intermediate)) == nil)
}

@Test func missingCategorySpeedNeverInventsTerrainPermission() {
    let lab = Lab.run(difficulty: .park)
    #expect(!lab.model(at: night, racer(.expert, park: nil)).isWithinAbility(lab.edge))
    #expect(lab.eta(at: night, racer(.expert, park: nil)) == nil)
}

@Test func unknownDifficultyIsGatedAsTheResortsHardestMarkedRun() {
    var m = Mountain()
    m.timezone = "UTC"
    let top = m.node("top", lon: 0), mid = m.node("mid", lon: 0.001), bottom = m.node("bottom", lon: 0.002)
    m.run("marked-black", top, mid, length: 500, difficulty: .black)
    let unrated = m.run("unrated", mid, bottom, length: 500, difficulty: .unknown)
    let lab = Lab(bundle: m.bundle(), edge: unrated)
    #expect(lab.eta(at: night, racer(.intermediate)) == nil)
    #expect(lab.eta(at: night, racer(.advanced)) != nil)
}

@Test func unknownDifficultyWithAMeasuredPitchIsGatedByThatPitch() {
    var m = Mountain()
    m.timezone = "UTC"
    let top = m.node("top", lon: 0), mid = m.node("mid", lon: 0.001), bottom = m.node("bottom", lon: 0.002)
    m.run("marked-double", top, mid, length: 500, difficulty: .doubleBlack)
    let flat = m.run("flat-link", mid, bottom, length: 40, difficulty: .unknown, grade: 6)
    let steep = m.run("steep-link", mid, bottom, length: 40, difficulty: .unknown, grade: 36)
    #expect(Lab(bundle: m.bundle(), edge: flat).eta(at: night, racer(.beginner)) != nil)
    #expect(Lab(bundle: m.bundle(), edge: steep).eta(at: night, racer(.advanced)) == nil)
    #expect(Lab(bundle: m.bundle(), edge: steep).eta(at: night, racer(.expert)) != nil)
}

@Test func heuristicLiftWaitCurveIsFIFOAcrossFormerBucketDrops() throws {
    let lab = Lab.lift()
    for boundaryHour in [12, 15] {
        // One second either side of the hour, from the same solve instant.
        let model = lab.model(at: thursday(boundaryHour - 1, 59))
        let before = 59 + (try #require(model.traverseTime(lab.edge, elapsedS: 59)))
        let after = 60 + (try #require(model.traverseTime(lab.edge, elapsedS: 60)))
        #expect(after > before)
        #expect(after - before < 2)
    }
}

@Test func continuousQueueCurveStillModelsPeakAndLateAfternoon() throws {
    let lab = Lab.lift()
    let peak = try #require(lab.eta(at: thursday(10)))
    let late = try #require(lab.eta(at: thursday(15)))
    #expect(abs(peak - late - 54) < 0.001)   // 90 s × (1.5 − 0.9)
}

@Test func knownCloseRejectsLiftReachedAfterClosing() {
    let hours = [OperatingHours(days: Array(1...7), openMinute: 8 * 60, closeMinute: 16 * 60)]
    let lab = Lab.lift(hours: hours)
    let model = lab.model(at: thursday(15, 58))
    #expect(model.traverseTime(lab.edge) != nil)
    // Reached at close, and reached a minute before with a queue that runs past it.
    #expect(model.traverseTime(lab.edge, elapsedS: 120) == nil)
    #expect(model.traverseTime(lab.edge, elapsedS: 60) == nil)
    #expect(lab.model(at: thursday(7, 59)).traverseTime(lab.edge) == nil)

    // A lift that only runs Monday to Friday is shut on Sunday 2 August.
    let weekdays = Lab.lift(hours: [OperatingHours(days: [1, 2, 3, 4, 5], openMinute: 480, closeMinute: 960)])
    #expect(weekdays.eta(at: utc(2026, 8, 3, 12)) != nil)
    #expect(weekdays.eta(at: utc(2026, 8, 2, 12)) == nil)
}

@Test func forecastLiftWindCurveRemainsFIFOWhenStormClears() throws {
    let lab = Lab.lift()
    let start = thursday(10)
    let model = lab.model(at: start, conditions: weather(
        at: start, tempC: 0, windKmh: 100,
        hourly: [sample(at: start, tempC: 0, windKmh: 100),
                 sample(at: start.addingTimeInterval(3_600), tempC: 0, windKmh: 20)]
    ))
    var prior = -Double.infinity
    for offset in stride(from: 0.0, through: 3_600.0, by: 15) {
        let completion = offset + (try #require(model.traverseTime(lab.edge, elapsedS: offset)))
        #expect(completion > prior)
        prior = completion
    }
}

@Test func forecastRunCostRemainsFIFOWhenWeatherClears() throws {
    let lab = Lab.run()
    let start = thursday(10)
    let model = lab.model(at: start, conditions: weather(
        at: start, windKmh: 70, visibilityKm: 0.5, cloudPct: 100,
        hourly: [sample(at: start, windKmh: 70, visibilityKm: 0.5, cloudPct: 100),
                 sample(at: start.addingTimeInterval(3_600), visibilityKm: 20)]
    ))
    var prior = -Double.infinity
    for offset in stride(from: 0.0, through: 3_600.0, by: 15) {
        let completion = offset + (try #require(model.traverseTime(lab.edge, elapsedS: offset)))
        #expect(completion > prior)
        prior = completion
    }
}

@Test func sunRoutingPhysicsIsContinuousAcrossDisplayThresholds() {
    #expect(abs(SunExposure.speedMultiplier(exposure: 0.6999, temperatureC: 0)
        - SunExposure.speedMultiplier(exposure: 0.7001, temperatureC: 0)) < 0.001)
    #expect(abs(SunExposure.speedMultiplier(exposure: 0.8, temperatureC: -1.0001)
        - SunExposure.speedMultiplier(exposure: 0.8, temperatureC: -0.9999)) < 0.001)
}

@Test func coldSnowGlideIsContinuousAcrossFormerTemperatureBuckets() {
    for threshold in [-15.0, -8.0, -3.0] {
        #expect(abs(Traversal.Run.iceSpeedFactor(at: threshold - 0.0001)
            - Traversal.Run.iceSpeedFactor(at: threshold + 0.0001)) < 0.001)
    }
    #expect(abs(Traversal.Run.iceSpeedFactor(at: -15) - 0.8) < 0.001)
    #expect(abs(Traversal.Run.iceSpeedFactor(at: 0) - 1) < 0.001)
}

@Test func icyAbilityPenaltyGrowsWithColdForACautiousSkier() throws {
    // No continuity check at −3 °C: temperature enters in whole degrees, so the
    // two sides of that boundary are the same input.
    var cautious = racer(.beginner)
    cautious.maxDifficulty = .blue
    let lab = Lab.run()
    func eta(_ temperature: Double, _ profile: SkierProfile) throws -> Double {
        try #require(lab.eta(at: night, profile, conditions: weather(at: night, tempC: temperature)))
    }
    #expect(try eta(-7, cautious) > eta(-3, cautious))
    // The cold-snow glide term slows everyone; the icy-ability term is extra.
    let confident = racer(.expert)
    #expect(try eta(-7, cautious) / eta(-3, cautious) > eta(-7, confident) / eta(-3, confident))
}

@Test func liftWindSlowsRideWithoutInventingExtraQueue() throws {
    // Live status says the lift is running, so no wind hold is guessed.
    let lab = Lab.lift(ride: 300, group: "lift:w1")
    let start = thursday(10)
    let running = live([:], observed: start, groups: ["lift:w1": .open])
    func eta(windKmh: Double) throws -> Double {
        try #require(lab.model(
            at: start, conditions: weather(at: start, tempC: 0, windKmh: windKmh), status: running
        ).traverseTime(lab.edge))
    }
    let calm = try eta(windKmh: 0)
    // 22 m/s (79.2 km/h) sits 96 % of the way from the 60 to the 80 km/h anchor.
    let windy = try eta(windKmh: 79.2)
    #expect(abs(calm - (300 + 90 * 1.5)) < 0.001)
    #expect(abs(windy - calm - 300 * (1.2 + 0.3 * 0.96 - 1)) < 0.001)
}

@Test func runSunExposureUsesEdgeArrivalTime() throws {
    let solveTime = utc(2026, 7, 1, 12)          // before dawn at 106°W
    let arrivalOffset = 6.0 * 3_600              // late morning there
    let sunnyAspect = SunExposure.solarPosition(
        date: solveTime.addingTimeInterval(arrivalOffset), latitude: 45, longitude: -106
    ).azimuthDeg
    let lab = Lab.run(aspect: sunnyAspect, lat: 45, lon: -106)
    let model = lab.model(at: solveTime, conditions: weather(at: solveTime, tempC: 2))
    let atSolve = try #require(model.traverseTime(lab.edge))
    let atArrival = try #require(model.traverseTime(lab.edge, elapsedS: arrivalOffset))
    #expect(atArrival > atSolve)
}

@Test func solarPositionUsesMountainLongitudeAtAnAbsoluteInstant() {
    // 19:00 UTC is about solar noon at 105°W whatever zone the phone is in. At
    // 45°N near the solstice the sun is high and almost due south.
    let position = SunExposure.solarPosition(date: utc(2026, 6, 21, 19), latitude: 45, longitude: -105)
    #expect(abs(position.altitudeDeg - 68.4) < 0.7)
    #expect(abs(position.azimuthDeg - 180) < 1.5)
}

@Test func solarPositionChangesWithMountainLongitudeNotDeviceClock() {
    let instant = utc(2026, 6, 21, 19)
    let west = SunExposure.solarPosition(date: instant, latitude: 45, longitude: -105)
    let east = SunExposure.solarPosition(date: instant, latitude: 45, longitude: -75)
    #expect(west.altitudeDeg > east.altitudeDeg)
    #expect(east.azimuthDeg > 180)
}

@Test func learnedEdgePaceSkipsTerrainButAdaptsToWeather() throws {
    let lab = Lab.run(groomed: false)
    var cautious = racer(.beginner)
    cautious.maxDifficulty = .blue
    func eta(_ profile: SkierProfile, snow: Double, learned: Bool = true) throws -> Double {
        let pace = PaceModel(
            ownerID: profile.userID, computedAt: night,
            edgeFactor: learned ? ["run": 1.25] : [:], stopsPerKm: 0
        )
        return try #require(lab.model(
            at: night, profile, conditions: weather(at: night, tempC: 0, snowCM: snow), pace: pace
        ).traverseTime(lab.edge))
    }
    // 8 m/s × 1.25 learned on this edge: the measurement already contains the
    // edge's terrain, so off-piste comfort is not applied a second time.
    let clearConfident = try eta(racer(.expert), snow: 0)
    let clearCautious = try eta(cautious, snow: 0)
    #expect(abs(clearConfident - 100) < 0.001)
    #expect(abs(clearCautious - clearConfident) < 0.001)
    #expect(try eta(cautious, snow: 15) > clearCautious)
    // Without a learned pace the same skier pays for the ungroomed surface.
    #expect(try eta(cautious, snow: 0, learned: false) > 125)
}

@Test func stopsAreAddedToMovingTime() throws {
    // Elapsed time includes stops, 0.4 per km of 20 s when nothing is learned.
    // Every reference scenario runs with a learned rate of zero.
    let lab = Lab.run()
    let still = weather(at: night, tempC: 0)
    func eta(stopsPerKm: Double?) throws -> Double {
        let me = racer()
        let who = SkierInput(
            id: me.userID, profile: me,
            pace: stopsPerKm.map { PaceModel(ownerID: me.userID, computedAt: night, stopsPerKm: $0) },
            origin: .node("top")
        )
        return try #require(CostModel(
            input: SolveInput(bundle: lab.bundle, conditions: still, at: night, skiers: (who, who)),
            skier: who
        ).traverseTime(lab.edge))
    }
    #expect(abs(try eta(stopsPerKm: 0) - 125) < 0.001)
    #expect(abs(try eta(stopsPerKm: nil) - 133) < 0.001)
    #expect(abs(try eta(stopsPerKm: 1) - 145) < 0.001)
}

@Test func runWeatherPenaltyUsesPredictedArrivalForecast() throws {
    let lab = Lab.run()
    let model = lab.model(at: night, conditions: weather(
        at: night, tempC: 0, visibilityKm: 20,
        hourly: [sample(at: night.addingTimeInterval(3_600), tempC: 0, windKmh: 60,
                        visibilityKm: 0.5, cloudPct: 100)]
    ))
    #expect(try #require(model.traverseTime(lab.edge, elapsedS: 3_600))
        > (try #require(model.traverseTime(lab.edge))))
}

@Test func forecastSnowChangesUngroomedArrivalETA() throws {
    let lab = Lab.run(groomed: false)
    let model = lab.model(at: night, conditions: weather(
        at: night, tempC: 0,
        hourly: [sample(at: night.addingTimeInterval(3_600), tempC: 0, snowCM: 30)]
    ))
    #expect(try #require(model.traverseTime(lab.edge, elapsedS: 3_600))
        > (try #require(model.traverseTime(lab.edge))))
}

@Test func connectionSnowPenaltyIsContinuousAndProgressive() throws {
    #expect(abs(Traversal.Connection.speedFactor(freshSnowCM: 4.99)
        - Traversal.Connection.speedFactor(freshSnowCM: 5.01)) < 0.001)
    var m = Mountain()
    m.timezone = "UTC"
    let a = m.node("a", lon: 0), b = m.node("b", lon: 0.001)
    let lab = Lab(bundle: m.bundle(), edge: m.connection("snowy-connector", a, b, length: 150))
    func eta(snow: Double) throws -> Double {
        try #require(lab.eta(at: night, conditions: weather(at: night, tempC: 0, snowCM: snow)))
    }
    #expect(abs(try eta(snow: 0) - 100) < 0.001)
    #expect(try eta(snow: 25) > eta(snow: 5))
    #expect(abs(try eta(snow: 5) - eta(snow: 0)) < 0.001)
}

@Test func forecastIsAnchoredToTheFreshCurrentReading() {
    let solveTime = Date(timeIntervalSinceReferenceDate: 1_800)
    let current = ConditionsSample(
        at: solveTime.addingTimeInterval(-300), tempC: -1.3, windMS: 4.72, visibilityM: 12_200,
        cloudPct: 37
    )
    let stale = ConditionsSample(at: solveTime, tempC: -10, windMS: 16.7, visibilityM: 1_000, cloudPct: 100)
    let quantized = Quantize.conditions(Conditions(
        resortID: "test", observedAt: solveTime, expiresAt: solveTime.addingTimeInterval(5_400),
        current: current, hourly: [stale]
    ), at: solveTime)
    // The current block is fresher than the hourly series: it anchors the curve
    // at the solve instant, coarsened by the one set of quantization rules.
    let now = quantized?.sample(at: solveTime)
    #expect(now?.tempC == -1)
    #expect(now?.windMS == 5)
    #expect(now?.visibilityM == 12_000)
    #expect(now?.cloudPct == 40)
    #expect(Quantize.time(Date(timeIntervalSinceReferenceDate: 1_859.9)) == solveTime)
}

@Test func liftQueueUsesResortLocalArrivalWeekday() throws {
    let lab = Lab.lift()
    let sunday = try #require(lab.eta(at: utc(2026, 8, 2, 12)))
    let monday = try #require(lab.eta(at: utc(2026, 8, 3, 12)))
    #expect(abs(sunday - 300 - (monday - 300) * 1.4) < 0.001)

    // 01:00 UTC on Monday is still Sunday evening (19:00) in Denver.
    let denver = Lab.lift(timezone: "America/Denver", lon: -105)
    let localSunday = try #require(denver.eta(at: utc(2026, 8, 3, 1)))
    let localMonday = try #require(denver.eta(at: utc(2026, 8, 4, 1)))
    #expect(localSunday > localMonday)
}

@Test func liftHoursUseTheBundlesTimeZoneNotLongitudeOrTheDevice() {
    // Colorado is UTC−6 after the March change: 13:30 UTC is 07:30 local, inside
    // the conservative window. Longitude alone gives UTC−7 (06:30) and closes it.
    let instant = utc(2026, 3, 15, 13, 30)
    #expect(Lab.lift(timezone: "America/Denver", lon: -105).eta(at: instant) != nil)
    #expect(Lab.lift(timezone: "Not/AZone", lon: -105).eta(at: instant) == nil)
}

@Test func splitLiftChargesPhysicalQueueExactlyOnce() throws {
    var m = Mountain()
    m.timezone = "UTC"
    let base = m.node("base", lon: 0), mid = m.node("mid", lon: 0.001), top = m.node("top", lon: 0.002)
    let whole = m.lift("w7:0", base, top, ride: 300)
    let entry = m.lift("w8:0", base, mid, ride: 150)
    let onward = m.lift("w8:1", mid, top, ride: 150)
    let lab = Lab(bundle: m.bundle(), edge: whole)
    let model = lab.model(at: utc(2026, 8, 3, 12))
    let wholeTime = try #require(model.traverseTime(whole))
    let entryTime = try #require(model.traverseTime(entry))
    let continuation = try #require(model.traverseTime(onward, elapsedS: entryTime, previous: entry))
    #expect(abs(continuation - 150) < 0.001)
    #expect(abs(entryTime + continuation - wholeTime) < 0.001)
    // Boarded on its own at the mid-station, the upper segment has its own queue.
    #expect(try #require(model.traverseTime(onward)) > 150)
}

// MARK: Live lift waits

/// A fresh row observed at `observed` with live waits in minutes.
private func live(_ waits: [String: Double], observed: Date, groups: [String: GroupState] = [:]) -> ResortStatus {
    var states: [GroupID: GroupState] = [:]
    for (id, state) in groups { states[GroupID(id)] = state }
    var minutes: [GroupID: Double] = [:]
    for (id, wait) in waits { minutes[GroupID(id)] = wait }
    return ResortStatus(
        resortID: "test", observedAt: observed, expiresAt: observed.addingTimeInterval(75 * 60),
        source: .epic, groups: states, waitMinutes: minutes
    )
}

@Test func liveLiftWaitWinsOverCanonicalWeekdayBaselines() throws {
    // A one-minute live wait makes Sunday and Monday the same ride.
    let lab = Lab.lift(group: "lift:w1")
    let sunday = utc(2026, 8, 2, 12), monday = utc(2026, 8, 3, 12)
    func eta(_ at: Date) throws -> Double {
        try #require(lab.model(at: at, status: live(["lift:w1": 1], observed: at)).traverseTime(lab.edge))
    }
    #expect(abs(try eta(sunday) - (300 + 60)) < 0.001)
    #expect(abs(try eta(monday) - (300 + 60)) < 0.001)
}

@Test func unknownOrStaleLiveWaitPricesTheModelledQueue() throws {
    let lab = Lab.lift(group: "lift:w1")
    let at = utc(2026, 8, 3, 12)
    let modelled = try #require(lab.eta(at: at))
    // A wait for another lift, or none, is today's price exactly.
    let other = lab.model(at: at, status: live(["lift:other": 25], observed: at))
    #expect(other.traverseTime(lab.edge) == modelled)
    // Zero is what feeds report for an unmeasured lift as often as for no line.
    let zero = lab.model(at: at, status: live(["lift:w1": 0], observed: at))
    #expect(zero.traverseTime(lab.edge) == modelled)
    // A row past its expiry keeps closures only: its queue minutes are dropped.
    let old = at.addingTimeInterval(-2 * 3_600)
    let stale = lab.model(at: at, status: live(["lift:w1": 25], observed: old))
    #expect(stale.traverseTime(lab.edge) == modelled)
}

@Test func liveWaitAppliesAboveTheModelledCapAndFadesWithoutBreakingFIFO() throws {
    let lab = Lab.lift(group: "lift:w1")
    let at = utc(2026, 8, 3, 12)
    let model = lab.model(at: at, status: live(["lift:w1": 25], observed: at))
    // Reached now: the reported 25 minutes, past the modelled 10-minute cap.
    #expect(abs(try #require(model.traverseTime(lab.edge)) - (300 + 25 * 60)) < 0.001)
    // Reached later, the live wait hands back to the model, and leaving later
    // never gets the skier up the lift sooner (I-04).
    var previousFinish = -Double.infinity
    for offset in stride(from: 0.0, through: 2 * 3_600, by: 60) {
        let finish = offset + (try #require(model.traverseTime(lab.edge, elapsedS: offset)))
        #expect(finish >= previousFinish - 1e-9)
        previousFinish = finish
    }
    let modelled = try #require(lab.model(at: at).traverseTime(lab.edge, elapsedS: 2 * 3_600))
    #expect(abs(try #require(model.traverseTime(lab.edge, elapsedS: 2 * 3_600)) - modelled) < 0.001)
}

@Test func liveWaitCountsAgainstLastChair() {
    // Closes at 12:20 local; a 25-minute line at 12:00 cannot be cleared in time.
    let hours = [OperatingHours(days: [1, 2, 3, 4, 5, 6, 7], openMinute: 9 * 60, closeMinute: 12 * 60 + 20)]
    let lab = Lab.lift(hours: hours, group: "lift:w1")
    let at = utc(2026, 8, 3, 12)
    #expect(lab.eta(at: at) != nil)
    #expect(lab.model(at: at, status: live(["lift:w1": 25], observed: at)).traverseTime(lab.edge) == nil)
}

@Test func aLikelyWindHoldCostsItsExpectedWaitOnlyWhereNoStatusSpeaks() throws {
    let lab = Lab.lift(ride: 300, group: "lift:w1")
    let start = thursday(10)
    let gale = weather(at: start, tempC: 0, windKmh: 79.2)
    let reported = try #require(lab.model(
        at: start, conditions: gale, status: live([:], observed: start, groups: ["lift:w1": .open])
    ).traverseTime(lab.edge))
    let guessed = try #require(lab.model(at: start, conditions: gale).traverseTime(lab.edge))
    // Part of the 15-minute hold, never all of it and never more.
    #expect(guessed - reported > 300)
    #expect(guessed - reported < 900)
    // A breeze is no hold.
    let breeze = weather(at: start, tempC: 0, windKmh: 30)
    #expect(lab.model(at: start, conditions: breeze).windHoldLikelihood(lab.edge, atOffset: 0) == 0)
}

@Test func leavingLaterNeverBoardsEarlierWhileGustsBuild() throws {
    let lab = Lab.lift(ride: 300)
    let start = thursday(10)
    // Calm to a gale inside one hour: the steepest forecast a front brings.
    let front = weather(at: start, tempC: 0, hourly: [
        sample(at: start, tempC: 0, windKmh: 20),
        sample(at: start.addingTimeInterval(3_600), tempC: 0, windKmh: 110),
    ])
    let model = lab.model(at: start, conditions: front)
    var lastArrival = -Double.infinity
    for offset in stride(from: 0.0, through: 5_400, by: 60) {
        let arrival = offset + (try #require(model.traverseTime(lab.edge, elapsedS: offset)))
        #expect(arrival >= lastArrival)
        lastArrival = arrival
    }
}

@Test func aSlopeOfUnknownAspectFadesInAtSunriseLikeAnyOther() {
    // One winter day at 50° N, minute by minute: no jump in exposure anywhere.
    let dawn = utc(2026, 1, 15, 0)
    var last = SunExposure.exposure(aspectDeg: nil, at: dawn, latitude: 50, longitude: 0, cloudPct: 0)
    var peak = last
    for minute in 1...(24 * 60) {
        let now = dawn.addingTimeInterval(Double(minute) * 60)
        let exposure = SunExposure.exposure(aspectDeg: nil, at: now, latitude: 50, longitude: 0, cloudPct: 0)
        #expect(abs(exposure - last) < 0.01)
        last = exposure
        peak = max(peak, exposure)
    }
    #expect(peak > 0.1)
}

// The lab's run sits at 2,500 m. These rows say the forecast is for 500 m.
private func mountainWeather(
    tempC: Double = -2, windKmh: Double = 0, _ change: (inout Conditions) -> Void = { _ in }
) -> Conditions {
    var conditions = weather(at: night, tempC: tempC, windKmh: windKmh)
    conditions.elevationM = 500
    change(&conditions)
    return conditions
}

@Test func aRunAboveAnInversionIsPacedByTheWarmerAirAloft() throws {
    let lab = Lab.run()
    // −10 °C in the valley. By the standard lapse the run would be far colder
    // still; the levels aloft say it is mild up there.
    let lapse = try #require(lab.eta(at: night, conditions: mountainWeather(tempC: -10)))
    let inversion = try #require(lab.eta(at: night, conditions: mountainWeather(tempC: -10) {
        $0.current.temp850C = -2
        $0.current.temp700C = -4
    }))
    #expect(inversion < lapse)
}

@Test func aSlopeTurnedIntoTheWindIsSlowerThanOneInItsLee() throws {
    func eta(aspect: Double) throws -> Double {
        try #require(Lab.run(aspect: aspect).eta(
            at: night, conditions: mountainWeather(windKmh: 50) { $0.current.windDirDeg = 270 }
        ))
    }
    #expect(try eta(aspect: 270) > eta(aspect: 90))
}

@Test func aRunInsideLowCloudIsSlowerAndNeverFasterThanTheResortReading() throws {
    let lab = Lab.run()
    let clear = try #require(lab.eta(at: night, conditions: mountainWeather()))
    // Dew point 4 °C under the temperature puts the base 500 m above the
    // forecast height, far below the run.
    let cloud = try #require(lab.eta(at: night, conditions: mountainWeather {
        $0.current.dewPointC = -6
        $0.current.cloudLowPct = 100
    }))
    let thin = try #require(lab.eta(at: night, conditions: mountainWeather {
        $0.current.dewPointC = -6
        $0.current.cloudLowPct = 20
    }))
    #expect(cloud > clear)
    #expect(thin == clear)
}

@Test func snowThatThawedAndRefrozeIsSlowerUntilNewSnowCoversIt() throws {
    // Ungroomed, with the levels aloft pinning the run near −5 °C now.
    let lab = Lab.run(groomed: false)
    func eta(peakC: Double, snowCM: Double = 0) throws -> Double {
        var conditions = weather(at: night, tempC: 5, snowCM: snowCM)
        conditions.elevationM = 500
        conditions.current.temp850C = -1
        conditions.current.temp700C = -8
        conditions.recent = [RecentConditions(at: night.addingTimeInterval(-10 * 3_600), tempC: peakC)]
        return try #require(lab.eta(at: night, conditions: conditions))
    }
    // A valley peak of 16 °C was above freezing at the run; 0 °C was not.
    #expect(try eta(peakC: 16) > eta(peakC: 0))
    #expect(try eta(peakC: 16, snowCM: 10) == eta(peakC: 0, snowCM: 10))
}
