import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

@Test func signInThenSignOutLeavesNoRunningTask() async throws {
    let world = try await World()
    let user = await world.backend.addUser(displayName: "Alice", appleToken: "apple-alice")
    let phone = Phone("alice", user: user, world: world, signedIn: false, push: true)
    let census = phone.dependencies.census

    try #require(await eventually { await phone.app.state == .signedOut(.noSession) })
    #expect(census.running == 0)

    try await phone.app.signInWithApple(idToken: "apple-alice", nonce: nil, fullName: nil)
    try #require(await eventually { await phone.isReady() })
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await phone.resortIsReady() })
    try #require(await eventually { phone.location.consumerCount == 1 })

    // Signed in: the realtime subscription, the resort and its effects are alive.
    #expect(census.running > 0)
    #expect(world.backend.subscriberCount(topic: "user:\(user.uuidString.lowercased())") == 1)
    #expect(await world.backend.deviceTokens(of: user) == [Phone.pushToken])

    phone.app.send(.signOutRequested)
    try #require(await eventually { await phone.app.state == .signedOut(.userRequested) })

    // Signed out: nothing is running, subscribed, sleeping or listening.
    #expect(census.running == 0, "still running: \(census.runningNames)")
    #expect(world.backend.totalSubscriberCount == 0)
    #expect(phone.location.consumerCount == 0 && !phone.location.isRunning)
    #expect(world.clock.sleeperCount == 0)
    #expect(await phone.app.resortSession == nil)
    // The server is told after the sign-in screen is up.
    #expect(await eventually { await world.backend.deviceTokens(of: user).isEmpty })
    #expect(await eventually { await phone.client.currentSession() == nil })

    await phone.kill()
    world.cleanUp()
}

@Test func switchingResortCancelsTheOldResortsLoads() async throws {
    let world = try await World()
    try await world.publish("other-resort")
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    try #require(await eventually { await phone.isReady() })

    // The first resort's bundle download hangs.
    await world.backend.pause("bundle_data")
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await world.backend.callCount("bundle_data") == 1 })
    let first = try #require(await phone.resort())
    #expect(await first.state == .loadingBundle)

    phone.app.send(.resortSelected("other-resort"))
    try #require(await eventually { await phone.resort()?.resortID == "other-resort" })
    await world.backend.resume("bundle_data")
    try #require(await eventually { await phone.resortIsReady() })

    // The old load was cancelled, not merely outlived: it never delivered a
    // bundle, cached nothing, and only the new resort's load is running.
    #expect(await first.state == .loadingBundle)
    #expect(phone.dependencies.bundles.activeBundleID(resortID: TestResort.id) == nil)
    #expect(phone.dependencies.bundles.activeBundleID(resortID: "other-resort") != nil)
    #expect(phone.dependencies.census.runningNames.filter { $0 == "load" }.count == 1)
    #expect(await world.backend.callCount("bundle_data") == 2)
    #expect(world.backend.subscriberCount(topic: "resort:\(TestResort.id)") == 0)
    #expect(await eventually { world.backend.subscriberCount(topic: "resort:other-resort") == 1 })

    await phone.kill()
    #expect(phone.dependencies.census.running == 0)
    world.cleanUp()
}

@Test func aFullMeetFromProposeToCompleted() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try await pair.accept()

    // The proposer learns of the acceptance from `meet.updated` and routes itself.
    try #require(await eventually { await pair.navigation(pair.a) != nil })
    let route = try #require(await pair.navigation(pair.a)).route
    #expect(route.legs.map(\.edgeID) == ["w20:0"])
    #expect(route.eta.sdS > 0, "variance carries into navigation (I-10)")
    let meetID = try #require(await pair.a.meet()?.meetID)
    #expect(await pair.b.meet()?.meetID == meetID)

    // Alice skis the run; Bob waits at the base.
    let line = TestResort.directLine.map(\.coordinate)
    for fraction in [0.25, 0.5, 0.75] {
        await pair.world.advance(20)
        pair.a.stand(at: try #require(Geo.interpolate(along: line, fraction: fraction)))
        pair.b.stand(at: TestResort.base)
    }
    try #require(await eventually {
        (await pair.navigation(pair.a)?.progress.fractionAlongLeg ?? 0) > 0.5
    })
    // Progress reaches the partner through the server.
    try #require(await eventually {
        if case .active(let active) = await pair.b.meetState() { return active.partner?.state == .navigating }
        return false
    })

    // Within 30 m of the rendezvous for 10 s is arrival.
    for _ in 0..<2 {
        await pair.world.advance(11)
        pair.a.stand(at: TestResort.base)
        pair.b.stand(at: TestResort.base)
    }
    // Both there: the meet completes by itself for both, with no tap.
    for phone in [pair.a, pair.b] {
        try #require(await eventually { await pair.ended(phone) != nil })
        let ended = try #require(await pair.ended(phone))
        #expect(ended.reason == .arrived && ended.meet?.status == .completed)
    }
    #expect(await pair.world.backend.storedMeet(meetID)?.status == .completed)
    #expect(try await pair.a.client.meetCurrent() == nil)

    // The funnel reached the server through the outbox.
    try #require(await eventually {
        let kinds = Set(await pair.world.backend.clientEvents.map(\.kind))
        return kinds.isSuperset(of: ["meet.proposed", "meet.accepted", "meet.active", "meet.ended"])
    })
    await pair.shutDown()
}

