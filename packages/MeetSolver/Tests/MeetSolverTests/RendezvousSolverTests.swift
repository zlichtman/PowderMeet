import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// Reference scenarios for the rendezvous solver: each test keeps its graph and
// its expected ranking or safety outcome.

@Test func onlyCatalogRendezvousAreEligible() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let junction = m.node("ordinary-junction", lon: -106.02)
    let base = m.node("lift-base", .liftBottom, lon: -106.03)
    m.run("a-short", a, junction, length: 10)
    m.run("b-short", b, junction, length: 10)
    m.run("a-meet", a, base, length: 100)
    m.run("b-meet", b, base, length: 100)
    m.meet(base)

    // The junction is ten times closer for both, but it is not a stopping point.
    let result = try MeetSolver.solve(input(m.bundle(), skier(at: a), skier(at: b))).get()
    #expect(result.options.map(\.rendezvous) == ["lift-base"])
    #expect(result.options[0].routes.0.legs.map(\.edgeID) == ["a-meet"])
}

@Test func reliabilityRankBalancesArrivalFairnessAndUncertainty() {
    let fastButFragile = RendezvousRank(
        latestArrivalS: 99, waitSpreadS: 90, uncertaintyS: 90,
        confidencePenalty: 1, qualityPenalty: 1, stableID: "z"
    )
    let dependable = RendezvousRank(
        latestArrivalS: 100, waitSpreadS: 0, uncertaintyS: 0,
        confidencePenalty: 0, qualityPenalty: 0, stableID: "a"
    )
    #expect(dependable < fastButFragile)
    #expect(abs(dependable.reliabilityScoreS - 100) < 0.001)
    // 99 + 1.5 × 90 wait + 0.5 × 90 uncertainty + 90 confidence + 120 quality.
    #expect(abs(fastButFragile.reliabilityScoreS - 489) < 0.001)

    let lowerQuality = RendezvousRank(
        latestArrivalS: 100, waitSpreadS: 0, uncertaintyS: 10,
        confidencePenalty: 1, qualityPenalty: 1, stableID: "z"
    )
    let higherQuality = RendezvousRank(
        latestArrivalS: 100, waitSpreadS: 0, uncertaintyS: 10,
        confidencePenalty: 0, qualityPenalty: 0, stableID: "a"
    )
    #expect(higherQuality < lowerQuality)
}

private let liftBaseExposure = 1.0, lodgeExposure = 0.15

@Test func weatherAwareWaitPenaltyOnlyIncreasesForHazardousExposure() {
    let clear = Scoring.waitPenaltyAlpha(
        temperatureC: -5, windKmh: 15, visibilityKm: 10, exposure: liftBaseExposure
    )
    let harshBase = Scoring.waitPenaltyAlpha(
        temperatureC: -25, windKmh: 70, visibilityKm: 0.25, exposure: liftBaseExposure
    )
    let harshLodge = Scoring.waitPenaltyAlpha(
        temperatureC: -25, windKmh: 70, visibilityKm: 0.25, exposure: lodgeExposure
    )
    #expect(abs(clear - Scoring.waitPenaltyAlpha) < 0.001)
    #expect(harshBase > harshLodge)
    #expect(harshLodge > clear)
    #expect(harshBase <= Scoring.waitPenaltyAlphaMaximum)
}

@Test func weatherAwareWaitCostCanChangeRendezvousChoice() {
    func exposed(_ alpha: Double) -> RendezvousRank {
        RendezvousRank(
            latestArrivalS: 100, waitSpreadS: 50, uncertaintyS: 0, waitPenaltyAlpha: alpha,
            confidencePenalty: 0, qualityPenalty: 0, stableID: "exposed"
        )
    }
    let clearExposed = exposed(Scoring.waitPenaltyAlpha(
        temperatureC: -5, windKmh: 15, visibilityKm: 10, exposure: liftBaseExposure
    ))
    let harshExposed = exposed(Scoring.waitPenaltyAlpha(
        temperatureC: -25, windKmh: 70, visibilityKm: 0.25, exposure: liftBaseExposure
    ))
    // 100 + 1.5 × 50 in clear weather, 100 + 2.45 × 50 in the storm.
    let sheltered = RendezvousRank(
        latestArrivalS: 190, waitSpreadS: 0, uncertaintyS: 0,
        confidencePenalty: 0, qualityPenalty: 0, stableID: "sheltered"
    )
    #expect(clearExposed < sheltered)
    #expect(sheltered < harshExposed)
}

/// Cold and wind make arriving together matter more; the solver's part is the weight it puts on the wait imbalance.
@Test func solverWeighsWaitImbalanceMoreInHarshWeatherAtAnExposedStop() throws {
    var m = Mountain()
    let a = m.node("context-a", lon: -106.00), b = m.node("context-b", lon: -106.01)
    let base = m.node("context-meet", .liftBottom, lon: -106.02)
    m.run("context-a-meet", a, base, length: 100)
    m.run("context-b-meet", b, base, length: 50)
    m.meet(base)
    let bundle = m.bundle()
    let point = try #require(bundle.rendezvous("context-meet"))
    func alpha(_ conditions: Conditions?) -> Double {
        let solve = input(bundle, skier(at: a), skier(at: b), conditions: conditions)
        return CostModel(input: solve, skier: solve.skiers.0)
            .waitPenaltyAlpha(for: point, arrivalOffsetS: 10)
    }
    #expect(alpha(nil) == Scoring.waitPenaltyAlpha)
    // −20 °C and 14 m/s (50.4 km/h after quantization) at a lift base.
    let expected = 1.5 + 0.45 * (12.0 / 17) + 0.35 * (30.4 / 45)
    #expect(abs(alpha(weather(tempC: -20, windKmh: 50)) - expected) < 1e-9)
    let result = try MeetSolver.solve(input(
        bundle, skier(at: a), skier(at: b), conditions: weather(tempC: -20, windKmh: 50)
    )).get()
    #expect(result.options[0].rendezvous == "context-meet")
}

