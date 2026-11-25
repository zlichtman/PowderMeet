import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// A signed-in phone on the test resort with developer testing's sandbox in
/// front of the "real" backend (a stand-in `FakeBackend`).
private struct SandboxedPhone {
    let world: World
    let location: PlaceableLocationProvider
    let sandbox: DeveloperSandbox
    let app: AppSession
    let resort: ResortSession
    let bundle: ResortBundle
    let running: Task<Void, Never>

    init() async throws {
        world = try await World()
        let me = await world.backend.addUser(displayName: "Tester")
        location = PlaceableLocationProvider(base: FakeLocationProvider(), clock: world.clock)
        sandbox = DeveloperSandbox(
            location: location, solveClock: world.clock,
            timing: RehearsalPartner.Timing(answersAfterS: 0.05, speedup: 2_000, tickS: 0.05, idleReportS: 60)
        )
        let backend = SandboxedBackend(base: world.backend.client(signedInAs: me), sandbox: sandbox)
        let dependencies = Dependencies(
            backend: backend, location: location, clock: world.clock, reachability: FakeReachability(),
            push: FakePushRegistrar(), cacheDirectory: world.root.appendingPathComponent("tester", isDirectory: true),
            appBuild: "test"
        )
        let app = AppSession(dependencies: dependencies)
        self.app = app
        running = Task { await app.run() }

        try #require(await eventually {
            if case .ready = await app.state { return true }
            return false
        })
        app.send(.resortSelected(TestResort.id))
        try #require(await eventually {
            guard let resort = await app.resortSession else { return false }
            if case .ready = await resort.state { return true }
            return false
        })
        resort = try #require(await app.resortSession)
        guard case .ready(let ready) = await resort.state else {
            throw DeveloperSandbox.Failure.notReady
        }
        bundle = ready.bundle
        await sandbox.stage(RehearsalPartner.Stage(bundle: bundle))
    }

    func stop() async {
        running.cancel()
        await running.value
        world.cleanUp()
    }
}

/// Developer testing in live mode (`specs/07-CLIENT.md` section 8): a teleported
/// phone with two dev people on the mountain meets one of them from proposal to
/// arrival, and the real backend sees none of it: no meet call, no position, no
/// meet funnel event.
@Test func aPretendMeetNeverReachesTheRealBackend() async throws {
    let phone = try await SandboxedPhone()
    let (dev1, dev2) = (DeveloperSandbox.devPeople[0].id, DeveloperSandbox.devPeople[1].id)

    // Teleported to the top, keeping the pretend position to this phone.
    phone.sandbox.setWithholdsPresence(true)
    phone.location.place(at: TestResort.top.coordinate)
    try await phone.sandbox.place(dev1, at: TestResort.base.coordinate)
    try await phone.sandbox.place(dev2, at: TestResort.base.coordinate)
    try #require(await eventually {
        let friends = await phone.resort.friends
        return friends[dev1] != nil && friends[dev2] != nil
    })

    phone.resort.send(.proposeRequested(friend: dev2))
    try #require(await eventually {
        if case .proposing(let proposing) = await phone.resort.meetSession?.state { return proposing.picked != nil }
        return false
    })
    let meet = try #require(await phone.resort.meetSession)
    meet.send(.sent)
    // Dev 2 accepts, and both travel.
    try #require(await eventually {
        if case .active(let active) = await meet.state { return active.navigation != nil }
        return false
    })
    // Dev 2 reaches the meeting point; this phone stands there for over 10 s,
    // and the meet completes by itself.
    guard case .active(let active) = await meet.state,
          let node = phone.bundle.rendezvous(active.meet.rendezvousID).flatMap({ phone.bundle.graph.nodes[$0.nodeID] })
    else { throw DeveloperSandbox.Failure.notReady }
    // The rehearsal moves this phone down its route first; stand still after.
    try #require(await eventually {
        phone.location.lastCoordinate.map { Geo.haversineM($0, node.coordinate) < 1 } ?? false
    })
    for _ in 0..<3 {
        await phone.world.advance(6)
        phone.location.place(at: node.coordinate)
    }
    try #require(await eventually {
        if case .ended(let ended) = await meet.state { return ended.reason == .arrived }
        return false
    })

    for call in ["meet_propose", "meet_respond", "meet_progress_update", "meet_end", "presence_update"] {
        #expect(await phone.world.backend.callCount(call) == 0, "\(call) reached the real backend")
    }
    #expect(!(await phone.world.backend.clientEvents.contains { $0.kind.hasPrefix("meet.") }))
    await phone.stop()
}

