import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// The ranking rules (specs/06-SOLVER.md section 3): everyone can leave, the
// run after the meet counts, standing idle costs more than travelling, a lap in
// the wait counts as skiing, a lodge stays on the list.

@Test func everySkierMustBeAbleToLeaveTheStopWithinTheirOwnLimits() throws {
    // A stop both can reach on blue runs, but whose only way on is black. Being
    // a lodge does not excuse it: a blue skier would be stranded there.
    for kind in [RendezvousKind.liftBase, .lodge] {
        func solve(withEasyStop: Bool) throws -> (MeetOptions, blue: UUID, expert: UUID) {
            var m = Mountain()
            let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
            let steep = m.node("steep-stop", .liftBottom, lon: -106.02)
            let steepEnd = m.node("steep-end", lon: -106.03)
            m.run("a-steep", a, steep, length: 100)
            m.run("b-steep", b, steep, length: 100)
            m.run("black-out", steep, steepEnd, length: 800, difficulty: .black, drop: 300)
            m.meet(steep, kind)
            if withEasyStop {
                let easy = m.node("easy-stop", .liftBottom, lon: -106.04)
                let easyEnd = m.node("easy-end", lon: -106.05)
                m.run("a-easy", a, easy, length: 900)
                m.run("b-easy", b, easy, length: 900)
                m.run("blue-out", easy, easyEnd, length: 300, drop: 60)
                m.meet(easy)
            }
            let blue = skier(at: a), expert = skier(profile(.expert), at: b)
            return (try MeetSolver.solve(input(m.bundle(), blue, expert)).get(), blue.id, expert.id)
        }
        // Far closer and with the better run, but only one of them can ski it.
        let (ruled, _, _) = try solve(withEasyStop: true)
        #expect(ruled.options.map(\.rendezvous) == ["easy-stop"])
        #expect(ruled.options[0].reasons.contains(.skiOnTogether(run: nil)))

        // With nowhere else to meet the solve still answers, and says who is stuck.
        let (fallback, blue, expert) = try solve(withEasyStop: false)
        #expect(fallback.options.map(\.rendezvous) == ["steep-stop"])
        #expect(fallback.options[0].reasons.contains(.noOnwardRouteFor(blue)))
        #expect(!fallback.options[0].reasons.contains(.noOnwardRouteFor(expert)))
    }
}

@Test func aLiftThatStrandsTheSkierAtItsTopIsNotAWayOn() throws {
    var m = Mountain()
    let base = m.node("base", .liftBottom, lon: -106.00)
    let top = m.node("top", .liftTop, lon: -106.01)
    let end = m.node("end", lon: -106.02)
    m.lift("chair", base, top, ride: 300)
    m.run("black-only", top, end, length: 600, difficulty: .black, drop: 250)
    let bundle = m.bundle()
    func move(_ skier: SkierInput) -> Ranking.OnwardMove {
        Ranking.onwardMove(
            from: base.id, model: CostModel(input: input(bundle, skier, skier), skier: skier),
            offsetS: 0
        )
    }
    #expect(move(skier(profile(.expert), at: base)) == .open)
    #expect(move(skier(at: base)) == .beyondAbility)
}

@Test func aFriendAlreadyAtAStopDoesNotMakeItTheMeetingPoint() throws {
    var m = Mountain()
    let waiting = m.node("where-b-stands", .liftBottom, lon: -106.00)
    let a = m.node("a", lon: -106.03)
    let between = m.node("between", .liftBottom, lon: -106.015)
    for (stop, name) in [(waiting, "one"), (between, "two")] {
        let end = m.node("end-\(name)", lon: -106.10)
        m.run("lap-\(name)", stop, end, length: 1_200, drop: 400)
        m.meet(stop)
    }
    m.run("a-between", a, between, length: 6_000)
    m.run("b-between", waiting, between, length: 6_000)
    m.run("a-waiting", a, waiting, length: 9_000)
    let skierA = skier(at: a), skierB = skier(at: waiting)
    let options = try MeetSolver.solve(input(m.bundle(), skierA, skierB)).get().options
    // About ten minutes each beats fifteen for one while the other stands still.
    #expect(options.map(\.rendezvous) == ["between", "where-b-stands"])
    #expect(options[0].expectedWaitS < 1)
    #expect(options[1].reasons.contains(.alreadyThere(skierB.id)))
    #expect(options[1].expectedWaitS > options[0].routes.0.eta.meanS)
}

