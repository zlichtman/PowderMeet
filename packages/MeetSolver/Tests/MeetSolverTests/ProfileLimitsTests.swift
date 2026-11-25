import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// The skier's own limits and what they ride (specs/06-SOLVER.md section 2,
// "limits" and "equipment"): each hard gate, the part-way exemption, and the
// direction and bound of each pace term.

private let dusk = Clock.afternoon

private func skier(
    equipment: Equipment? = nil, avoid: Set<Avoidance> = [], maxPitch: Double? = nil,
    height: Int? = nil, weight: Int? = nil
) -> SkierProfile {
    SkierProfile(
        userID: UUID(), ability: .expert, maxDifficulty: .doubleBlack,
        baselineSpeedMS: [.green: 8, .blue: 8, .black: 8, .doubleBlack: 8, .park: 8],
        equipment: equipment, avoid: avoid, maxPitchDeg: maxPitch, heightCM: height,
        weightKG: weight
    )
}

private func model(
    _ bundle: ResortBundle, _ profile: SkierProfile, origin: NodeID, snowCM: Double? = nil
) -> CostModel {
    let who = SkierInput(
        id: profile.userID, profile: profile,
        pace: PaceModel(ownerID: profile.userID, computedAt: dusk, stopsPerKm: 0),
        origin: .node(origin)
    )
    let conditions = snowCM.map {
        Conditions(
            resortID: "test", observedAt: dusk, expiresAt: dusk.addingTimeInterval(5_400),
            current: ConditionsSample(
                at: dusk, tempC: -2, windMS: 0, visibilityM: 10_000, cloudPct: 100, snow24hCM: $0
            ),
            hourly: []
        )
    }
    return CostModel(
        input: SolveInput(bundle: bundle, conditions: conditions, at: dusk, skiers: (who, who)),
        skier: who
    )
}

/// One run between two nodes and the time `profile` takes down it.
private func runTime(
    _ profile: SkierProfile, difficulty: Difficulty = .blue, groomed: Bool? = true,
    length: Double = 1_000, drop: Double = 250, grade: Double? = 18, snowCM: Double? = nil,
    remaining: Double = 1
) -> Double? {
    var m = Mountain()
    let top = m.node("top", lon: 0), bottom = m.node("bottom", lon: 0.01)
    let edge = m.run("run", top, bottom, length: length, difficulty: difficulty, groomed: groomed,
                     drop: drop, grade: grade)
    return model(m.bundle(), profile, origin: top.id, snowCM: snowCM)
        .traverseTime(edge, remainingFraction: remaining)
}

@Test func avoidChoicesAreHardGates() {
    #expect(runTime(skier(avoid: [.park]), difficulty: .park) == nil)
    #expect(runTime(skier(avoid: [.park])) != nil)

    #expect(runTime(skier(avoid: [.ungroomed]), groomed: false) == nil)
    // Unknown grooming is not known to be ungroomed.
    #expect(runTime(skier(avoid: [.ungroomed]), groomed: nil) != nil)

    // 1 km dropping 30 m averages 1.7°: a cat track.
    #expect(runTime(skier(avoid: [.flats]), drop: 30, grade: 4) == nil)
    #expect(runTime(skier(avoid: [.flats]), drop: 250) != nil)
    // A short flat link is not a traverse.
    #expect(runTime(skier(avoid: [.flats]), length: 60, drop: 1, grade: 2) != nil)
}

@Test func pitchLimitIsAHardGate() {
    #expect(runTime(skier(maxPitch: 25), grade: 28) == nil)
    #expect(runTime(skier(maxPitch: 25), grade: 24) != nil)
    // No measured pitch: held to the usual steepest pitch of the rating.
    #expect(runTime(skier(maxPitch: 25), difficulty: .black, grade: nil) == nil)
    #expect(runTime(skier(maxPitch: 25), difficulty: .blue, grade: nil) != nil)
}

@Test func aSkierAlreadyOnAnAvoidedRunFinishesIt() {
    #expect(runTime(skier(avoid: [.ungroomed], maxPitch: 15), groomed: false, remaining: 0.4) != nil)
}

@Test func surfaceLiftsCanBeAvoided() {
    var m = Mountain()
    let base = m.node("base", lon: 0), top = m.node("top", lon: 0.01)
    let tbar = m.lift("tbar", base, top, ride: 200, type: .tbar)
    let chair = m.lift("chair", base, top, ride: 200, type: .chair)
    let bundle = m.bundle()
    let wary = model(bundle, skier(avoid: [.surfaceLifts]), origin: base.id)
    #expect(wary.traverseTime(tbar) == nil)
    #expect(wary.traverseTime(chair) != nil)
    #expect(!wary.isWithinAbility(tbar))
    // Already on it: the ride finishes.
    #expect(wary.traverseTime(tbar, remainingFraction: 0.5) != nil)
    #expect(model(bundle, skier(), origin: base.id).traverseTime(tbar) != nil)
}