@Test func rendezvousQualityCanBeatAFasterPoorStopWithoutDominatingTravel() {
    func rank(_ latest: Double, confidence: Double = 0, quality: Double = 0, _ id: RendezvousID)
        -> RendezvousRank {
        RendezvousRank(
            latestArrivalS: latest, waitSpreadS: 0, uncertaintyS: 0,
            confidencePenalty: confidence, qualityPenalty: quality, stableID: id
        )
    }
    let poorStop = rank(100, confidence: 0.4, quality: 0.5, "poor")
    #expect(rank(150, "clear") < poorStop)
    #expect(poorStop < rank(300, "far"))
}

@Test func sharedContinuationIsWorthMinutesButNeverDominatesTravelTime() {
    func rank(_ latest: Double, onward: Double, _ id: RendezvousID) -> RendezvousRank {
        RendezvousRank(
            latestArrivalS: latest, waitSpreadS: 0, uncertaintyS: 0,
            onwardCostS: onward, confidencePenalty: 0, qualityPenalty: 0, stableID: id
        )
    }
    // Nothing to ski together costs twelve minutes; a full run from the stop, none.
    let deadEnd = Ranking.onwardCostS(continuation: nil)
    #expect(deadEnd == 12 * 60)
    let terminal = rank(100, onward: deadEnd, "terminal")
    #expect(rank(100 + 11 * 60, onward: 0, "hub") < terminal)
    #expect(terminal < rank(100 + 13 * 60, onward: 0, "far"))
}

@Test func solverPrefersAUsefulSharedContinuationUntilItCostsMuchMoreTime() throws {
    func winner(usefulHubLength: Double) throws -> RendezvousID {
        var m = Mountain()
        let a = m.node("continue-a", lon: -106.00), b = m.node("continue-b", lon: -106.01)
        let token = m.node("token", .liftBottom, lon: -106.02)
        let useful = m.node("useful", .liftBottom, lon: -106.03)
        let tokenEnd = m.node("token-end", lon: -106.04), onward = m.node("onward", lon: -106.05)
        m.run("a-token", a, token, length: 100)
        m.run("b-token", b, token, length: 100)
        m.run("a-useful", a, useful, length: usefulHubLength)
        m.run("b-useful", b, useful, length: usefulHubLength)
        m.run("token-run", token, tokenEnd, length: 80)
        m.run("shared-onward", useful, onward, length: 1_200, drop: 400)
        m.meet(token)
        m.meet(useful)
        return try MeetSolver.solve(input(m.bundle(), skier(at: a), skier(at: b))).get()
            .options[0].rendezvous
    }
    // At 10 m/s: three minutes later to a real shared run is worth it, ten is not.
    #expect(try winner(usefulHubLength: 1_900) == "useful")
    #expect(try winner(usefulHubLength: 6_100) == "token")
}

@Test func deadEndConnectorDoesNotMasqueradeAsUsefulSharedContinuation() throws {
    var m = Mountain()
    let a = m.node("rollout-a", lon: -106.00), b = m.node("rollout-b", lon: -106.01)
    let deadStop = m.node("a-dead-stop", .liftBottom, lon: -106.02)
    let usefulStop = m.node("z-useful-stop", .liftBottom, lon: -106.03)
    let deadEnd = m.node("dead-end", lon: -106.04)
    let runEnd = m.node("shared-run-end", lon: -106.05)
    m.run("a-dead", a, deadStop, length: 100)
    m.run("b-dead", b, deadStop, length: 100)
    m.run("a-useful", a, usefulStop, length: 100)
    m.run("b-useful", b, usefulStop, length: 100)
    m.connection("tiny-dead-connector", deadStop, deadEnd, length: 20)
    m.run("shared-real-run", usefulStop, runEnd, length: 100, name: "Homeward")
    m.meet(deadStop)
    m.meet(usefulStop)

    let best = try MeetSolver.solve(input(m.bundle(), skier(at: a), skier(at: b))).get().options[0]
    #expect(best.rendezvous == "z-useful-stop")
    #expect(best.sharedContinuation?.edgeID == "shared-real-run")
    #expect(best.sharedContinuation?.kind == .ski)
    #expect(best.sharedContinuation?.name == "Homeward")
}

@Test func sharedLiftRequiresMutuallyUsableTerrainBeyondItsTop() throws {
    func solve(hasDownstreamRun: Bool) throws -> MeetOption {
        var m = Mountain()
        let a = m.node("lift-rollout-a", lon: -106.00), b = m.node("lift-rollout-b", lon: -106.01)
        let base = m.node("lift-rollout-base", .liftBottom, lon: -106.02)
        let top = m.node("lift-rollout-top", .liftTop, lon: -106.03)
        let runEnd = m.node("lift-rollout-run-end", lon: -106.04)
        m.run("a-base", a, base, length: 100)
        m.run("b-base", b, base, length: 100)
        m.lift("summit-chair", base, top, ride: 240, name: "Summit Chair")
        if hasDownstreamRun {
            m.run("summit-cruiser", top, runEnd, length: 300, drop: 100, name: "Summit Cruiser")
        }
        m.meet(base)
        return try MeetSolver.solve(input(m.bundle(), skier(at: a), skier(at: b))).get().options[0]
    }
    let useful = try solve(hasDownstreamRun: true)
    #expect(useful.sharedContinuation?.edgeID == "summit-chair")
    #expect(useful.sharedContinuation?.kind == .ride)
    #expect(useful.sharedContinuation?.name == "Summit Chair")
    #expect(try solve(hasDownstreamRun: false).sharedContinuation == nil)
}

/// Two skiers 100 m from each hub, so approach ETAs tie and the stop is chosen on
/// what both can do next. `build` adds the terrain beyond the hubs.
private func hubs(
    _ names: [String], build: (inout Mountain, [Node]) -> Void
) throws -> MeetOption {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let hubNodes = names.enumerated().map { index, name in
        m.node(name, .liftBottom, lon: -106.02 - Double(index) * 0.01)
    }
    for hub in hubNodes {
        m.run("a-\(hub.id)", a, hub, length: 100)
        m.run("b-\(hub.id)", b, hub, length: 100)
        m.meet(hub)
    }
    build(&m, hubNodes)
    return try MeetSolver.solve(input(m.bundle(), skier(at: a), skier(at: b))).get().options[0]
}