private let nineToFour = [OperatingHours(days: Array(1...7), openMinute: 9 * 60, closeMinute: 16 * 60)]

@Test func aLodgeStaysOnTheListAndWinsWhenStoppingIsThePoint() throws {
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    let lodge = m.node("lodge", lon: -106.05)
    m.run("a-lodge", a, lodge, length: 400)
    m.run("b-lodge", b, lodge, length: 400)
    m.meet(lodge, .lodge, amenities: ["indoor"])
    // Two lift bases, each with its own lap, both nearer than the lodge.
    for (index, name) in ["near", "next"].enumerated() {
        let hub = m.node("\(name)-hub", .liftBottom, lon: -106.10 - Double(index) * 0.05)
        let top = m.node("\(name)-top", .liftTop, lon: -106.11 - Double(index) * 0.05)
        m.run("a-\(name)", a, hub, length: 100 + Double(index) * 50)
        m.run("b-\(name)", b, hub, length: 100 + Double(index) * 50)
        m.lift("\(name)-chair", hub, top, ride: 240, hours: nineToFour)
        m.run("\(name)-lap", top, hub, length: 1_200, drop: 400)
        m.meet(hub)
    }
    let bundle = m.bundle()
    func solve(at date: Date, _ conditions: Conditions? = nil) throws -> [MeetOption] {
        try MeetSolver.solve(input(
            bundle, skier(at: a), skier(at: b), at: date, conditions: conditions,
            options: SolveOptions(maxOptions: 2)
        )).get().options
    }

    // Mid-day: skiing wins, and the lodge takes the last place from the second hub.
    let midday = try solve(at: Clock.denver(12))
    #expect(midday.map(\.rendezvous) == ["near-hub", "lodge"])
    #expect(midday[1].reasons.contains(.lodgeAlternative))
    #expect(!midday[0].reasons.contains(.lodgeAlternative))

    // Ten minutes before last chair, and in a storm, the lodge is the pick.
    #expect(try solve(at: Clock.denver(15, 50)).first?.rendezvous == "lodge")
    let storm = weather(at: Clock.denver(12), tempC: -25, windKmh: 70, visibilityKm: 0.5)
    #expect(try solve(at: Clock.denver(12), storm).first?.rendezvous == "lodge")
}

@Test func theKeptLodgeIsNeverInAnAreaAlreadyOnTheList() throws {
    // Seen at Whistler: the kept lodge shared the pick's node, as Garibaldi Lift
    // Company shares the Village Gondola base. That is the same place twice.
    var m = Mountain()
    let a = m.node("a", lon: -106.00), b = m.node("b", lon: -106.01)
    for (index, name) in ["hub", "next"].enumerated() {
        let hub = m.node(name, .liftBottom, lon: -106.10 - Double(index) * 0.05)
        let top = m.node("\(name)-top", .liftTop, lon: -106.11 - Double(index) * 0.05)
        m.run("a-\(name)", a, hub, length: 100 + Double(index) * 50)
        m.run("b-\(name)", b, hub, length: 100 + Double(index) * 50)
        m.lift("\(name)-chair", hub, top, ride: 240)
        m.run("\(name)-lap", top, hub, length: 1_200, drop: 400)
        m.meet(hub)
        if index == 0 {
            m.points.append(Rendezvous(
                id: "hub-lodge", nodeID: hub.id, kind: .lodge, name: "hub-lodge",
                confidence: 1, quality: 1, amenities: ["indoor"]
            ))
        }
    }
    func solve(_ mountain: Mountain) throws -> [MeetOption] {
        try MeetSolver.solve(input(
            mountain.bundle(), skier(at: a), skier(at: b), options: SolveOptions(maxOptions: 2)
        )).get().options
    }
    // The only lodge is on the pick's node: none is added.
    #expect(try solve(m).map(\.rendezvous) == ["hub", "next"])

    // A lodge somewhere else takes the last place instead.
    var withLodge = m
    let lodge = withLodge.node("lodge", lon: -106.05)
    withLodge.run("a-lodge", a, lodge, length: 400)
    withLodge.run("b-lodge", b, lodge, length: 400)
    withLodge.meet(lodge, .lodge, amenities: ["indoor"])
    let options = try solve(withLodge)
    #expect(options.map(\.rendezvous) == ["hub", "lodge"])
    #expect(options[1].reasons.contains(.lodgeAlternative))
}