@Test func aLimitThatBlocksTheOnlyWayIsReportedAsTheSkiersLimit() {
    var m = Mountain()
    let top = m.node("top", lon: 0), base = m.node("base", .base, lon: 0.01)
    m.run("only", top, base, length: 800, groomed: false, drop: 200, grade: 20)
    m.meet(base)
    let bundle = m.bundle()
    let limited = skier(avoid: [.ungroomed]), free = skier()
    let input = SolveInput(bundle: bundle, at: dusk, skiers: (
        SkierInput(id: limited.userID, profile: limited, origin: .node(top.id)),
        SkierInput(id: free.userID, profile: free, origin: .node(base.id))
    ))
    #expect(MeetSolver.solve(input) == .failure(.abilityBlocksAll(limited.userID)))
}

@Test func waistWidthFavoursGroomersWhenNarrowAndPowderWhenWide() throws {
    let narrow = skier(equipment: Equipment(discipline: .ski, type: .allMountain, waistMM: 70))
    let wide = skier(equipment: Equipment(discipline: .ski, type: .allMountain, waistMM: 115))
    #expect(try #require(runTime(narrow)) < #require(runTime(wide)))
    #expect(try #require(runTime(wide, groomed: false, snowCM: 20))
        < #require(runTime(narrow, groomed: false, snowCM: 20)))
    // Bounded: no ski is worth more than a few percent.
    let plain = try #require(runTime(skier()))
    #expect(abs(try #require(runTime(narrow)) / plain - 1) < 0.03)
}

@Test func lengthNeedsHeightAndWeightActsOnFlats() throws {
    let long = Equipment(discipline: .ski, type: .allMountain, lengthCM: 190, waistMM: 90)
    // A partner's height is never known: the length term is then 1.
    #expect(runTime(skier(equipment: long)) == runTime(skier(equipment: Equipment(discipline: .ski, waistMM: 90))))
    let tallOrder = skier(equipment: long, height: 170)
    #expect(try #require(runTime(tallOrder)) < #require(runTime(skier(equipment: long))))
    #expect(try #require(runTime(tallOrder, groomed: false))
        > #require(runTime(skier(equipment: long), groomed: false)))

    let heavy = try #require(runTime(skier(weight: 100), drop: 30, grade: 4))
    let light = try #require(runTime(skier(weight: 50), drop: 30, grade: 4))
    let none = try #require(runTime(skier(), drop: 30, grade: 4))
    #expect(heavy < none && none < light)
    #expect(none / heavy <= 1.06 && light / none <= 1 / 0.90)
    // On a real pitch weight does nothing.
    #expect(runTime(skier(weight: 100)) == runTime(skier()))
}

// MARK: Reference scenarios

// The personal pitch limit.

@Test func explicitPitchLimitRequiresUsablePitchData() {
    // Not a pitch: the run is held to its rating's usual steepest (blue 23°).
    for pitch in [0.0, -1, 91, .nan, .infinity] {
        #expect(runTime(skier(maxPitch: 20), grade: pitch) == nil, "\(pitch)")
    }
    for pitch in [0.1, 10, 20] {
        #expect(runTime(skier(maxPitch: 20), grade: pitch) != nil, "\(pitch)")
    }
}

@Test func unknownPitchDoesNotIntroduceAnUnrequestedHardLimit() {
    #expect(runTime(skier(), grade: 0) != nil)
    #expect(runTime(skier(), grade: nil) != nil)
    var m = Mountain()
    let base = m.node("base", lon: 0), top = m.node("top", lon: 0.01)
    let lift = m.lift("lift", base, top, ride: 200)
    let link = m.connection("link", top, base, length: 200)
    let limited = model(m.bundle(), skier(maxPitch: 20), origin: base.id)
    #expect(limited.traverseTime(lift) != nil)
    #expect(limited.traverseTime(link) != nil)
}

@Test func invalidPitchLimitCannotDisableTheLimit() {
    for limit in [-1.0, 0, 91, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
        #expect(runTime(skier(maxPitch: limit), grade: 10) == nil, "\(limit)")
    }
}