@Test func sharedContinuationRecognizesLapReturningToMeetingBase() throws {
    let best = try hubs(["loop-base"]) { m, hub in
        let top = m.node("loop-top", .liftTop, lon: -106.10)
        m.lift("loop-chair", hub[0], top, ride: 300, length: 700, rise: 250, name: "Loop Chair")
        m.run("home-lap", top, hub[0], length: 600, drop: 250, name: "Home Lap")
    }
    #expect(best.sharedContinuation?.edgeID == "loop-chair")
    #expect(best.sharedContinuation?.kind == .ride)
    #expect(best.sharedContinuation?.sharedRunLengthM == 600)
    #expect(best.sharedContinuation?.sharedVerticalDropM == 250)
}

@Test func sharedLiftThroughConnectorStillRequiresDownhillTerrain() throws {
    let best = try hubs(["connector-base"]) { m, hub in
        let top = m.node("connector-top", .liftTop, lon: -106.10)
        let deadEnd = m.node("connector-dead-end", lon: -106.11)
        m.lift("connector-chair", hub[0], top, ride: 240, name: "Connector Chair")
        m.connection("long-dead-connector", top, deadEnd, length: 500, name: "Service Road")
    }
    #expect(best.sharedContinuation == nil)
}

@Test func sharedContinuationChoosesSubstantialRunInsteadOfStableEdgeID() throws {
    let best = try hubs(["choice-base"]) { m, hub in
        let shortEnd = m.node("choice-short-end", lon: -106.10)
        let fullEnd = m.node("choice-full-end", lon: -106.11)
        m.run("a-short-run", hub[0], shortEnd, length: 100, drop: 10, name: "Short Cut")
        m.run("z-full-run", hub[0], fullEnd, length: 800, drop: 300, name: "Full Lap")
    }
    let continuation = try #require(best.sharedContinuation)
    #expect(continuation.edgeID == "z-full-run")
    #expect(continuation.sharedRunLengthM == 800)
    #expect(continuation.sharedVerticalDropM == 300)
    #expect(continuation.jointTerrainFit > 0.9)
    #expect(abs(continuation.quality - SharedLapUtility.score(
        runLengthM: 800, verticalDropM: 300, actionTransitionCount: 0, downhillAccessS: 0,
        jointTerrainFit: continuation.jointTerrainFit
    )) < 0.0001)
}

@Test func rendezvousRankRewardsSubstantialSharedLapOverTokenRun() throws {
    // Equal approach ETAs: a binary "has some run" score would pick a-short-hub
    // by id. The continuous score must prefer the genuinely useful lap.
    let best = try hubs(["a-short-hub", "z-full-hub"]) { m, hub in
        let shortEnd = m.node("lap-short-end", lon: -106.10)
        let fullEnd = m.node("lap-full-end", lon: -106.11)
        m.run("token-run", hub[0], shortEnd, length: 75, drop: 10, name: "Token Run")
        m.run("proper-shared-lap", hub[1], fullEnd, length: 800, drop: 300, name: "Proper Shared Lap")
    }
    #expect(best.rendezvous == "z-full-hub")
    #expect(best.sharedContinuation?.edgeID == "proper-shared-lap")
}

@Test func sharedLapQualityIsInvariantToRunSegmentation() throws {
    // The split corridor is physically longer and must win even though its first
    // stored segment is shorter than the single-edge alternative.
    let best = try hubs(["a-single-hub", "z-split-hub"]) { m, hub in
        let singleEnd = m.node("segment-single-end", lon: -106.10)
        let splitMid = m.node("segment-split-mid", lon: -106.11)
        let splitEnd = m.node("segment-split-end", lon: -106.12)
        m.run("single-cruiser", hub[0], singleEnd, length: 450, drop: 150, name: "Single Cruiser")
        m.run("split-cruiser-1", hub[1], splitMid, length: 300, drop: 100, name: "Split Cruiser")
        m.run("split-cruiser-2", splitMid, splitEnd, length: 300, drop: 100, name: "Split Cruiser")
    }
    #expect(best.rendezvous == "z-split-hub")
    let continuation = try #require(best.sharedContinuation)
    #expect(continuation.edgeID == "split-cruiser-1")
    #expect(continuation.sharedRunLengthM == 600)
    #expect(continuation.sharedVerticalDropM == 200)
    #expect(continuation.sharedRunOptionCount == 1)
    #expect(continuation.jointTerrainFit > 0.9)
    #expect(abs(continuation.quality - SharedLapUtility.score(
        runLengthM: 600, verticalDropM: 200, actionTransitionCount: 0, downhillAccessS: 0,
        jointTerrainFit: continuation.jointTerrainFit
    )) < 0.0001)
}

@Test func sharedLapUtilityPrefersFasterAccessToEquivalentDownhill() throws {
    // The status here has no wait figures, so the slow chair is on hold: same lap, later downhill.
    func solve(_ names: [String]) throws -> MeetOption {
        var m = Mountain()
        let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
        for (index, name) in names.enumerated() {
            let hub = m.node("\(name)-hub", .liftBottom, lon: -106.02 - Double(index) * 0.01)
            let top = m.node("\(name)-top", .liftTop, lon: -106.10 - Double(index) * 0.01)
            let end = m.node("\(name)-end", lon: -106.20 - Double(index) * 0.01)
            m.run("a-\(name)", a, hub, length: 100)
            m.run("b-\(name)", b, hub, length: 100)
            m.lift("\(name)-chair", hub, top, ride: 300, length: 700, rise: 300, group: "lift:\(name)")
            m.run("\(name)-cruiser", top, end, length: 800, drop: 300, name: "Equivalent Cruiser")
            m.meet(hub)
        }
        return try MeetSolver.solve(input(
            m.bundle(), skier(at: a), skier(at: b), status: status(hold: ["lift:a-slow"])
        )).get().options[0]
    }
    let slowOnly = try #require(try solve(["a-slow"]).sharedContinuation)
    let fastOnly = try #require(try solve(["z-fast"]).sharedContinuation)
    let ranked = try solve(["a-slow", "z-fast"])
    #expect(slowOnly.downhillAccessS > fastOnly.downhillAccessS + 10 * 60)
    #expect(slowOnly.quality < fastOnly.quality)
    // Equal approaches and equal runs: without time-to-downhill in the utility,
    // a-slow-hub would win on id alone.
    #expect(ranked.rendezvous == "z-fast-hub")
    #expect(ranked.sharedContinuation?.edgeID == "z-fast-chair")
}

