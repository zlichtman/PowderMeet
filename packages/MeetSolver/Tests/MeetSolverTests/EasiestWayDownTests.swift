import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// The easiest way down (06-SOLVER section 1): a skier with no way down within
// their level is routed the least hard way there is, and the route says so.

/// 10 m/s on every rating; `limit` alone decides what is within their level.
private func limited(_ limit: Difficulty) -> SkierProfile {
    var speeds: [Difficulty: Double] = [:]
    for difficulty in [Difficulty.green, .blue, .black, .doubleBlack, .park] {
        speeds[difficulty] = 10
    }
    return SkierProfile(
        userID: UUID(), ability: .beginner, maxDifficulty: limit, baselineSpeedMS: speeds
    )
}

private func edgeIDs(_ route: Route) -> [String] { route.legs.map(\.edgeID.rawValue) }

@Test func aRouteWithinTheLevelIsAlwaysPreferredToAFasterOneAboveIt() throws {
    var m = Mountain()
    let top = m.node("top", lon: -106.00), mid = m.node("mid", lon: -106.005)
    let base = m.node("base", .liftBottom, lon: -106.01)
    m.run("black-shortcut", top, base, length: 100, difficulty: .black)
    m.run("green-a", top, mid, length: 900, difficulty: .green)
    m.run("green-b", mid, base, length: 900, difficulty: .green)
    m.meet(base)
    let bundle = m.bundle()
    let green = skier(limited(.green), at: top), friend = skier(limited(.doubleBlack), at: base)

    let best = try MeetSolver.solve(input(bundle, green, friend)).get().options[0]
    #expect(edgeIDs(best.routes.0) == ["green-a", "green-b"])
    #expect(best.routes.0.easiestWayDown == nil)
    #expect(!best.reasons.contains(.easiestWayDownFor(green.id)))
    let route = try MeetSolver.route(for: green, to: "base", in: input(bundle, green, friend)).get()
    #expect(edgeIDs(route) == ["green-a", "green-b"])
    #expect(route.easiestWayDown == nil)
}

@Test func withNoWayDownWithinTheLevelTheEasiestWayIsRoutedAndLabelled() throws {
    var m = Mountain()
    let top = m.node("top", lon: -106.00), base = m.node("base", .liftBottom, lon: -106.01)
    m.run("blue-a", top, base, length: 300, difficulty: .blue, group: "trail:blue")
    m.meet(base)
    let bundle = m.bundle()
    let green = skier(limited(.green), at: top), friend = skier(limited(.green), at: base)
    let solveInput = input(bundle, green, friend)

    let best = try MeetSolver.solve(solveInput).get().options[0]
    #expect(best.rendezvous == "base")
    #expect(best.reasons.first == .easiestWayDownFor(green.id))
    let easiest = try #require(best.routes.0.easiestWayDown)
    #expect(easiest.hardest == .blue)
    #expect(easiest.runsAboveLevel == [.blue: 1])
    #expect(easiest.runCount == 1)
    #expect(easiest.metresAboveLevel == 300)
    #expect(easiest.edgeIDs == ["blue-a"])
    #expect(best.routes.1.easiestWayDown == nil)

    // `route` gives the same route for the agreed stop, and `recost` keeps it.
    let route = try MeetSolver.route(for: green, to: "base", in: solveInput).get()
    #expect(route == best.routes.0)
    let eta = try #require(MeetSolver.recost(route, from: Progress(), at: Clock.afternoon, in: solveInput))
    #expect(abs(eta.meanS - route.eta.meanS) < 1)
    // A later instant and a changed level re-price it the same way...
    var lower = limited(.green)
    lower.ability = .beginner
    let relevelled = SkierInput(id: green.id, profile: lower, pace: green.pace, origin: green.origin)
    #expect(MeetSolver.recost(
        route, from: Progress(), at: Clock.afternoon.addingTimeInterval(600),
        in: input(bundle, relevelled, friend)
    ) != nil)
    // ...but a closure still ends it.
    #expect(MeetSolver.recost(
        route, from: Progress(), at: Clock.afternoon,
        in: input(bundle, green, friend, status: status(closed: ["trail:blue"]))
    ) == nil)
    // A normal route never gets the allowance.
    let plain = Route(
        skierID: green.id, legs: route.legs, eta: route.eta, hardestDifficulty: .blue,
        liftCount: 0, lengthM: 300
    )
    #expect(MeetSolver.recost(plain, from: Progress(), at: Clock.afternoon, in: solveInput) == nil)
}

