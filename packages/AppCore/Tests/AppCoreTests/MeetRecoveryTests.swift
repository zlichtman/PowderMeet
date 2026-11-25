import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// A meet session on its own, wired to nothing but the server: no realtime
/// reaches it, so every event it gets is one the test sends or a read it makes.
private struct LoneSession {
    let session: MeetSession
    let task: Task<Void, Never>

    init(adopting meet: Meet, as user: UUID, world: World) async throws {
        let stored = try TestResort.stored()
        let bundle = try BundleLoader.load(data: stored.data, expectedID: stored.bundleID)
        let profile = try #require(await world.backend.storedProfile(of: user))
        let dependencies = Dependencies(
            backend: world.backend.client(signedInAs: user), location: FakeLocationProvider(),
            clock: world.clock, reachability: FakeReachability(), push: FakePushRegistrar(token: nil),
            cacheDirectory: world.root.appendingPathComponent("lone-\(user)", isDirectory: true),
            appBuild: "test"
        )
        let session = MeetSession(
            start: .adopt(meet), context: MeetSession.Context(profile: profile, bundle: bundle),
            dependencies: dependencies
        )
        self.session = session
        task = Task { await session.run() }
    }

    func isActive() async -> Bool {
        if case .active = await session.state { return true }
        return false
    }

    func stop() async {
        task.cancel()
        await task.value
    }
}

private actor StateLog {
    var states: [MeetSession.State] = []
    func add(_ state: MeetSession.State) { states.append(state) }
}

@Test func aLostAcceptanceIsFoundByTheResyncAndALateProposedRowCannotUndoIt() async throws {
    let world = try await World()
    let alice = await world.backend.addUser(displayName: "Alice")
    let bob = await world.backend.addUser(displayName: "Bob")
    await world.backend.makeFriends(alice, bob)
    let stored = try TestResort.stored()
    let proposed = try await world.backend.client(signedInAs: alice).meetPropose(
        meetID: UUID(), invitee: bob, resortID: TestResort.id, rendezvousID: TestResort.baseRendezvous,
        bundleID: stored.bundleID, proposerEtaS: 300, proposerEtaSdS: 60, supersedes: nil
    )
    let lone = try await LoneSession(adopting: proposed, as: alice, world: world)
    // Only the resync timer sleeps while the proposal waits.
    try #require(await eventually { world.clock.sleeperCount == 1 })

    // Bob accepts; the `meet.updated` never reaches this session.
    let active = try await world.backend.client(signedInAs: bob).meetRespond(
        meetID: proposed.meetID, accept: true, inviteeEtaS: 200, inviteeEtaSdS: 40, declineReason: nil
    )
    #expect(await lone.session.state == .proposed(proposed))
    await world.advance(MeetSession.resyncIntervalS + 1)
    try #require(await eventually { await lone.isActive() })

    // A replayed or late read of the proposal arrives after the acceptance.
    let log = StateLog()
    let watcher = Task { for await state in await lone.session.states() { await log.add(state) } }
    lone.session.send(.proposalUpdated(proposed))
    var later = active
    later.inviteeEtaS = 999
    lone.session.send(.proposalUpdated(later))
    try #require(await eventually {
        if case .active(let now) = await lone.session.state { return now.meet.inviteeEtaS == 999 }
        return false
    })
    #expect(await !log.states.contains {
        if case .proposed = $0 { return true }
        return false
    }, "a proposed row moved an active meet backwards")

    watcher.cancel()
    await lone.stop()
    world.cleanUp()
}

@Test func switchingResortMidMeetEndsItForThePartner() async throws {
    let pair = try await Pair()
    try await pair.world.publish("other-resort")
    try await pair.propose()
    try await pair.accept()

    pair.a.app.send(.resortSelected("other-resort"))
    try #require(await eventually { await pair.ended(pair.b)?.reason == .partnerLeft })
    await pair.shutDown()
}

@Test func signingOutWithAProposalOutWithdrawsIt() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try #require(await eventually {
        if case .incoming = await pair.b.meetState() { return true }
        return false
    })

    pair.a.app.send(.signOutRequested)
    try #require(await eventually { await pair.ended(pair.b)?.reason == .userCancelled })
    await pair.shutDown()
}

@Test func anOldFixDoesNotPlanAMeet() async throws {
    let pair = try await Pair()
    // Alice stands still long enough for her last fix to stop being routing grade.
    await pair.world.advance(FixQuality.maximumAgeS + 5)
    try #require(await pair.a.resort()).send(.proposeRequested(friend: pair.b.user))
    try #require(await eventually {
        if case .proposing(let proposing) = await pair.a.meetState() {
            return proposing.failure == .routing(.originNotOnGraph(pair.a.user)) && proposing.options == nil
        }
        return false
    })

    // A fresh fix plans it.
    pair.a.stand(at: TestResort.top)
    try #require(await eventually {
        if case .proposing(let proposing) = await pair.a.meetState() { return proposing.options != nil }
        return false
    })
    await pair.shutDown()
}