@Test func theSkierWhoWouldWaitIsOfferedALapThatGetsThemBackInTime() throws {
    var m = Mountain()
    let base = m.node("base", .liftBottom, lon: -106.00)
    let top = m.node("top", .liftTop, lon: -106.01)
    let far = m.node("far", lon: -106.05)
    m.lift("chair", base, top, ride: 240)
    m.run("lap-run", top, base, length: 1_500, drop: 300, name: "Lap Run")
    m.meet(base)
    func solve(partnerDistance: Double) throws -> (MeetOption, SkierInput) {
        var mountain = m
        mountain.run("long-way-in", far, base, length: partnerDistance)
        let waiting = skier(at: base), coming = skier(at: far)
        let option = try MeetSolver.solve(input(mountain.bundle(), waiting, coming)).get().options[0]
        return (option, waiting)
    }

    // Twenty minutes to fill: one lap of about eight fits with a minute to spare.
    let (option, waiting) = try solve(partnerDistance: 12_000)
    let lap = try #require(option.lapWhileWaiting)
    #expect(lap.skierID == waiting.id)
    #expect(lap.legs.map(\.edgeID) == ["chair", "lap-run"])
    #expect(lap.legs.first?.enterS == option.routes.0.eta.meanS)
    #expect(lap.eta.meanS <= option.routes.1.eta.meanS - Scoring.waitLapReturnMarginS)
    #expect(option.reasons.contains(.lapWhileWaitingFor(waiting.id)))
    // It is the only stop, so the pick also says the wait could not be avoided.
    #expect(option.reasons.contains(.longWaitUnavoidable(waiting.id)))
    // The meet itself is untouched: same stop, the waiting skier's route still empty.
    #expect(option.rendezvous == "base")
    #expect(option.routes.0.legs.isEmpty)

    // Four minutes is not a wait worth a lap, and a lap that would make the
    // partner wait is never offered.
    #expect(try solve(partnerDistance: 2_400).0.lapWhileWaiting == nil)
    #expect(try solve(partnerDistance: 4_000).0.lapWhileWaiting == nil)
}

/// The gap between arrivals less the lap the earlier skier fits into it.
private func idleS(_ option: MeetOption) -> Double {
    option.expectedWaitS - (option.lapWhileWaiting.map { $0.eta.meanS - ($0.legs.first?.enterS ?? 0) } ?? 0)
}