@Test func relaunchMidMeetRecoversIt() async throws {
    let pair = try await Pair()
    try await pair.propose()
    let meetID = try #require(await pair.a.meet()?.meetID)

    // D4: the proposer's app is killed, then the invitee accepts.
    await pair.a.kill()
    #expect(pair.a.dependencies.census.running == 0)
    try await pair.accept()

    // Relaunch: same account and caches, a new process. Nothing is selected by
    // hand; `meet_current()` brings back the resort and the meet.
    let relaunched = Phone("alice", user: pair.a.user, world: pair.world)
    try #require(await eventually {
        if case .active = await relaunched.meetState() { return true }
        return false
    })
    #expect(await relaunched.meet()?.meetID == meetID)
    #expect(await relaunched.resort()?.resortID == TestResort.id)
    // The bundle came from the disk cache: no second download for this phone.
    #expect(await pair.world.backend.calls.filter {
        $0.name == "bundle_data" && $0.user == pair.a.user
    }.count == 1)

    // The first fix after relaunch puts the proposer back on a route.
    await pair.world.advance(5)
    relaunched.stand(at: TestResort.top)
    try #require(await eventually { await pair.navigation(relaunched) != nil })
    #expect(await pair.navigation(relaunched)?.route.legs.map(\.edgeID) == ["w20:0"])

    // And it still ends for both.
    try #require(await relaunched.meet()).send(.userEnded)
    try #require(await eventually { await pair.ended(pair.b)?.reason == .userCancelled })
    try #require(await eventually { await pair.ended(relaunched)?.reason == .userCancelled })

    await relaunched.kill()
    await pair.shutDown()
}

@Test func aClosureReroutesAndThenEndsTheMeetWithAReason() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try await pair.accept()
    try #require(await eventually { await pair.navigation(pair.a) != nil })
    #expect(await pair.navigation(pair.a)?.route.legs.map(\.edgeID) == ["w20:0"])

    // D6: the run on the remaining route closes. Another way down exists.
    // Each phone has a fresh fix (I-14): an old one would leave the route alone.
    await pair.world.advance(60)
    pair.a.stand(at: TestResort.top)
    pair.b.stand(at: TestResort.base)
    await pair.world.backend.publishStatus(pair.world.status(closed: [TestResort.directRun]))
    try #require(await eventually {
        await pair.navigation(pair.a)?.route.legs.map(\.edgeID) == ["w30:0", "w30:1"]
    })
    if case .active(let active) = await pair.b.meetState() {
        #expect(active.meet.status == .active)
    } else {
        Issue.record("the partner's meet should still be active after a reroute")
    }

    // Then the other way closes too: no route is left, so the meet ends, and
    // both phones say why.
    await pair.world.advance(60)
    pair.a.stand(at: TestResort.top)
    pair.b.stand(at: TestResort.base)
    await pair.world.backend.publishStatus(
        pair.world.status(closed: [TestResort.directRun, TestResort.longWay])
    )
    for phone in [pair.a, pair.b] {
        try #require(await eventually { await pair.ended(phone) != nil })
        let ended = try #require(await pair.ended(phone))
        #expect(ended.reason == .statusBlocksRoute && ended.meet?.status == .invalidated)
    }
    await pair.shutDown()
}