@Test func sharedLapUtilityPrefersTerrainThatFitsBothSkiers() throws {
    // The bundle carries grooming only, so the technical run is ungroomed
    // and both skiers are beginners off-piste (cleared for blue).
    func solve(_ names: [String]) throws -> MeetOption {
        var m = Mountain()
        let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
        for (index, name) in names.enumerated() {
            let hub = m.node("\(name)-hub", .liftBottom, lon: -106.02 - Double(index) * 0.01)
            let end = m.node("\(name)-end", lon: -106.10 - Double(index) * 0.01)
            m.run("a-\(name)", a, hub, length: 100)
            m.run("b-\(name)", b, hub, length: 100)
            m.run("\(name)-descent", hub, end, length: 600, groomed: name == "z-groomed",
                  drop: 200, name: "\(name)-descent")
            m.meet(hub)
        }
        return try MeetSolver.solve(input(
            m.bundle(), skier(profile(.beginner), at: a), skier(profile(.beginner), at: b)
        )).get().options[0]
    }
    let technicalOnly = try #require(try solve(["a-technical"]).sharedContinuation)
    let groomedOnly = try #require(try solve(["z-groomed"]).sharedContinuation)
    let ranked = try solve(["a-technical", "z-groomed"])
    #expect(technicalOnly.jointTerrainFit < groomedOnly.jointTerrainFit)
    #expect(ranked.rendezvous == "z-groomed-hub")
    #expect(ranked.sharedContinuation?.edgeID == "z-groomed-descent")
}

@Test func rendezvousSoftlyPrefersSeveralViableSharedRuns() throws {
    func solve(_ names: [String]) throws -> MeetOption {
        try hubs(names) { m, hub in
            for (index, node) in hub.enumerated() {
                let endA = m.node("end-a-\(index)", lon: -106.10 - Double(index) * 0.01)
                if node.id == "a-single-run-hub" {
                    m.run("single-cruiser", node, endA, length: 600, drop: 200, name: "Single Cruiser")
                } else {
                    let endB = m.node("end-b-\(index)", lon: -106.20)
                    m.run("varied-cruiser", node, endA, length: 600, drop: 200, name: "Varied Cruiser")
                    m.run("varied-glider", node, endB, length: 600, drop: 200, name: "Varied Glider")
                }
            }
        }
    }
    let singleOnly = try #require(try solve(["a-single-run-hub"]).sharedContinuation)
    let variedOnly = try #require(try solve(["z-varied-run-hub"]).sharedContinuation)
    let ranked = try solve(["a-single-run-hub", "z-varied-run-hub"])
    #expect(singleOnly.sharedRunOptionCount == 1)
    #expect(variedOnly.sharedRunOptionCount == 2)
    #expect(variedOnly.quality > singleOnly.quality)
    #expect(ranked.rendezvous == "z-varied-run-hub")
    #expect(ranked.sharedContinuation?.sharedRunOptionCount == 2)
}

private let eightToFour = [OperatingHours(days: Array(1...7), openMinute: 8 * 60, closeMinute: 16 * 60)]

@Test func sharedContinuationAllowsTimeToRegroupBeforeLastChair() throws {
    var m = Mountain()
    let a = m.node("handoff-a", lon: -106.00), b = m.node("handoff-b", lon: -106.01)
    let base = m.node("handoff-base", .liftBottom, lon: -106.02)
    let top = m.node("handoff-top", .liftTop, lon: -106.03)
    let end = m.node("handoff-end", lon: -106.04)
    m.run("handoff-a-base", a, base, length: 10)
    m.run("handoff-b-base", b, base, length: 10)
    m.lift("handoff-chair", base, top, ride: 300, length: 800, rise: 300, hours: eightToFour)
    m.run("handoff-run", top, end, length: 700, drop: 300, name: "Handoff Run")
    m.meet(base)
    let bundle = m.bundle()
    func continuation(at date: Date) throws -> SharedContinuation? {
        try MeetSolver.solve(input(bundle, skier(at: a), skier(at: b), at: date)).get()
            .options[0].sharedContinuation
    }
    // Both arrive within seconds; the 90 s handoff and the modelled queue must
    // still fit before 16:00. (The modelled queue is about 90 s, so the passing
    // case starts at 15:56.)
    #expect(try continuation(at: Clock.denver(15, 56))?.edgeID == "handoff-chair")
    #expect(try continuation(at: Clock.denver(15, 59)) == nil)
}

@Test func uncertainApproachMustReliablyCatchLastChair() throws {
    var m = Mountain()
    let start = m.node("deadline-start", lon: -106.00)
    let base = m.node("deadline-base", .liftBottom, lon: -106.01)
    let top = m.node("deadline-meet", .liftBottom, lon: -106.02)
    m.run("deadline-approach", start, base, length: 2_000)
    // A magic carpet's 15 s queue is the nearest thing to a lift with no queue.
    m.lift("deadline-lift", base, top, ride: 60, type: .magicCarpet, hours: eightToFour)
    m.meet(top)
    let bundle = m.bundle()
    let a = skier(at: start), b = skier(at: start)
    func solve(at date: Date) -> Result<MeetOptions, SolveFailure> {
        MeetSolver.solve(input(bundle, a, b, at: date))
    }
    // The cold-snow-adjusted 2 km approach is about 207 s with a 31 s standard
    // deviation. From 15:56 (15:56:30 floors to it) the mean clears the gate
    // before 16:00 but the P90 arrival does not, so the chair must not be relied
    // on. Ten minutes earlier the same route is fine.
    let comfortable = try solve(at: Clock.denver(15, 46, 30)).get()
    let route = comfortable.options[0].routes.0
    #expect(route.legs.map(\.edgeID) == ["deadline-approach", "deadline-lift"])
    #expect(solve(at: Clock.denver(15, 56, 30)) == .failure(.liftDeadlineRisk))

    // A route already agreed must not slip past the same gate, stored or live.
    let fragile = input(bundle, a, b, at: Clock.denver(15, 56, 30))
    let begin = RouteProgress.start(route, in: bundle)
    #expect(MeetSolver.recost(route, from: begin, at: Clock.denver(15, 56, 30), in: fragile) == nil)
    #expect(MeetSolver.recost(route, from: begin, at: Clock.denver(15, 46, 30), in: fragile) != nil)
    #expect(MeetSolver.route(for: a, to: "deadline-meet", in: fragile) == .failure(.liftDeadlineRisk))
}