@Test func aPrefetchSolvedBeforeAStatusChangeIsNotKept() async throws {
    let pair = try await Pair()
    let resort = try #require(await pair.a.resort())
    try #require(await eventually { await resort.hasPrefetchedOptions(for: pair.b.user) })

    // The status changes; the answers are dropped and solved again on it.
    await pair.world.backend.publishStatus(pair.world.status(closed: []))
    try #require(await eventually {
        if case .ready(let ready) = await resort.state { return ready.status != nil }
        return false
    })
    // Jobs are spaced: the next one waits out the gap after the first (its
    // sleep may start after an advance, so give it a few).
    var resolved = false
    for _ in 0..<5 where !resolved {
        await pair.world.advance(MeetPrefetch.minimumGapS + 1)
        resolved = await eventually(timeout: 1) { await resort.hasPrefetchedOptions(for: pair.b.user) }
    }
    try #require(resolved)
    let ready = try #require(await { () async -> ResortSession.Ready? in
        if case .ready(let ready) = await resort.state { return ready }
        return nil
    }())

    // A job that started before the change answers late, solved on no status.
    let key = MeetPrefetch.Key(
        friend: pair.b.user, mine: TestResort.top.coordinate, theirs: TestResort.base.coordinate,
        profile: SkierProfile(try #require(await pair.world.backend.storedProfile(of: pair.a.user))),
        at: pair.a.dependencies.solveClock.now
    )
    resort.send(.prefetched(.init(
        key: key, bundleID: ready.bundle.id, status: nil, conditions: ready.conditions, options: nil
    )))
    // Handled in order: once Bob's newer position is in, the late answer was too.
    let moved = Date(timeInterval: 1, since: try #require(await resort.friends[pair.b.user]).capturedAt)
    resort.send(.friendsPresence([Presence(
        userID: pair.b.user, resortID: TestResort.id, lon: TestResort.base.lon, lat: TestResort.base.lat,
        accuracyM: 5, capturedAt: moved
    )]))
    try #require(await eventually { await resort.friends[pair.b.user]?.capturedAt == moved })
    #expect(await resort.hasPrefetchedOptions(for: pair.b.user), "a stale answer replaced a current one")
    await pair.shutDown()
}

@Test func aStandingSkierBesideALiftIsNotPlacedOnIt() throws {
    let stored = try TestResort.stored()
    let bundle = try BundleLoader.load(data: stored.data, expectedID: stored.bundleID)
    // Halfway up the chair, far from both stations and from every run.
    let midLift = Coordinate(lon: TestResort.base.lon, lat: 50.105)
    func origin(speed: Double?) -> RoutingOrigin.Kind? {
        OriginResolver.origin(
            for: Fix(coordinate: midLift, accuracyM: 5, capturedAt: Date(), speedMS: speed), in: bundle
        )?.kind
    }
    func onLift(_ kind: RoutingOrigin.Kind?) -> Bool {
        if case .onEdge(let edge, _) = kind { return edge == "w10:0" }
        return false
    }
    #expect(!onLift(origin(speed: 0)))
    #expect(onLift(origin(speed: 2.5)), "a moving fix on the line is riding")
    #expect(onLift(origin(speed: nil)))
}

@Test func aSkierFasterThanTheLiftBesideItIsPlacedOnTheRun() throws {
    let stored = try TestResort.stored()
    let bundle = try BundleLoader.load(data: stored.data, expectedID: stored.bundleID)
    // Near the bottom, about 20 m from the chair and 40 m from the run beside it.
    let besideLift = Coordinate(lon: -122.9503, lat: 50.101)
    func edge(speed: Double) -> EdgeID? {
        let kind = OriginResolver.origin(
            for: Fix(coordinate: besideLift, accuracyM: 5, capturedAt: Date(), speedMS: speed), in: bundle
        )?.kind
        if case .onEdge(let edge, _) = kind { return edge }
        return nil
    }
    #expect(edge(speed: 12) == "w20:0", "skiing speed is not riding a chair")
    #expect(edge(speed: 2.5) == "w10:0", "chair speed beside the line may be riding")
}

@Test func presenceIsNotPublishedFarFromTheResort() async throws {
    let world = try await World()
    let alice = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: alice, world: world)
    try #require(await eventually { await phone.isReady() })
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await phone.resortIsReady() })
    try #require(await eventually { phone.location.consumerCount == 1 })

    // At home, about 70 km from the resort, browsing its map.
    phone.stand(at: Coordinate(lon: -122.0, lat: 50.1))
    await world.advance(1)
    phone.stand(at: TestResort.top)
    try #require(await eventually { await world.backend.storedPresence(of: alice) != nil })
    let row = try #require(await world.backend.storedPresence(of: alice))
    #expect(row.lon == TestResort.top.lon && row.lat == TestResort.top.lat)

    await phone.kill()
    world.cleanUp()
}

@Test func anUnfriendedPersonLeavesTheMapAtOnce() async throws {
    let pair = try await Pair()
    let resort = try #require(await pair.a.resort())
    let updates = await resort.friendUpdates()
    resort.send(.personRemoved(pair.b.user))
    try #require(await eventually { await resort.friends[pair.b.user] == nil })
    // The map is told too, not only the session.
    var latest: [UUID: Presence]?
    for await friends in updates {
        latest = friends
        if friends[pair.b.user] == nil { break }
    }
    #expect(latest?[pair.b.user] == nil)
    await pair.shutDown()
}