@Test func pitchLimitChoosesKnownAlternativeInsteadOfFasterUnknownRoute() throws {
    var m = Mountain()
    let top = m.node("top", lon: 0), base = m.node("base", .liftBottom, lon: 0.005)
    m.run("unknown", top, base, length: 50, drop: 20, grade: 0)
    m.run("known", top, base, length: 500, drop: 80, grade: 10)
    m.meet(base)
    let bundle = m.bundle()
    func first(_ profile: SkierProfile) throws -> EdgeID? {
        let who = SkierInput(id: profile.userID, profile: profile,
                             pace: PaceModel(ownerID: profile.userID, computedAt: dusk, stopsPerKm: 0),
                             origin: .node(top.id))
        return try MeetSolver.route(for: who, to: RendezvousID(base.id.rawValue),
                                    in: SolveInput(bundle: bundle, at: dusk, skiers: (who, who))).get().legs.first?.edgeID
    }
    #expect(try first(skier()) == "unknown")
    #expect(try first(skier(maxPitch: 20)) == "known")
}

// What the skier rides.

@Test func catalogCategoryAddsSmallDisciplineSpecificAdvantages() throws {
    let allMountain = skier(equipment: Equipment(discipline: .ski, type: .allMountain, waistMM: 90))
    let park = skier(equipment: Equipment(discipline: .ski, type: .park, waistMM: 90))
    let race = skier(equipment: Equipment(discipline: .ski, type: .carving, waistMM: 78))
    let parkOnPark = try #require(runTime(park, difficulty: .park))
    let allOnPark = try #require(runTime(allMountain, difficulty: .park))
    #expect(parkOnPark < allOnPark && parkOnPark / allOnPark > 0.95)
    let raceOnGroomer = try #require(runTime(race))
    let allOnGroomer = try #require(runTime(allMountain))
    #expect(raceOnGroomer < allOnGroomer && raceOnGroomer / allOnGroomer > 0.95)
}

@Test func equipmentSnowResponseIsContinuousAtFormerThresholds() throws {
    let skis = [
        Equipment(discipline: .ski, type: .carving, waistMM: 72),
        Equipment(discipline: .ski, type: .freeride, waistMM: 118),
        Equipment(discipline: .ski, type: .park, waistMM: 95),
    ]
    for gear in skis {
        for (difficulty, groomed) in [(Difficulty.blue, false), (.park, true)] {
            for threshold in [3.0, 8.0] {
                let below = try #require(runTime(skier(equipment: gear), difficulty: difficulty,
                                                 groomed: groomed, snowCM: threshold - 0.0001))
                let above = try #require(runTime(skier(equipment: gear), difficulty: difficulty,
                                                 groomed: groomed, snowCM: threshold + 0.0001))
                #expect(abs(below / above - 1) < 1e-5, "\(gear.type) \(difficulty) \(threshold) cm")
            }
        }
    }
}

@Test func forecastSnowNeverMakesALaterStartFinishEarlier() throws {
    // A 118 mm ski on an ungroomed run, 2 cm now and 10 cm by the next hour.
    var m = Mountain()
    let top = m.node("top", lon: 0), bottom = m.node("bottom", lon: 0.01)
    let edge = m.run("run", top, bottom, length: 1_000, groomed: false, drop: 250, grade: 18)
    let powder = skier(equipment: Equipment(discipline: .ski, type: .freeride, waistMM: 118))
    let who = SkierInput(id: powder.userID, profile: powder,
                         pace: PaceModel(ownerID: powder.userID, computedAt: dusk, stopsPerKm: 0),
                         origin: .node(top.id))
    let conditions = weather(at: dusk, snowCM: 2, hourly: [sample(at: dusk.addingTimeInterval(3_600), snowCM: 10)])
    let cost = CostModel(input: SolveInput(bundle: m.bundle(), conditions: conditions, at: dusk, skiers: (who, who)),
                         skier: who)
    var previous = -Double.infinity
    for start in stride(from: 0.0, through: 3 * 3_600, by: 150) {
        let finish = start + (try #require(cost.traverseTime(edge, elapsedS: start)))
        #expect(finish >= previous - 1e-9, "start \(start)")
        previous = finish
    }
}

@Test func equipmentCannotBypassDifficultyGateOrClosedStatus() {
    let wide = Equipment(discipline: .ski, type: .freeride, waistMM: 118)
    var beginner = SkierProfile.preset(.beginner, userID: UUID())
    beginner.equipment = wide
    #expect(runTime(beginner, difficulty: .black, groomed: false, snowCM: 15) == nil)

    var m = Mountain()
    let top = m.node("top", lon: 0), bottom = m.node("bottom", lon: 0.01)
    let edge = m.run("run", top, bottom, length: 1_000, difficulty: .green, drop: 150, grade: 10, group: "trail:shut")
    let expert = skier(equipment: wide)
    let who = SkierInput(id: expert.userID, profile: expert, origin: .node(top.id))
    let cost = CostModel(input: SolveInput(bundle: m.bundle(), status: status(closed: ["trail:shut"], at: dusk),
                                           at: dusk, skiers: (who, who)), skier: who)
    #expect(cost.traverseTime(edge) == nil)
}