@Test func skierAlreadyOnLiftMayFinishRideAfterLastChair() throws {
    var m = Mountain()
    let base = m.node("aboard-base", .liftBottom, lon: -106.00)
    let mid = m.node("aboard-mid", .liftTop, lon: -106.01)
    m.lift("aboard-lift", base, mid, ride: 120, hours: eightToFour)
    m.meet(mid, .liftTop)
    let bundle = m.bundle()
    let origin = RoutingOrigin.onEdge("aboard-lift", fraction: 0.5, fixAccuracyM: 150)
    let a = skier(at: origin), b = skier(at: origin)
    let solve = input(bundle, a, b, at: Clock.denver(16, 5))
    let route = try MeetSolver.solve(solve).get().options[0].routes.0
    #expect(route.legs.map(\.edgeID) == ["aboard-lift"])
    #expect(abs(route.eta.meanS - 60) < 0.001)
    #expect(abs(route.legs[0].startFraction - 0.5) < 0.001)
    #expect(route.liftCount == 1)

    let live = try #require(MeetSolver.recost(
        route, from: RouteProgress.start(route, in: bundle), at: Clock.denver(16, 5), in: solve
    ))
    #expect(abs(live.meanS - 60) < 0.001)
}

/// One physical lift stored as two edges (`w123:0`, `w123:1`), solved two minutes
/// before last chair. `upperGroup` lets a test close only the second segment.
private func splitLift(
    fasterWrongLift: Bool = false, upperGroup: String = "lift:same"
) -> (bundle: ResortBundle, base: Node) {
    var m = Mountain()
    let base = m.node("split-base", .liftBottom, lon: -106.00)
    let mid = m.node("split-mid", .liftTop, lon: -106.01)
    let top = m.node("split-top", .liftTop, lon: -106.02)
    m.lift("w123:0", base, mid, ride: 180, hours: eightToFour, group: "lift:same", name: "Same Lift")
    m.lift("w123:1", mid, top, ride: 180, hours: eightToFour, group: upperGroup, name: "Same Lift")
    if fasterWrongLift {
        m.lift("w999:0", base, mid, ride: 60, hours: eightToFour, group: "lift:same", name: "Same Lift")
    }
    m.meet(top, .liftTop)
    return (m.bundle(), base)
}

private let splitLiftPath: [EdgeID] = ["w123:0", "w123:1"]

@Test func splitLiftFinishesAfterLastChairAcrossSolveStoredAndLivePaths() throws {
    let (bundle, base) = splitLift()
    let a = skier(at: base), b = skier(at: base)
    let solve = input(bundle, a, b, at: Clock.denver(15, 58))
    let model = CostModel(input: solve, skier: a)
    // The first boarding pays its queue once; the continuation adds exactly its
    // 180 s ride, with no second queue and no closing gate.
    let first = try #require(bundle.graph.edge("w123:0"))
    let expected = try #require(model.traverseTime(first)) + 180
    #expect(expected > 180 + 180 + 60)

    let best = try MeetSolver.solve(solve).get().options[0]
    #expect(best.rendezvous == "split-top")
    #expect(best.routes.0.legs.map(\.edgeID) == splitLiftPath)
    #expect(best.routes.1.legs.map(\.edgeID) == splitLiftPath)
    #expect(abs(best.routes.0.eta.meanS - expected) < 0.001)
    #expect(best.routes.0.liftCount == 1)

    let route = best.routes.0
    let live = try #require(MeetSolver.recost(
        route, from: RouteProgress.start(route, in: bundle), at: Clock.denver(15, 58), in: solve
    ))
    #expect(abs(live.meanS - expected) < 0.001)
    #expect(live.sdS > 0)

    let maneuvers = MeetSolver.maneuvers(for: route, in: bundle)
    #expect(maneuvers.map(\.action) == [.ride])
    #expect(maneuvers[0].edgeIDs == splitLiftPath)
    #expect(abs(maneuvers[0].exitS - maneuvers[0].enterS - expected) < 0.001)
}

@Test func fasterSameNamedDifferentLiftCannotDominateAlreadyBoardedState() throws {
    let (bundle, base) = splitLift(fasterWrongLift: true)
    let best = try MeetSolver.solve(
        input(bundle, skier(at: base), skier(at: base), at: Clock.denver(15, 58))
    ).get().options[0]
    #expect(best.routes.0.legs.map(\.edgeID) == splitLiftPath)
    #expect(best.routes.1.legs.map(\.edgeID) == splitLiftPath)
}

@Test func splitLiftBoundaryDoesNotBecomeANewBoardingAfterClose() throws {
    let (bundle, base) = splitLift()
    let a = skier(at: base)
    let solve = input(bundle, a, skier(at: base), at: Clock.denver(15, 58))
    let route = try MeetSolver.solve(solve).get().options[0].routes.0
    // Three minutes past close, at the boundary between the two stored segments.
    var atBoundary = RouteProgress.start(route, in: bundle)
    atBoundary.legIndex = 1
    let live = try #require(MeetSolver.recost(route, from: atBoundary, at: Clock.denver(16, 3), in: solve))
    #expect(abs(live.meanS - 180) < 0.001)

    // Without ride evidence nobody boards either segment after close.
    let late = CostModel(input: solve, skier: a, at: Clock.denver(16, 3))
    #expect(late.traverseTime(try #require(bundle.graph.edge("w123:1"))) == nil)
    #expect(late.traverseTime(try #require(bundle.graph.edge("w123:0"))) == nil)
}