/// A dev person set to Beginner and placed part-way down a blue run has no way
/// down within their level, so the meet still forms on the easiest way down
/// and names them (roadmap: two people can always meet).
@Test func aSkierStuckAboveTheirLevelGetsTheEasiestWayDown() async throws {
    let phone = try await SandboxedPhone()
    let dev2 = DeveloperSandbox.devPeople[1]

    phone.location.place(at: TestResort.top.coordinate)
    try await phone.sandbox.setLevel(.beginner, for: dev2.id)
    // Half-way down the blue direct run, which a beginner may not ski.
    try await phone.sandbox.place(dev2.id, at: TestResort.directLine[1].coordinate)
    try #require(await eventually { await phone.resort.friends[dev2.id] != nil })

    phone.resort.send(.proposeRequested(friend: dev2.id))
    try #require(await eventually {
        if case .proposing(let proposing) = await phone.resort.meetSession?.state {
            return proposing.options != nil || proposing.failure != nil
        }
        return false
    })
    guard case .proposing(let proposing) = await phone.resort.meetSession?.state else {
        Issue.record("the meet is not proposing")
        return
    }
    #expect(proposing.failure == nil)
    let best = try #require(proposing.options?.options.first)
    #expect(best.reasons.contains(.easiestWayDownFor(dev2.id)))
    await phone.stop()
}

/// "Show dev people" puts the three on three different places a skier can
/// stand, the same three on every launch, and a shuffle moves them.
@Test func theThreeDevPeopleStartApartOnTheMountain() throws {
    let bundle = ResortBundle(id: try TestResort.stored().bundleID, document: TestResort.document())
    let seed = DeveloperSpots.seed(for: TestResort.id)
    let spots = DeveloperSpots.pick(DeveloperSandbox.devPeople.count, in: bundle, seed: seed)

    #expect(spots.count == 3)
    #expect(Set(spots).count == 3)
    for spot in spots {
        let snapped = try #require(DeveloperPlacement.snap(spot, in: bundle))
        #expect(Geo.haversineM(snapped, spot) < 1)
    }
    #expect(DeveloperSpots.pick(3, in: bundle, seed: seed) == spots)
    #expect(DeveloperSpots.seed(for: TestResort.id, shuffle: 1) != seed)
}

/// The Time page's presets land on the lift day the solver reads: first chair
/// at the first opening, last chair before the last lift shuts.
@Test func solverTimePresetsLandOnTheLiftDay() throws {
    let day = LiftDay(openMinute: 8 * 60 + 30, closeMinute: 16 * 60)
    #expect(SolverTimePreset.firstChair.minuteOfDay(on: day) == 510)
    #expect(SolverTimePreset.midday.minuteOfDay(on: day) == 750)
    #expect(SolverTimePreset.lastChair.minuteOfDay(on: day) == 945)
    #expect(SolverTimePreset.firstChair.minuteOfDay(on: nil) == 540)

    // The test chair has no hours: the solver's 7:00 to 21:00.
    let bundle = ResortBundle(id: try TestResort.stored().bundleID, document: TestResort.document())
    #expect(LiftDay.of(bundle, weekday: 3) == LiftDay(openMinute: 420, closeMinute: 1_260))
    #expect(LiftDay.anyLiftRuns(bundle, weekday: 3, minute: 1_259))
    #expect(!LiftDay.anyLiftRuns(bundle, weekday: 3, minute: 1_260))
}