@Test func theEasiestWayIsTheLeastHardRunThenFewestMetresAboveThenTime() throws {
    // Hardest run first: a long blue beats a short black.
    do {
        var m = Mountain()
        let top = m.node("top", lon: -106.00), base = m.node("base", .liftBottom, lon: -106.01)
        m.run("black", top, base, length: 100, difficulty: .black)
        m.run("blue", top, base, length: 2_000, difficulty: .blue)
        m.meet(base)
        let green = skier(limited(.green), at: top)
        let best = try MeetSolver.solve(input(m.bundle(), green, skier(limited(.green), at: base)))
            .get().options[0]
        #expect(edgeIDs(best.routes.0) == ["blue"])
        #expect(best.routes.0.easiestWayDown?.hardest == .blue)
    }
    // Same hardest run: fewer metres above the level beats a quicker way.
    do {
        var m = Mountain()
        let top = m.node("top", lon: -106.00), mid = m.node("mid", lon: -106.005)
        let base = m.node("base", .liftBottom, lon: -106.01)
        m.run("long-blue", top, base, length: 600, difficulty: .blue)
        m.run("short-blue", top, mid, length: 100, difficulty: .blue)
        m.run("green-out", mid, base, length: 1_500, difficulty: .green)
        m.meet(base)
        let green = skier(limited(.green), at: top)
        let best = try MeetSolver.solve(input(m.bundle(), green, skier(limited(.green), at: base)))
            .get().options[0]
        #expect(edgeIDs(best.routes.0) == ["short-blue", "green-out"])
        #expect(best.routes.0.easiestWayDown?.metresAboveLevel == 100)
    }
    // Same hardest run and metres: the quicker way.
    do {
        var m = Mountain()
        let top = m.node("top", lon: -106.00), mid = m.node("mid", lon: -106.005)
        let base = m.node("base", .liftBottom, lon: -106.01)
        m.run("blue-direct", top, base, length: 200, difficulty: .blue)
        m.run("blue-side", top, mid, length: 200, difficulty: .blue)
        m.run("green-slow", mid, base, length: 1_000, difficulty: .green)
        m.meet(base)
        let green = skier(limited(.green), at: top)
        let best = try MeetSolver.solve(input(m.bundle(), green, skier(limited(.green), at: base)))
            .get().options[0]
        #expect(edgeIDs(best.routes.0) == ["blue-direct"])
    }
    // A run split into several edges counts once.
    do {
        var m = Mountain()
        let top = m.node("top", lon: -106.00), mid = m.node("mid", lon: -106.005)
        let base = m.node("base", .liftBottom, lon: -106.01)
        m.run("split-1", top, mid, length: 150, difficulty: .blue, group: "trail:split")
        m.run("split-2", mid, base, length: 150, difficulty: .blue, group: "trail:split")
        m.meet(base)
        let green = skier(limited(.green), at: top)
        let best = try MeetSolver.solve(input(m.bundle(), green, skier(limited(.green), at: base)))
            .get().options[0]
        #expect(best.routes.0.easiestWayDown?.runsAboveLevel == [.blue: 1])
        #expect(best.routes.0.easiestWayDown?.metresAboveLevel == 300)
    }
}

@Test func bothSkiersCanGetTheEasiestWayDownWhicheverPhoneSolves() throws {
    var m = Mountain()
    let left = m.node("left", lon: -106.00), right = m.node("right", lon: -106.02)
    let base = m.node("base", .liftBottom, lon: -106.01)
    m.run("left-blue", left, base, length: 400, difficulty: .blue)
    m.run("right-black", right, base, length: 300, difficulty: .black)
    m.meet(base)
    let bundle = m.bundle()
    let a = skier(limited(.green), at: left), b = skier(limited(.blue), at: right)

    let mine = try MeetSolver.solve(input(bundle, a, b)).get().options[0]
    #expect(mine.reasons.contains(.easiestWayDownFor(a.id)))
    #expect(mine.reasons.contains(.easiestWayDownFor(b.id)))
    #expect(mine.routes.0.easiestWayDown?.runsAboveLevel == [.blue: 1])
    #expect(mine.routes.1.easiestWayDown?.runsAboveLevel == [.black: 1])
    // The partner's phone puts them first and gets the same routes.
    let theirs = try MeetSolver.solve(input(bundle, b, a)).get().options[0]
    #expect(theirs.rendezvous == mine.rendezvous)
    #expect(theirs.routes.0 == mine.routes.1)
    #expect(theirs.routes.1 == mine.routes.0)
}

@Test func aSkierPartWayDownARunAboveTheirLevelIsRoutedOffIt() throws {
    var m = Mountain()
    let top = m.node("top", lon: -106.00), base = m.node("base", .liftBottom, lon: -106.01)
    m.run("black", top, base, length: 400, difficulty: .black)
    m.meet(base)
    let blue = skier(limited(.blue), at: .onEdge("black", fraction: 0.5))
    let best = try MeetSolver.solve(input(m.bundle(), blue, skier(limited(.blue), at: base)))
        .get().options[0]
    #expect(edgeIDs(best.routes.0) == ["black"])
    #expect(best.routes.0.easiestWayDown?.metresAboveLevel == 200)
}

@Test func avoidChoicesStayHardGatesForTheEasiestWayDown() {
    var m = Mountain()
    let top = m.node("top", lon: -106.00), base = m.node("base", .liftBottom, lon: -106.01)
    m.run("ungroomed-black", top, base, length: 400, difficulty: .black, groomed: false)
    m.meet(base)
    var profile = limited(.blue)
    profile.avoid = [.ungroomed]
    let wary = skier(profile, at: top)
    #expect(MeetSolver.solve(input(m.bundle(), wary, skier(limited(.blue), at: base)))
        == .failure(.abilityBlocksAll(wary.id)))
}
