import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// Alice skis the direct run to the base, where Bob waits, standing at
/// `fraction` of the run every 11 s for `times` fixes.
private func ski(_ pair: Pair, to fraction: Double, times: Int = 2) async throws {
    let line = TestResort.directLine.map(\.coordinate)
    let here = try #require(Geo.interpolate(along: line, fraction: fraction))
    for _ in 0..<times {
        await pair.world.advance(11)
        pair.a.stand(at: here)
        pair.b.stand(at: TestResort.base)
    }
}

private func activeState(_ phone: Phone) async -> MeetSession.Active? {
    if case .active(let active) = await phone.meetState() { return active }
    return nil
}

/// "Arrived" means one thing: 30 m of the meeting point for 10 s. The route
/// used up within 110 m is only nearly there; it is neither shown nor
/// published as arrived, and the meet does not complete on it.
@Test func nearlyThereIsNotArrivedAndThirtyMetresForTenSecondsIs() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try await pair.accept()
    try #require(await eventually { await pair.navigation(pair.a) != nil })

    try await ski(pair, to: 0.5)
    // About 65 m short of the base: past the last leg's midpoint and inside
    // the 80 m leg end, so the route itself is finished.
    let nearly = try #require(Geo.interpolate(along: TestResort.directLine.map(\.coordinate), fraction: 0.95))
    #expect(Geo.haversineM(nearly, TestResort.base.coordinate) > 50)
    try await ski(pair, to: 0.95, times: 3)
    try #require(await eventually { await pair.navigation(pair.a)?.progress.state == .arrived })
    try #require(await eventually { await activeState(pair.b)?.arrived == true })
    // The progress tick sends the last fix's progress.
    await pair.world.advance(11)
    try #require(await eventually { await activeState(pair.b)?.partner?.remainingM == 0 })
    #expect(await activeState(pair.a)?.arrived == false)
    #expect(await activeState(pair.b)?.partner?.state == .navigating, "nearly there is not published as arrived")

    // Twenty metres from the base for more than 10 s is arrival, and with
    // Bob there too the meet completes by itself.
    try await ski(pair, to: 0.985)
    for phone in [pair.a, pair.b] {
        try #require(await eventually { await pair.ended(phone) != nil })
        #expect(await pair.ended(phone)?.reason == .arrived)
    }
    await pair.shutDown()
}

/// A server from before automatic completion leaves the meet active: the phone
/// that sees both arrived completes it, once, and a late duplicate from the
/// other phone changes nothing.
@Test func bothArrivedCompletesOnceEvenOnAnOlderServer() async throws {
    let pair = try await Pair()
    await pair.world.backend.setCompletesMeetsOnArrival(false)
    try await pair.propose()
    try await pair.accept()
    try #require(await eventually { await pair.navigation(pair.a) != nil })
    let meetID = try #require(await pair.a.meet()?.meetID)

    try await ski(pair, to: 0.5)
    try await ski(pair, to: 1, times: 3)
    for phone in [pair.a, pair.b] {
        try #require(await eventually { await pair.ended(phone) != nil })
        let ended = try #require(await pair.ended(phone))
        #expect(ended.reason == .arrived && ended.meet?.status == .completed)
    }
    for user in [pair.a.user, pair.b.user] {
        #expect(await pair.world.backend.calls.count { $0.name == "meet_end" && $0.user == user } <= 1)
    }

    let late = try await pair.b.client.meetEnd(meetID: meetID, reason: .arrived)
    #expect(late.status == .completed && late.endReason == .arrived)
    #expect(await pair.world.backend.storedMeet(meetID)?.status == .completed)
    await pair.shutDown()
}

/// A friend's level is read again when a solve finds the copy older than two
/// minutes, and not before.
@Test func aFriendsChangedLevelReachesTheNextSolveAfterTwoMinutes() async throws {
    let pair = try await Pair()
    let resort = try #require(await pair.a.resort())
    resort.send(.proposeRequested(friend: pair.b.user))
    try #require(await eventually {
        if case .proposing(let proposing) = await pair.a.meetState() { return proposing.options != nil }
        return false
    })
    let meet = try #require(await pair.a.meet())
    let before = try #require(await meet.partner?.profile)
    _ = try await pair.b.client.profileUpdate(ProfilePatch().ability(before.ability == .expert ? "beginner" : "expert"))
    let reads = await pair.world.backend.callCount("profile")

    // A solve 30 s on keeps the copy.
    await pair.world.advance(30)
    pair.a.stand(at: TestResort.top)
    meet.send(.retry)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await pair.world.backend.callCount("profile") == reads)
    #expect(await meet.partner?.profile == before)

    // Past two minutes the next solve reads the friend again.
    await pair.world.advance(100)
    pair.b.stand(at: TestResort.base)
    pair.a.stand(at: TestResort.top)
    meet.send(.retry)
    try #require(await eventually { await meet.partner?.profile.ability != before.ability })
    await pair.shutDown()
}