@Test func continuationDoesNotBypassAnExplicitLiftClosure() throws {
    let (bundle, base) = splitLift(upperGroup: "lift:upper")
    let a = skier(at: base)
    let open = input(bundle, a, skier(at: base), at: Clock.denver(15, 58))
    let route = try MeetSolver.solve(open).get().options[0].routes.0
    #expect(route.legs.map(\.edgeID) == splitLiftPath)

    let closed = input(
        bundle, a, skier(at: base), at: Clock.denver(15, 58),
        status: status(closed: ["lift:upper"], at: Clock.denver(15, 58))
    )
    var halfway = RouteProgress.start(route, in: bundle)
    #expect(MeetSolver.recost(route, from: halfway, at: Clock.denver(15, 58), in: closed) == nil)
    halfway.fractionAlongLeg = 0.5
    #expect(MeetSolver.recost(route, from: halfway, at: Clock.denver(15, 58), in: closed) == nil)
    #expect(MeetSolver.solve(closed) == .failure(.noRendezvousReachable(a.id)))
}

@Test func liftContinuationRequiresExactConsecutiveSourceSegmentsNotNames() throws {
    let (bundle, _) = splitLift()
    let first = try #require(bundle.graph.edge("w123:0"))
    let second = try #require(bundle.graph.edge("w123:1"))
    func changed(id: String? = nil, from: String? = nil) -> Edge {
        var edge = second
        if let id { edge.id = EdgeID(id) }
        if let from { edge.from = NodeID(from) }
        return edge
    }
    #expect(LiftRideContinuation.isContinuation(from: first, to: second))
    #expect(!LiftRideContinuation.isContinuation(from: nil, to: second))
    #expect(!LiftRideContinuation.isContinuation(from: first, to: changed(id: "w999:1")))
    #expect(!LiftRideContinuation.isContinuation(from: first, to: changed(id: "w123:2")))
    #expect(!LiftRideContinuation.isContinuation(from: first, to: changed(from: "unconnected")))
    for invalid in ["same-lift-1", "w123:01", "w123:+1", "w123:1:extra", "w123:999999999999999999999"] {
        #expect(!LiftRideContinuation.isContinuation(from: first, to: changed(id: invalid)))
    }
}

@Test func closedApproachMakesRendezvousIneligible() {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let safe = m.node("safe", lon: -106.015)
    let base = m.node("meet", .liftBottom, lon: -106.02)
    m.run("a-meet", a, base, length: 100)
    m.run("b-meet-closed", b, base, length: 100, group: "trail:closed")
    m.run("b-safe-exit", b, safe, length: 100)
    m.meet(base)
    let bundle = m.bundle()
    let skierA = skier(at: a), skierB = skier(at: b)
    // The edge is still in the graph; the closure is a cost (I-18).
    #expect(bundle.graph.outgoing(from: b.id).map(\.id) == ["b-meet-closed", "b-safe-exit"])
    #expect(MeetSolver.solve(input(bundle, skierA, skierB, status: status(closed: ["trail:closed"])))
        == .failure(.noRendezvousReachable(skierB.id)))
    #expect((try? MeetSolver.solve(input(bundle, skierA, skierB)).get()) != nil)
}

@Test func skierAlreadyAtTerminalRendezvousCanWaitWithoutOutgoingRoute() throws {
    var m = Mountain()
    let waiting = m.node("waiting", .liftBottom, lon: -106.00)
    let approaching = m.node("approaching", lon: -106.01)
    m.run("approach", approaching, waiting, length: 100)
    m.meet(waiting)
    let best = try MeetSolver.solve(
        input(m.bundle(), skier(at: waiting), skier(at: approaching))
    ).get().options[0]
    #expect(best.rendezvous == "waiting")
    #expect(best.routes.0.legs.isEmpty)
    #expect(best.routes.0.eta.meanS == 0)
    #expect(best.routes.1.legs.map(\.edgeID) == ["approach"])
}

@Test func abilityGateGivesTheEasiestWayDownOnlyToTheSkierWhoNeedsIt() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let safe = m.node("safe", lon: -106.015)
    let base = m.node("meet", .liftBottom, lon: -106.02)
    m.run("a-meet", a, base, length: 100)
    m.run("b-too-hard", b, base, length: 100, difficulty: .doubleBlack)
    m.run("b-safe", b, safe, length: 100, difficulty: .green)
    m.meet(base)
    let skierA = skier(at: a), skierB = skier(at: b)
    let best = try MeetSolver.solve(input(m.bundle(), skierA, skierB)).get().options[0]
    #expect(best.routes.0.easiestWayDown == nil)
    #expect(best.routes.1.legs.map(\.edgeID) == ["b-too-hard"])
    #expect(best.routes.1.easiestWayDown?.hardest == .doubleBlack)
    #expect(best.reasons.contains(.easiestWayDownFor(skierB.id)))
    #expect(!best.reasons.contains(.easiestWayDownFor(skierA.id)))
}

@Test func relaxedOrdinaryJunctionDoesNotMasqueradeAsCapabilityRoute() {
    var m = Mountain()
    let a = m.node("junction-a", lon: -106.00), b = m.node("junction-b", lon: -106.01)
    let safe = m.node("junction-safe", lon: -106.015)
    let ordinary = m.node("ordinary", lon: -106.02)
    let isolated = m.node("isolated", lon: -106.03)
    let unreachable = m.node("unreachable-meet", .liftBottom, lon: -106.04)
    m.run("a-too-hard", a, ordinary, length: 100, difficulty: .doubleBlack)
    m.run("a-safe", a, safe, length: 100, difficulty: .green)
    m.run("b-ordinary", b, ordinary, length: 100, difficulty: .green)
    m.run("isolated-meet", isolated, unreachable, length: 100)
    m.meet(unreachable)
    let skierA = skier(at: a)
    // Relaxing ability lets both reach an ordinary junction, which is not a stop.
    #expect(MeetSolver.solve(input(m.bundle(), skierA, skier(at: b)))
        == .failure(.noRendezvousReachable(skierA.id)))
}