@Test func aLapInTheWaitCountsAsSkiingNotWaiting() throws {
    // B is twenty minutes ahead of A at either stop. At the chair B can lap; at
    // the other stop B can only stand, though A gets there a minute sooner and
    // the run on from it is better.
    var m = Mountain()
    let base = m.node("chair-base", .liftBottom, lon: -106.00)
    let top = m.node("chair-top", .liftTop, lon: -106.01)
    let stand = m.node("standing-stop", .liftBottom, lon: -106.02)
    let standEnd = m.node("standing-end", lon: -106.03)
    let far = m.node("far", lon: -106.10)
    m.lift("chair", base, top, ride: 240)
    m.run("lap-run", top, base, length: 1_500, drop: 300)
    m.run("b-stand", base, stand, length: 100)
    m.run("stand-out", stand, standEnd, length: 1_200, drop: 400)
    m.run("a-chair", far, base, length: 12_000)
    m.run("a-stand", far, stand, length: 11_400)
    m.meet(base)
    m.meet(stand)
    let a = skier(at: far), b = skier(at: base)
    let options = try MeetSolver.solve(input(m.bundle(), a, b)).get().options
    #expect(options.map(\.rendezvous) == ["chair-base", "standing-stop"])
    #expect(options[0].routes.0.eta.meanS > options[1].routes.0.eta.meanS)
    #expect(options[0].lapWhileWaiting?.skierID == b.id)
    #expect(options[1].lapWhileWaiting == nil)
    #expect(idleS(options[0]) < idleS(options[1]) - 5 * 60)

    // The score charges the lap at a third of what standing costs, and the
    // twenty-minute gap past its first five at 0.5 either way.
    func rank(lap: Double) -> Double {
        RendezvousRank(
            latestArrivalS: 1_200, waitSpreadS: 1_200, lapS: lap, uncertaintyS: 0,
            confidencePenalty: 0, qualityPenalty: 0, stableID: "x"
        ).reliabilityScoreS
    }
    #expect(rank(lap: 0) == 1_200 + 1.5 * 1_200 + 0.5 * 900)
    #expect(rank(lap: 900) == 1_200 + 1.5 * 300 + 0.5 * 900 + 0.5 * 900)
}

@Test func anEvenMeetOutranksASlightlyFasterOneWhereOneSkierLapsAloneForTwentyMinutes() {
    // The friend already stands at a lift base with a full run from it; you get
    // there in 24 minutes and they lap meanwhile. The other stop has you both
    // arriving within two minutes, a minute later, but with no shared run on.
    let lopsided = RendezvousRank(
        latestArrivalS: 24 * 60, waitSpreadS: 24 * 60,
        lapS: RendezvousRank.longestPossibleLapS(waitSpreadS: 24 * 60), uncertaintyS: 0,
        confidencePenalty: 0, qualityPenalty: 0, stableID: "lopsided"
    )
    let even = RendezvousRank(
        latestArrivalS: 25 * 60, waitSpreadS: 2 * 60, uncertaintyS: 0,
        onwardCostS: Scoring.onwardMaximumS, confidencePenalty: 0, qualityPenalty: 0, stableID: "even"
    )
    // Before the uneven-wait term the lap made the long gap cheap enough that
    // the lopsided stop won by about three minutes.
    #expect(lopsided.reliabilityScoreS - 0.5 * (24 * 60 - 5 * 60) < even.reliabilityScoreS)
    #expect(even < lopsided)
}

// A playtest on the real Whistler graph with the demo's positions gave one skier
// about a minute of travel and the other about 26.