/// A friend who closed the resort sends no event: their last position leaves
/// the map once it is as old as the server's presence TTL, and a fresher one
/// stays.
@Test func aFriendWhoStoppedSendingLeavesTheMap() async throws {
    let pair = try await Pair()
    let resort = try #require(await pair.a.resort())
    let gone = UUID(), here = UUID()
    func row(_ user: UUID) -> Presence {
        Presence(
            userID: user, resortID: TestResort.id, lon: TestResort.base.lon, lat: TestResort.base.lat,
            accuracyM: 5, capturedAt: pair.world.clock.now
        )
    }
    resort.send(.friendsPresence([row(gone)]))
    try #require(await eventually { await resort.friends[gone] != nil })
    await pair.world.advance(10 * 60)
    resort.send(.friendsPresence([row(here)]))
    try #require(await eventually { await resort.friends[here] != nil })

    await pair.world.advance(5 * 60)
    try #require(await eventually { await resort.friends[gone] == nil })
    #expect(await resort.friends[here] != nil)
    // A row already past the bound (`FriendSignal.forgetAfterS`) is not drawn at all.
    let stale = Presence(
        userID: gone, resortID: TestResort.id, lon: TestResort.base.lon, lat: TestResort.base.lat,
        accuracyM: 5, capturedAt: pair.world.clock.now.addingTimeInterval(-15 * 60)
    )
    resort.send(.friendsPresence([stale]))
    resort.send(.friendsPresence([row(here)]))
    try #require(await eventually { await resort.friends[here]?.capturedAt == pair.world.clock.now })
    #expect(await resort.friends[gone] == nil)
    await pair.shutDown()
}

/// On a slow cell a publish still on its way is never cancelled by the next
/// one; the first fix after the server has answered goes.
@Test func aSlowPresencePublishIsNotCancelledByTheNext() async throws {
    let world = try await World()
    let alice = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: alice, world: world)
    try #require(await eventually { await phone.isReady() })
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await phone.resortIsReady() })
    try #require(await eventually { phone.location.consumerCount == 1 })
    let resort = try #require(await phone.resort())

    await world.backend.pause("presence_update")
    phone.stand(at: TestResort.top)
    try #require(await eventually { await world.backend.callCount("presence_update") == 1 })
    for node in [TestResort.junction, TestResort.base] {
        await world.advance(ResortSession.movingIntervalS + 6)
        phone.stand(at: node)
    }
    try #require(await eventually { await resort.trail(for: alice, since: .distantPast).count == 3 })
    #expect(await world.backend.callCount("presence_update") == 1, "a publish in flight was replaced")

    await world.backend.resume("presence_update")
    try #require(await eventually {
        await world.backend.storedPresence(of: alice)?.lat == TestResort.top.lat
    })
    // Until the session has taken the answer, a fix is skipped; then one goes.
    try #require(await eventually {
        await world.advance(ResortSession.movingIntervalS + 1)
        phone.stand(at: TestResort.base)
        guard let row = await world.backend.storedPresence(of: alice) else { return false }
        return row.lon == TestResort.base.lon && row.lat == TestResort.base.lat
    })
    #expect(await world.backend.callCount("presence_update") == 2)
    await phone.kill()
    world.cleanUp()
}

/// Accepting a proposal that ran out but is not yet swept says so, rather
/// than doing nothing.
@Test func acceptingAnExpiredProposalSaysItIsGone() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try #require(await eventually {
        if case .incoming(let incoming) = await pair.b.meetState() { return incoming.ownRoute != nil }
        return false
    })
    await pair.world.backend.failNext("meet_respond", with: .meetExpired)
    try #require(await pair.b.meet()).send(.accepted)
    try #require(await eventually {
        if case .incoming(let incoming) = await pair.b.meetState() { return incoming.failure == .meet(.meetGone) }
        return false
    })
    await pair.shutDown()
}

/// GPS lost since the invitation was routed: accepting sends no time, so the
/// proposer is not shown one worked out from where the skier was, and the
/// first new fix routes.
@Test func acceptingWithGPSLostSendsNoTimeFromAnOldPlace() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try #require(await eventually {
        if case .incoming(let incoming) = await pair.b.meetState() { return incoming.ownRoute != nil }
        return false
    })
    let meetID = try #require(await pair.b.meet()?.meetID)
    await pair.world.advance(FixQuality.maximumAgeS + 5)
    try #require(await pair.b.meet()).send(.accepted)
    try #require(await eventually {
        if case .active = await pair.b.meetState() { return true }
        return false
    })
    let stored = try #require(await pair.world.backend.storedMeet(meetID))
    #expect(stored.inviteeEtaS == nil && stored.inviteeEtaSdS == nil)
    #expect(await pair.navigation(pair.b) == nil, "the invitation's route is not carried")

    pair.b.stand(at: TestResort.base)
    try #require(await eventually { await pair.navigation(pair.b) != nil })
    await pair.shutDown()
}