@Test func selectionAndAlternatesAreStableAcrossInputOrder() throws {
    let skierA = profile(), skierB = profile()
    var outputs: [[RendezvousID]] = []
    for reverse in [false, true, false, true] {
        var m = Mountain()
        let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
        let r1 = m.node("r1", .liftBottom, lon: -106.02)
        let r2 = m.node("r2", .liftBottom, lon: -106.03)
        let r3 = m.node("r3", .liftTop, lon: -106.04)
        m.run("a-r1", a, r1, length: 100)
        m.run("b-r1", b, r1, length: 100)
        m.run("a-r2", a, r2, length: 100)
        m.run("b-r2", b, r2, length: 100)
        m.run("a-r3", a, r3, length: 110)
        m.run("b-r3", b, r3, length: 110)
        m.meet(r3, .liftTop)
        m.meet(r2)
        m.meet(r1)
        if reverse {
            m.nodes.reverse()
            m.edges.reverse()
            m.points.reverse()
        }
        let result = try MeetSolver.solve(
            input(m.bundle(), skier(skierA, at: a), skier(skierB, at: b))
        ).get()
        outputs.append(result.options.map(\.rendezvous))
    }
    #expect(outputs.dropFirst().allSatisfy { $0 == outputs[0] })
    #expect(outputs[0].first == "r1")
    #expect(Set(outputs[0]).isSubset(of: ["r1", "r2", "r3"]))
}

@Test func nearbyDuplicateStopsDoNotPadAlternates() throws {
    var m = Mountain()
    let a = m.node("near-a", lon: -106.00), b = m.node("near-b", lon: -106.01)
    for index in 0..<5 {
        let stop = m.node("near-stop-\(index)", .liftBottom, lon: -106.0200 + Double(index) * 0.0001)
        m.run("a-\(stop.id)", a, stop, length: 100)
        m.run("b-\(stop.id)", b, stop, length: 100)
        m.meet(stop)
    }
    let options = try MeetSolver.solve(input(m.bundle(), skier(at: a), skier(at: b))).get().options
    // Five stops within fifty metres are one place: the pick plus one fallback.
    #expect(options.count == 2)
    #expect(options[0].rendezvous != options[1].rendezvous)
}

@Test func cachedSolveChangesWhenLiftStatusChanges() throws {
    // The cache key is the whole input, so a new live wait is a different solve, and a long line moves the route.
    var m = Mountain()
    let start = m.node("queue-start", lon: -106.00)
    let topA = m.node("queue-top-a", lon: -106.01), topB = m.node("queue-top-b", lon: -106.02)
    let base = m.node("queue-meet", .liftBottom, lon: -106.03)
    m.lift("lift-a", start, topA, ride: 60, group: "lift:a")
    m.lift("lift-b", start, topB, ride: 60, group: "lift:b")
    m.run("run-a", topA, base, length: 1_000)
    m.run("run-b", topB, base, length: 1_000)
    m.meet(base)
    let bundle = m.bundle()
    let a = skier(at: start), b = skier(at: start)
    let cache = SolveCache(capacity: 4)
    var solves = 0
    func firstLeg(slow: String) throws -> EdgeID? {
        let solve = input(bundle, a, b, status: status(waits: [slow: 20]))
        return try cache.value(for: solve) {
            solves += 1
            return MeetSolver.solve(solve)
        }.get().options[0].routes.0.legs.first?.edgeID
    }
    #expect(try firstLeg(slow: "lift:b") == "lift-a")
    #expect(try firstLeg(slow: "lift:a") == "lift-b")
    #expect(try firstLeg(slow: "lift:b") == "lift-a")
    #expect(solves == 2)
}

// The next five scenarios make one approach "fragile". The pace model carries
// no per-edge speed variance, so the fragile
// approach is a lift (30 % time variance, 15 s magic-carpet queue) and the
// dependable one a run (15 %) or connector (10 %). Expected choices are the
// reference ones.

private let still = weather(tempC: 0)   // no cold-snow slowdown: 10 m/s is 10 m/s

@Test func solverPrefersDependableMeetOverNominallyFasterFragileMeet() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let fragile = m.node("fragile", .liftBottom, lon: -106.02)
    let dependable = m.node("dependable", .liftBottom, lon: -106.03)
    m.lift("w1:0", a, fragile, ride: 75, type: .magicCarpet)       // 90 s ± 27
    m.lift("w2:0", b, fragile, ride: 75, type: .magicCarpet)
    m.connection("a-dependable", a, dependable, length: 150)       // 100 s ± 10
    m.connection("b-dependable", b, dependable, length: 150)
    m.meet(fragile)
    m.meet(dependable)
    let options = try MeetSolver.solve(
        input(m.bundle(), skier(at: a), skier(at: b), conditions: still)
    ).get().options
    #expect(options[0].rendezvous == "dependable")
    #expect(options[0].routes.0.eta.meanS > 90)
    let alternate = try #require(options.dropFirst().first)
    #expect(alternate.rendezvous == "fragile")
    #expect(alternate.routes.0.eta.sdS > options[0].routes.0.eta.sdS)
}

@Test func routeToSameMeetPreservesSlowerDependableAlternative() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let fragileMid = m.node("fragile-mid", lon: -106.02)
    let dependableMid = m.node("dependable-mid", lon: -106.03)
    let base = m.node("meet", .liftBottom, lon: -106.04)
    m.lift("w1:0", a, fragileMid, ride: 30, type: .magicCarpet)    // 45 s ± 13.5
    m.lift("w2:0", fragileMid, base, ride: 30, type: .magicCarpet) // 45 s ± 13.5
    m.run("dependable-1", a, dependableMid, length: 500)           // 50 s ± 7.5
    m.run("dependable-2", dependableMid, base, length: 500)
    m.run("b-meet", b, base, length: 1_000)
    m.meet(base)
    // B needs 100 s whatever A does, so A's ten faster seconds buy nothing and
    // the steadier approach makes the group arrival more dependable.
    let route = try MeetSolver.solve(
        input(m.bundle(), skier(at: a), skier(at: b), conditions: still)
    ).get().options[0].routes.0
    #expect(route.legs.map(\.edgeID) == ["dependable-1", "dependable-2"])
    #expect(abs(route.eta.meanS - 100) < 0.001)
    #expect(route.eta.sdS < 15)
}