@Test func whistlerMidDayPicksAreBalancedWhenABalancedStopExists() throws {
    let bundle = try Whistler.bundle()
    // (A, B): the demo skier with each demo friend, then pairs both high, both
    // low and one each side of the valley; in clear weather, then in the demo's
    // (−6 °C, 12 cm of new snow), which slows every run.
    let pairs = [
        ("7th Heaven Express top", "Beavertails"),
        ("7th Heaven Express top", "Whistler Village Gondola Upper top"),
        ("Peak Express top", "Symphony Express top"),
        ("Dusty's", "Black's Pub"),
        ("Raven's", "Glacier Creek"),
    ]
    let at = Whistler.time(11)
    let snow = weather(at: at, tempC: -6, windKmh: 14, visibilityKm: 9, snowCM: 12)
    for conditions in [nil, snow] {
        for (placeA, placeB) in pairs {
            let a = try Whistler.skier(at: placeA, in: bundle)
            let b = try Whistler.skier(at: placeB, in: bundle)
            let options = try MeetSolver.solve(
                input(bundle, a, b, at: at, conditions: conditions)
            ).get().options
            let pick = try #require(options.first)
            let pair: Comment = "\(placeA) + \(placeB)"
            // Both travel and neither stands long: the pick never needs the
            // "uneven" label, and a lodge is still on the list.
            #expect(!pick.routes.0.legs.isEmpty && !pick.routes.1.legs.isEmpty, pair)
            #expect(pick.expectedWaitS < 7 * 60, pair)
            #expect(!pick.reasons.contains { if case .longWaitUnavoidable = $0 { true } else { false } }, pair)
            #expect(!pick.reasons.contains(.noLiftsRunning), pair)
            #expect(options.contains { bundle.rendezvous($0.rendezvous)?.kind == .lodge }, pair)
        }
    }

    // The demo pair exactly, in the demo's weather. Sam's own lodge (Sam 0
    // minutes, you 26) is offered with a lap that fills most of Sam's wait, but
    // it is not the pick: a stop each reaches in about twenty minutes is.
    let me = try Whistler.skier(at: "7th Heaven Express top", in: bundle)
    let sam = try Whistler.skier(at: "Beavertails", in: bundle)
    let options = try MeetSolver.solve(input(bundle, me, sam, at: at, conditions: snow)).get().options
    #expect(options[0].expectedWaitS < 2 * 60)
    let lodge = try #require(options.first { bundle.rendezvous($0.rendezvous)?.name == "Beavertails" })
    #expect(options[0].rendezvous != lodge.rendezvous)
    #expect(lodge.reasons.contains(.alreadyThere(sam.id)))
    #expect(lodge.lapWhileWaiting?.skierID == sam.id)
    #expect(idleS(lodge) < lodge.expectedWaitS / 2)
}

@Test func whistlerWithNoLiftsRunningSaysWhyThePickIsUneven() throws {
    // What the playtest hit: the demo solves at the real time, and at night no
    // lift runs, so the friend at the bottom cannot come up and every stop has
    // them waiting. The pick is still the best there is; it has to say so.
    let bundle = try Whistler.bundle()
    let me = try Whistler.skier(at: "7th Heaven Express top", in: bundle)
    let sam = try Whistler.skier(at: "Beavertails", in: bundle)
    let options = try MeetSolver.solve(input(bundle, me, sam, at: Whistler.time(3))).get().options
    let pick = try #require(options.first)
    // The 2026-11-20 fixture ties run ends to lift stations, so Sam now walks
    // about 4 min to the pick and waits about 20; the point is the labels.
    #expect(pick.expectedWaitS > 15 * 60)
    #expect(pick.routes.1.eta.meanS < 5 * 60)
    #expect(pick.reasons.contains(.noLiftsRunning))
    #expect(pick.reasons.contains(.longWaitUnavoidable(sam.id)))
    #expect(options.allSatisfy { $0.reasons.contains(.noLiftsRunning) })
    // Only the pick carries the label.
    #expect(options.dropFirst().allSatisfy { option in
        !option.reasons.contains { if case .longWaitUnavoidable = $0 { true } else { false } }
    })
}