/// GPS that never places the two within 30 m (a lodge, a poor fix): the skier
/// ends the meet by hand, and with both within 150 m it is told as met up.
@Test func endingByHandWhileTogetherReadsAsMetUp() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try await pair.accept()
    try #require(await eventually { await pair.navigation(pair.a) != nil })

    try await ski(pair, to: 0.5)
    try await ski(pair, to: 0.95)
    try #require(await eventually { await activeState(pair.a)?.withinReach == true })
    #expect(await activeState(pair.a)?.arrived == false)

    try #require(await pair.a.meet()).send(.userEnded)
    try #require(await eventually { await pair.ended(pair.a) != nil })
    let ended = try #require(await pair.ended(pair.a))
    #expect(ended.reason == .userCancelled && ended.wereTogether)
    await pair.shutDown()
}

/// Arrived, then away again (a lap, the lodge next door): no longer arrived,
/// and published as such, so the partner arriving later does not complete the
/// meet with one skier somewhere else.
@Test func aSkierWhoLeavesTheMeetingPointIsNoLongerArrived() async throws {
    let pair = try await Pair()
    try await pair.propose()
    try await pair.accept()
    try #require(await eventually { await pair.navigation(pair.a) != nil })

    // Bob waits partway up, not at the base, so Alice arrives alone.
    let line = TestResort.directLine.map(\.coordinate)
    let waiting = try #require(Geo.interpolate(along: line, fraction: 0.3))
    let there = try #require(Geo.interpolate(along: line, fraction: 0.985))
    for _ in 0..<3 {
        await pair.world.advance(11)
        pair.a.stand(at: there)
        pair.b.stand(at: waiting)
    }
    try #require(await eventually { await activeState(pair.a)?.arrived == true })
    try #require(await eventually { await activeState(pair.b)?.partner?.state == .arrived })

    // Alice goes back up, well past 100 m from the meeting point.
    let away = try #require(Geo.interpolate(along: line, fraction: 0.5))
    #expect(Geo.haversineM(away, TestResort.base.coordinate) > MeetSession.arrivalLeaveRadiusM)
    for _ in 0..<2 {
        await pair.world.advance(11)
        pair.a.stand(at: away)
        pair.b.stand(at: waiting)
    }
    try #require(await eventually { await activeState(pair.a)?.arrived == false })
    try #require(await eventually { await activeState(pair.b)?.partner?.state != .arrived })
    #expect(await pair.ended(pair.a) == nil)
    await pair.shutDown()
}

/// Alice arrives, then her phone goes quiet (no service, then gone): her
/// `arrived` stays stored. Bob arriving minutes later is not "both there", so
/// his phone does not complete the meet.
@Test func anArrivalMinutesOldDoesNotCompleteTheMeet() async throws {
    let pair = try await Pair()
    // Only the client's own check can complete the meet here.
    await pair.world.backend.setCompletesMeetsOnArrival(false)
    try await pair.propose()
    try await pair.accept()
    try #require(await eventually { await pair.navigation(pair.a) != nil })

    let line = TestResort.directLine.map(\.coordinate)
    let waiting = try #require(Geo.interpolate(along: line, fraction: 0.3))
    let there = try #require(Geo.interpolate(along: line, fraction: 0.985))
    for _ in 0..<3 {
        await pair.world.advance(11)
        pair.a.stand(at: there)
        pair.b.stand(at: waiting)
    }
    try #require(await eventually { await activeState(pair.b)?.partner?.state == .arrived })
    await pair.a.kill()

    // Bob waits, then skis down and arrives well past the bound.
    for _ in 0..<3 {
        await pair.world.advance(50)
        pair.b.stand(at: waiting)
    }
    for _ in 0..<3 {
        await pair.world.advance(11)
        pair.b.stand(at: TestResort.base)
    }
    try #require(await eventually { await activeState(pair.b)?.arrived == true })
    let partnerFixAt = try #require(await activeState(pair.b)?.partner?.fixAt)
    #expect(pair.world.clock.now.timeIntervalSince(partnerFixAt) > MeetSession.arrivalFreshS)
    // A progress tick retries completion; it must still not happen.
    await pair.world.advance(11)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await pair.ended(pair.b) == nil)
    #expect(await pair.world.backend.calls.count { $0.name == "meet_end" && $0.user == pair.b.user } == 0)
    await pair.shutDown()
}
