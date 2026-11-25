import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// Solver safety reference scenarios, plus the rule that fresh status is part of
// a live solve (invariant I-07).

@Test func strictSolveNeverSubstitutesNearbyEscapeNode() {
    var m = Mountain()
    let dead = m.node("dead", lon: -106, lat: 40.0000, ele: 3_000)
    let start = m.node("start", .base, lon: -106, lat: 40.0001, ele: 3_000)
    let target = m.node("target", .liftBottom, lon: -106, lat: 39.99, ele: 2_900)
    m.run("safe-run", start, target, length: 1_000, groomed: nil)
    m.meet(target)
    let bundle = m.bundle()
    let a = skier(profile(), at: dead), b = skier(profile(), at: start)
    // "dead" is eleven metres from a node that routes. It is still not that node.
    #expect(MeetSolver.solve(input(bundle, a, b)) == .failure(.originNotOnGraph(a.id)))

    let nowhere = skier(profile(), at: .node("not-in-this-bundle"))
    #expect(MeetSolver.solve(input(bundle, b, nowhere)) == .failure(.originNotOnGraph(nowhere.id)))
    #expect(MeetSolver.route(for: nowhere, to: "target", in: input(bundle, b, nowhere))
        == .failure(.originNotOnGraph(nowhere.id)))
}

@Test func unknownStatusIsLabelledAndKnownClosuresSurviveStaleness() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let near = m.node("near", .liftBottom, lon: -106.02)
    let far = m.node("far", .liftBottom, lon: -106.03)
    m.run("a-near", a, near, length: 100, group: "trail:near")
    m.run("b-near", b, near, length: 100, group: "trail:near")
    m.run("a-far", a, far, length: 400, group: "trail:far")
    m.run("b-far", b, far, length: 400, group: "trail:far")
    m.meet(near)
    m.meet(far)
    let bundle = m.bundle()
    let skierA = skier(at: a), skierB = skier(at: b)
    let now = Clock.afternoon
    func solve(_ status: ResortStatus?, _ policy: StatusPolicy = .degraded)
        -> Result<MeetOptions, SolveFailure> {
        MeetSolver.solve(input(bundle, skierA, skierB, status: status,
                               options: SolveOptions(statusPolicy: policy)))
    }
    let closure = ResortStatus(
        resortID: "test", observedAt: now.addingTimeInterval(-600),
        expiresAt: now.addingTimeInterval(3_900), source: .epic,
        groups: ["trail:near": .closed, "trail:far": .open]
    )

    // Fresh status: the closure is honoured and nothing is badged.
    let fresh = try solve(closure).get()
    #expect(fresh.options.map(\.rendezvous) == ["far"])
    #expect(fresh.statusFreshness == .fresh)
    #expect(!fresh.degraded)
    // Nothing leads on from `far`, so the option also says who is stuck there.
    #expect(fresh.options[0].reasons == [
        .noOnwardRouteFor(skierA.id), .noOnwardRouteFor(skierB.id), .onlyOptionUnderClosures,
    ])

    // No status at all: strict refuses; degraded solves and says so on every card.
    #expect(solve(nil, .strict) == .failure(.statusExpired))
    let blind = try solve(nil).get()
    #expect(blind.degraded)
    #expect(blind.statusFreshness == .unavailable)
    #expect(blind.options[0].rendezvous == "near")
    #expect(blind.options.allSatisfy { $0.reasons.contains(.statusUnknown) })

    // An hour past expiry: still refused under strict, and under degraded the
    // closure we were told about is still a closure.
    var stale = closure
    stale.expiresAt = now.addingTimeInterval(-3_600)
    #expect(solve(stale, .strict) == .failure(.statusExpired))
    let degraded = try solve(stale).get()
    #expect(degraded.statusFreshness == .stale)
    #expect(degraded.degraded)
    #expect(degraded.options.map(\.rendezvous) == ["far"])

    // Seven hours past expiry the row says nothing reliable about today.
    stale.expiresAt = now.addingTimeInterval(-7 * 3_600)
    #expect(try solve(stale).get().statusFreshness == .unavailable)
}

/// The owner's rule (21 Nov 2026): when both skiers can get down to the same
/// bottom within their own limits, there is always a meeting point. Two things
/// could empty the list and must not: a higher stop only one of them can reach,
/// and the everyone-can-leave rule at a lift base whose lift has shut.
@Test func bothSkiersReachingTheBaseAlwaysGetAMeetingPoint() throws {
    var m = Mountain()
    let base = m.node("base", .base, lon: -106.00, lat: 40.00, ele: 2_500)
    let top = m.node("top", .liftTop, lon: -106.00, lat: 40.02, ele: 3_100)
    let ledge = m.node("ledge", lon: -106.01, lat: 40.015, ele: 2_900)
    let aStart = m.node("a-start", lon: -106.02, lat: 40.02, ele: 3_000)
    let bStart = m.node("b-start", lon: -105.99, lat: 40.02, ele: 3_000)
    m.lift("chair", base, top, ride: 420, rise: 600)
    m.run("top-down", top, base, length: 1_500, difficulty: .blue, drop: 600)
    // The ledge is a stop the beginner could only reach down a double black.
    m.run("a-chute", aStart, ledge, length: 300, difficulty: .doubleBlack, drop: 100)
    m.run("b-to-ledge", bStart, ledge, length: 500, difficulty: .blue, drop: 100)
    m.run("ledge-down", ledge, base, length: 1_200, difficulty: .blue, drop: 400)
    m.run("a-home", aStart, base, length: 2_500, difficulty: .green, drop: 500)
    m.run("b-home", bStart, base, length: 1_400, difficulty: .blue, drop: 500)
    m.meet(base, .liftBase)
    m.meet(ledge, .junction)
    let bundle = m.bundle()
    let beginner = SkierProfile(
        userID: UUID(), ability: .beginner, maxDifficulty: .green, baselineSpeedMS: [.green: 6]
    )
    let a = skier(beginner, at: aStart), b = skier(profile(), at: bStart)

    // Mid-afternoon with the chair running, and at 22:00 with it shut.
    for at in [Clock.denver(14), Clock.denver(22)] {
        let options = try MeetSolver.solve(input(bundle, a, b, at: at)).get().options
        #expect(options.contains { $0.rendezvous == "base" }, "no meeting point at \(at)")
        #expect(!options.contains { $0.rendezvous == "ledge" })
    }
}