// With gusts strong enough to hold every lift and no live status, a balanced
// stop may not exist: the solver still answers, leans away from lifts, and says
// why on any option that boards one.
@Test func whistlerInAStormStillMeetsWithFewerLiftsAndSaysWhy() throws {
    let bundle = try Whistler.bundle()
    let at = Whistler.time(11)
    // Everything a newer conditions row carries: a gale with stronger gusts, the
    // upper mountain in cloud, and yesterday's thaw refrozen.
    var storm = weather(at: at, tempC: -1, windKmh: 40, visibilityKm: 8, cloudPct: 100, snowCM: 2)
    storm.elevationM = 690
    storm.current.gustMS = 21
    storm.current.windDirDeg = 200
    storm.current.dewPointC = -2
    storm.current.cloudLowPct = 100
    storm.current.temp850C = -5
    storm.current.temp700C = -14
    storm.recent = [RecentConditions(at: at.addingTimeInterval(-20 * 3_600), tempC: 6)]
    let pairs = [
        ("7th Heaven Express top", "Beavertails"),
        ("Peak Express top", "Symphony Express top"),
        ("Dusty's", "Black's Pub"),
    ]
    var calmLifts = 0, stormLifts = 0
    for (placeA, placeB) in pairs {
        let a = try Whistler.skier(at: placeA, in: bundle)
        let b = try Whistler.skier(at: placeB, in: bundle)
        let calm = try #require(try MeetSolver.solve(input(bundle, a, b, at: at)).get().options.first)
        let pick = try #require(
            try MeetSolver.solve(input(bundle, a, b, at: at, conditions: storm)).get().options.first
        )
        calmLifts += calm.routes.0.liftCount + calm.routes.1.liftCount
        stormLifts += pick.routes.0.liftCount + pick.routes.1.liftCount
        for route in [pick.routes.0, pick.routes.1] where route.liftCount > 0 {
            #expect(pick.reasons.contains(.windHoldLikelyFor(route.skierID)), "\(placeA) + \(placeB)")
        }
    }
    #expect(stormLifts <= calmLifts)
}

// A playtest showed three of five options leaving one skier standing for over
// twenty minutes beside a pick that had them together in step: different
// places, the same bad choice. One such stop may be offered (where a friend
// already stands, say), and the lodge; the rest must be real choices.
@Test func whistlerAlternatesAreNotARowOfPlainlyWorseStops() throws {
    let bundle = try Whistler.bundle()
    let at = Whistler.time(11)
    let pairs = [
        ("7th Heaven Express top", "Beavertails"),
        ("7th Heaven Express top", "Whistler Village Gondola Upper top"),
        ("Peak Express top", "Symphony Express top"),
        ("Dusty's", "Black's Pub"),
        ("Raven's", "Glacier Creek"),
    ]
    for (placeA, placeB) in pairs {
        let a = try Whistler.skier(at: placeA, in: bundle)
        let b = try Whistler.skier(at: placeB, in: bundle)
        let options = try MeetSolver.solve(input(bundle, a, b, at: at)).get().options
        let pick = try #require(options.first)
        func together(_ option: MeetOption) -> Double {
            max(option.routes.0.eta.meanS, option.routes.1.eta.meanS)
        }
        let plainlyWorse = options.dropFirst().filter {
            $0.expectedWaitS > pick.expectedWaitS + 5 * 60 && together($0) > together(pick) - 60
                && bundle.rendezvous($0.rendezvous)?.kind != .lodge
        }
        #expect(plainlyWorse.count <= 1, "\(placeA) + \(placeB)")
    }
}

@Test func aPlaceAskedForByNameJoinsTheOptionsLastWithItsOwnRoutes() throws {
    let bundle = try Whistler.bundle()
    let a = try Whistler.skier(at: "7th Heaven Express top", in: bundle)
    let b = try Whistler.skier(at: "Beavertails", in: bundle)
    var request = input(bundle, a, b, at: Whistler.time(11))
    let plain = try MeetSolver.solve(request).get().options
    let offered = Set(plain.map(\.rendezvous))
    // Any stop both can reach that the solver's own list left out.
    request.options.requested = try #require(bundle.rendezvous.first { point in
        guard !offered.contains(point.id) else { return false }
        var probe = request
        probe.options.requested = point.id
        return (try? MeetSolver.solve(probe).get().options.last?.rendezvous) == point.id
    }?.id)
    let asked = try MeetSolver.solve(request).get().options
    #expect(asked.count == plain.count + 1)
    #expect(asked.dropLast().map(\.rendezvous) == plain.map(\.rendezvous))
    let last = try #require(asked.last)
    #expect(last.rendezvous == request.options.requested)
    #expect(last.tradeoff == .yourPick)
    #expect(last.expectedWaitS == abs(last.routes.0.eta.meanS - last.routes.1.eta.meanS))

    // One already on the list stays where it ranks.
    request.options.requested = plain[0].rendezvous
    #expect(try MeetSolver.solve(request).get().options.map(\.rendezvous) == plain.map(\.rendezvous))
}