@Test func connectionGoesOfflineThenReconnectingThenOnline() async throws {
    let world = try await World()
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    try #require(await eventually { await phone.isReady() })
    #expect(await phone.app.link == .online)

    phone.reachability.set(online: false)
    try #require(await eventually { await phone.app.link == .offline })

    // The network is back but the server has not answered yet.
    await world.backend.pause("meet_current")
    phone.reachability.set(online: true)
    try #require(await eventually { await phone.app.link == .reconnecting })
    await world.backend.resume("meet_current")
    try #require(await eventually { await phone.app.link == .online })

    // A server that answers with something a retry cannot fix must not leave
    // "reconnecting" on screen for ever.
    phone.reachability.set(online: false)
    try #require(await eventually { await phone.app.link == .offline })
    await world.backend.failNext("meet_current", with: .decoding("bad row"))
    phone.reachability.set(online: true)
    try #require(await eventually { await phone.app.link == .unconfirmed })

    await phone.kill()
    world.cleanUp()
}

@Test func replacingASentProposalSupersedesItForBoth() async throws {
    let pair = try await Pair()
    try await pair.propose()
    guard case .proposed(let first) = await pair.a.meetState() else {
        Issue.record("no proposal sent")
        return
    }
    try #require(await eventually {
        if case .incoming(let incoming) = await pair.b.meetState() { return incoming.meet.meetID == first.meetID }
        return false
    })

    // Changing the spot solves again; backing out keeps the sent proposal.
    let session = try #require(await pair.a.meet())
    session.send(.changeProposal)
    try #require(await eventually {
        if case .proposing(let proposing) = await pair.a.meetState() {
            return proposing.replacing?.meetID == first.meetID && proposing.options != nil
        }
        return false
    })
    session.send(.userEnded)
    try #require(await eventually {
        if case .proposed(let meet) = await pair.a.meetState() { return meet.meetID == first.meetID }
        return false
    })
    #expect(await pair.world.backend.storedMeet(first.meetID)?.status == .proposed)

    // Sending the replacement ends the old row and the invitee sees the new one.
    session.send(.changeProposal)
    try #require(await eventually {
        if case .proposing(let proposing) = await pair.a.meetState() { return proposing.options != nil }
        return false
    })
    session.send(.optionPicked(0))
    session.send(.sent)
    try #require(await eventually {
        if case .proposed(let meet) = await pair.a.meetState() { return meet.meetID != first.meetID }
        return false
    })
    guard case .proposed(let second) = await pair.a.meetState() else { return }
    let old = await pair.world.backend.storedMeet(first.meetID)
    #expect(old?.status == .invalidated && old?.endReason == .superseded && old?.supersededBy == second.meetID)
    try #require(await eventually {
        if case .incoming(let incoming) = await pair.b.meetState() { return incoming.meet.meetID == second.meetID }
        return false
    })

    try await pair.accept()
    try #require(await eventually {
        if case .active(let active) = await pair.a.meetState() { return active.meet.meetID == second.meetID }
        return false
    })
    await pair.shutDown()
}

/// Changing skill level while the options show re-solves them (the demo's
/// "changing skill level changes the answer"): green-only routes Alice down
/// the Long Way instead of the blue Test Run.
@Test func aProfileEditReSolvesTheOptionsOnScreen() async throws {
    let pair = try await Pair()
    let resort = try #require(await pair.a.resort())
    resort.send(.proposeRequested(friend: pair.b.user))
    @Sendable func aliceLegs() async -> [EdgeID]? {
        guard case .proposing(let proposing) = await pair.a.meetState(),
              let option = proposing.options?.options.first(where: { $0.rendezvous == TestResort.baseRendezvous })
        else { return nil }
        return option.routes.0.legs.map(\.edgeID)
    }
    try #require(await eventually { await aliceLegs() == ["w20:0"] })
    pair.a.app.send(.profileEdited(ProfilePatch().maxDifficulty("green")))
    try #require(await eventually { await aliceLegs() == ["w30:0", "w30:1"] })
    await pair.shutDown()
}

/// Notifications allowed after sign-in (or a token iOS replaced) still reach
/// the server, and sign-out unregisters the token pushes go to.
@Test func aTokenThatArrivesAfterStartupIsRegistered() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world)
    try #require(await eventually { await phone.isReady() })
    #expect(await world.backend.deviceTokens(of: user).isEmpty)

    let push = try #require(phone.dependencies.push as? FakePushRegistrar)
    let token = DeviceToken(token: String(repeating: "cd", count: 32), environment: .development)
    try #require(await eventually {
        push.receive(token)
        return await world.backend.deviceTokens(of: user) == [token.token]
    })

    phone.app.send(.signOutRequested)
    try #require(await eventually { await phone.app.state == .signedOut(.userRequested) })
    // The signed-out screen shows first; the server is told just after.
    try #require(await eventually { await world.backend.deviceTokens(of: user).isEmpty })
    await phone.kill()
}