@Test func fairnessNeverSendsFasterSkierOnADetourToConsumeWaitTime() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let fastMid = m.node("fast-mid", lon: -106.02)
    let alignedMid = m.node("aligned-mid", lon: -106.03)
    let base = m.node("meet", .liftBottom, lon: -106.04)
    m.lift("w1:0", a, fastMid, ride: 15, type: .magicCarpet)       // 30 s
    m.lift("w2:0", fastMid, base, ride: 15, type: .magicCarpet)    // 30 s
    m.run("aligned-1", a, alignedMid, length: 500)
    m.run("aligned-2", alignedMid, base, length: 500)
    m.run("b-meet", b, base, length: 1_000)
    m.meet(base)
    // The 100 s approach would line A up with B exactly, and is steadier, but it
    // is 40 s slower than A's fastest. Fairness picks stops, not detours (I-02).
    let best = try MeetSolver.solve(
        input(m.bundle(), skier(at: a), skier(at: b), conditions: still)
    ).get().options[0]
    #expect(best.routes.0.legs.map(\.edgeID) == ["w1:0", "w2:0"])
    #expect(best.routes.1.legs.map(\.edgeID) == ["b-meet"])
    #expect(abs(best.routes.0.eta.meanS - 60) < 0.001)
    #expect(abs(best.routes.1.eta.meanS - 100) < 0.001)
    #expect(abs(best.expectedWaitS - 40) < 0.001)
}

@Test func meetSolveSelectsApproachPathsByJointReliability() throws {
    var m = Mountain()
    let a = m.node("joint-a", lon: -106.00), b = m.node("joint-b", lon: -106.01)
    let fragileMid = m.node("joint-fragile-mid", .liftTop, lon: -106.02)
    let dependableMid = m.node("joint-dependable-mid", lon: -106.03)
    let base = m.node("joint-meet", .liftBottom, lon: -106.04)
    // One lift in two segments: 15 s queue + 37.5 s, then 37.5 s. 90 s ± 27.
    m.lift("w500:0", a, fragileMid, ride: 37.5, type: .magicCarpet, group: "lift:joint")
    m.lift("w500:1", fragileMid, base, ride: 37.5, type: .magicCarpet, group: "lift:joint")
    // One connector in two segments: 97 s ± 9.7.
    m.connection("joint-dependable-1", a, dependableMid, length: 72.75, name: "Cat Track")
    m.connection("joint-dependable-2", dependableMid, base, length: 72.75, name: "Cat Track")
    m.lift("w600:0", b, base, ride: 70, type: .magicCarpet)        // 85 s ± 25.5
    m.meet(base)
    let bundle = m.bundle()
    let skierA = skier(at: a), skierB = skier(at: b)
    let solve = input(bundle, skierA, skierB, conditions: still)

    // Alone, A's steadier 97 s approach scores better than the 90 s lift…
    let search = Search.run(
        from: try #require(ResolvedOrigin(skierA.origin, graph: bundle.graph)),
        model: CostModel(input: solve, skier: skierA), maxLabels: 8
    )
    #expect(search.best(at: base.id)?.via == "joint-dependable-2")

    // …but B's much larger uncertainty dominates the pair, so seven more mean
    // seconds for A barely narrow the group range. The pair keeps the faster one.
    let best = try MeetSolver.solve(solve).get().options[0]
    #expect(best.routes.0.legs.map(\.edgeID) == ["w500:0", "w500:1"])
    #expect(abs(best.routes.0.eta.meanS - 90) < 0.001)
    #expect(abs(best.routes.1.eta.meanS - 85) < 0.001)
}

@Test func frontierCapPreservesFastestApproachForTheDetourLimit() throws {
    for reversed in [false, true] {
        var m = Mountain()
        let a = m.node("cap-a", lon: -106.00), b = m.node("cap-b", lon: -106.01)
        let base = m.node("cap-meet", .liftBottom, lon: -106.02)
        // Fast but fiddly: five separate 40 s lifts. 200 s, and the worst
        // reliability score at the meet once four transitions are priced in.
        var previous = a
        for index in 1...5 {
            let next = index == 5 ? base : m.node("cap-hop-\(index)", .liftTop, lon: -106.10 - Double(index) * 0.01)
            m.lift("w\(index):0", previous, next, ride: 25, type: .magicCarpet)
            previous = next
        }
        // Eight steady single-edge approaches, every one more than 30 s slower.
        for index in 0..<8 {
            m.connection("slow-stable-\(index)", a, base, length: 346.5 + Double(index) * 0.5)
        }
        m.run("partner", b, base, length: 1_000)
        m.meet(base)
        if reversed { m.edges.reverse() }
        let best = try MeetSolver.solve(
            input(m.bundle(), skier(at: a), skier(at: b), conditions: still)
        ).get().options[0]
        // Trimming the frontier by reliability alone would erase the 200 s
        // baseline and make a 31 s detour look like the fastest legal approach.
        #expect(best.routes.0.legs.map(\.edgeID) == ["w1:0", "w2:0", "w3:0", "w4:0", "w5:0"])
        #expect(abs(best.routes.0.eta.meanS - 200) < 0.001)
        #expect(best.routes.1.legs.map(\.edgeID) == ["partner"])
    }
}

@Test func aLiftIsRiddenDownOnlyWhenTheBundleMarksItTwoWay() throws {
    // Seen at Whistler: a route rode Peak Express down. A chair carries skiers
    // up unless the bundle says it also downloads (`one_way: false`).
    func legs(twoWay: Bool) throws -> [EdgeID] {
        var m = Mountain()
        let base = m.node("base", .liftBottom, lon: -106.00, ele: 2_000)
        let top = m.node("top", .liftTop, lon: -106.01, ele: 2_400)
        m.lift("chair", base, top, ride: 240, rise: 400, twoWay: twoWay)
        m.run("long-way-down", top, base, length: 9_000, drop: 400)
        m.meet(base)
        let options = try MeetSolver.solve(input(m.bundle(), skier(at: top), skier(at: base))).get()
        return try #require(options.options.first).routes.0.legs.map(\.edgeID)
    }
    #expect(try legs(twoWay: false) == ["long-way-down"])
    #expect(try legs(twoWay: true) == ["chair~rev"])
}