@Test func clusteredBaseStopsAreThinnedAndTheOtherPlacesFilledFromElsewhere() throws {
    // Seen at Whistler: the list was the village's lift bases one after another.
    // Each base has its own lift, so the lift-zone rule alone keeps them all.
    // `bases` are lon offsets (0.001 is about 85 m here); `others` are stops
    // elsewhere; all are in score order after the pick at 600 s.
    func alternates(
        bases: [Double], links: [Double] = [], others: [(String, Double, Double)] = [], count: Int
    ) throws -> [RendezvousID] {
        var m = Mountain()
        var scores: [(String, Double)] = []
        for (index, offset) in bases.enumerated() {
            let name = "base\(index)"
            let base = m.node(name, .liftBottom, lon: -106.00 - offset, ele: 1_000)
            let top = m.node("\(name)-top", .liftTop, lon: -106.00 - offset, lat: 40.02, ele: 1_500)
            m.lift("\(name)-chair", base, top, ride: 300)
            m.meet(base)
            scores.append((name, 600 + Double(index) * 10))
        }
        for (index, offset) in links.enumerated() {
            let link = m.node("link\(index)", lon: -106.00 - offset, ele: 1_000)
            m.meet(link, .junction)
        }
        for (name, ele, score) in others {
            let stop = m.node(name, lon: -106.00 - score / 10_000, ele: ele)
            m.meet(stop, .junction)
            scores.append((name, score))
        }
        let bundle = m.bundle()
        let ranked = try scores.enumerated().map { index, entry in
            let point = try #require(bundle.rendezvous.first { $0.id == RendezvousID(entry.0) })
            let label = Label(
                id: index, node: point.nodeID, time: entry.1, uncertainty: RouteTimeUncertainty(),
                transitions: 0, previous: nil, via: nil
            )
            return Ranking.Candidate(
                point: point,
                rank: RendezvousRank(
                    latestArrivalS: entry.1, waitSpreadS: 0, uncertaintyS: 0, confidencePenalty: 0,
                    qualityPenalty: 0, stableID: point.id
                ),
                a: label, b: label, continuation: nil, lapKnown: true
            )
        }
        return Ranking.diverseAlternates(
            after: ranked[0], searchA: SearchResult(frontier: [:], labels: []), graph: bundle.graph,
            areas: Ranking.stopAreas(bundle.rendezvous, graph: bundle.graph), count: count,
            candidate: { ranked.indices.contains($0) ? ranked[$0] : nil }
        ).map(\.point.id)
    }

    // Lifts 120 m and 240 m apart are one place: the loosened distance steps no
    // longer list them all, and only the one nearby fallback is left.
    #expect(try alternates(bases: [0, 0.0014, 0.0028], count: 4) == ["base1"])

    // Bases 400 m apart, linked into one area by stops between them. The pick's
    // bound is max(5 min, 25 % of 600 s) = 300 s: the stops at 800 s and 850 s
    // are close enough to take places ahead of the other bases, far (1,000 s) is not.
    let elsewhere = [("high1", 1_800.0, 800.0), ("high2", 2_000, 850), ("far", 1_000, 1_000)]
    let wide = [0, 0.0047, 0.0094], links = [0.00235, 0.00705]
    #expect(try alternates(bases: wide, links: links, others: elsewhere, count: 2) == ["high1", "high2"])
    // A place left over goes back to rank order, which beats a far worse stop.
    #expect(try alternates(bases: wide, links: links, others: elsewhere, count: 3)
        == ["base1", "high1", "high2"])
}
