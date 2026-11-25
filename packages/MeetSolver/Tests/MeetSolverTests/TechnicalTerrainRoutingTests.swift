import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// Technical-terrain reference scenarios. The bundle and profile carry marked
// difficulty and grooming only, so the terrain-comfort cases use grooming
// rather than obstacle density.

/// Every category paced at 8 m/s; only the tier limits what is routed.
private func tiered(_ ability: Ability, limit: Difficulty, speed: Double? = 8) -> SkierProfile {
    var speeds: [Difficulty: Double] = [:]
    for difficulty in [Difficulty.green, .blue, .black, .doubleBlack, .park] {
        speeds[difficulty] = speed
    }
    return SkierProfile(userID: UUID(), ability: ability, maxDifficulty: limit, baselineSpeedMS: speeds)
}

private func gate(_ profile: SkierProfile, _ difficulty: Difficulty) -> Bool {
    var m = Mountain()
    let top = m.node("top", lon: -106.00), base = m.node("base", lon: -106.01)
    let edge = m.run("run", top, base, length: 500, difficulty: difficulty)
    let solve = input(m.bundle(), skier(profile, at: top), skier(profile, at: top))
    return CostModel(input: solve, skier: solve.skiers.0).isWithinAbility(edge)
}

@Test func markedDifficultyPermissionsAreExplicitForEveryTier() {
    let difficulties: [Difficulty] = [.green, .blue, .black, .doubleBlack, .park]
    let cases: [(Ability, Difficulty, [Difficulty])] = [
        (.beginner, .green, [.green]),
        (.intermediate, .blue, [.green, .blue]),
        (.advanced, .black, [.green, .blue, .black, .park]),
        (.expert, .doubleBlack, difficulties),
    ]
    // A pace on file for terrain above the chosen limit (from an old import, or
    // after a downgrade) is not permission to route there.
    for (ability, limit, allowed) in cases {
        for difficulty in difficulties {
            #expect(gate(tiered(ability, limit: limit), difficulty) == allowed.contains(difficulty),
                    "\(ability) / \(difficulty)")
        }
    }
    let beginner = SkierProfile.preset(.beginner, userID: UUID())
    #expect(beginner.baselineSpeedMS[.blue] != nil)
    #expect(!gate(beginner, .blue))
}

@Test func invalidPaceCannotGrantMarkedTerrainPermission() {
    for value: Double? in [nil, 0, -1, .nan, .infinity, -.infinity] {
        let skier = tiered(.expert, limit: .doubleBlack, speed: value)
        for difficulty: Difficulty in [.green, .blue, .black, .doubleBlack, .park] {
            #expect(!gate(skier, difficulty))
        }
    }
}

@Test func blockedStartingTerrainGetsTheEasiestWayDownButNeverPastAClosure() throws {
    // The hard gate here is marked difficulty.
    var m = Mountain()
    let top = m.node("top", lon: -106.00, lat: 40.002, ele: 1_100)
    let base = m.node("base", .liftBottom, lon: -106.00, ele: 900)
    m.run("too-hard", top, base, length: 200, difficulty: .black, group: "trail:too-hard")
    m.meet(base)
    let bundle = m.bundle()
    let limited = skier(tiered(.intermediate, limit: .blue), at: top)
    let friend = skier(tiered(.expert, limit: .doubleBlack), at: base)

    // With no way down within their level, the easiest way down, labelled.
    let best = try MeetSolver.solve(input(bundle, limited, friend)).get().options[0]
    #expect(best.reasons.contains(.easiestWayDownFor(limited.id)))
    #expect(best.routes.0.easiestWayDown?.runsAboveLevel == [.black: 1])
    // A closed start is never diagnosed by relaxing the closure.
    #expect(MeetSolver.solve(input(bundle, limited, friend, status: status(closed: ["trail:too-hard"])))
        == .failure(.originNotOnGraph(limited.id)))
    let route = try MeetSolver.route(for: limited, to: "base", in: input(bundle, limited, friend)).get()
    #expect(route.easiestWayDown?.hardest == .black)
}

/// A skier whose off-piste comfort is the only thing that varies.
private func offPiste(_ ability: Ability) -> SkierProfile { tiered(ability, limit: .doubleBlack) }

@Test func ungroomedTerrainSlowsCautiousSkierMoreThanTechnicalSkier() throws {
    var m = Mountain()
    let top = m.node("top", lon: -106.00), base = m.node("base", lon: -106.01)
    let clear = m.run("clear", top, base, length: 1_000, groomed: true)
    let technical = m.run("technical", top, base, length: 1_000, groomed: false)
    let bundle = m.bundle()
    func eta(_ profile: SkierProfile, _ edge: Edge) throws -> Double {
        let solve = input(bundle, skier(profile, at: top), skier(profile, at: top),
                          conditions: weather(tempC: 0))
        return try #require(CostModel(input: solve, skier: solve.skiers.0).traverseTime(edge))
    }
    let cautious = offPiste(.beginner), confident = offPiste(.expert)
    #expect(try eta(cautious, technical) > eta(cautious, clear) * 1.5)
    #expect(try eta(confident, technical) < eta(confident, clear) * 1.1)
    #expect(try eta(cautious, technical) / eta(cautious, clear)
        > eta(confident, technical) / eta(confident, clear))
}

@Test func routeChoiceUsesTerrainComfortInsteadOfDifficultyAlone() throws {
    var m = Mountain()
    let start = m.node("start", lon: -106, lat: 40.000, ele: 2_400)
    let safeMid = m.node("safe-mid", lon: -106.001, lat: 40.004, ele: 2_200)
    let technicalMid = m.node("technical-mid", lon: -105.999, lat: 40.004, ele: 2_200)
    let meeting = m.node("meeting", .liftBottom, lon: -106, lat: 40.008, ele: 2_000)
    m.run("safe-1", start, safeMid, length: 500)
    m.run("safe-2", safeMid, meeting, length: 500)
    m.run("technical-1", start, technicalMid, length: 400, groomed: false)
    m.run("technical-2", technicalMid, meeting, length: 400, groomed: false)
    m.meet(meeting)
    let bundle = m.bundle()
    func path(_ profile: SkierProfile) throws -> [EdgeID] {
        let who = skier(profile, at: start)
        return try MeetSolver.route(for: who, to: "meeting", in: input(bundle, who, who)).get()
            .legs.map(\.edgeID)
    }
    // All four runs are blue. The shorter pair is ungroomed.
    #expect(try path(offPiste(.beginner)) == ["safe-1", "safe-2"])
    #expect(try path(offPiste(.expert)) == ["technical-1", "technical-2"])
}
