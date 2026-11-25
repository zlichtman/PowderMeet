import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

// MARK: Opening the resort the phone is in (M3)

private func mapped(_ id: String, _ box: BoundingBox) -> PublishedResort {
    PublishedResort(
        id: id, name: id.capitalized, timezone: "America/Denver", bbox: box,
        bundleID: BundleID(String(repeating: "a", count: 64))
    )
}

// The catalog's own boxes, which overlap at the top of the two canyons.
private let alta = mapped("alta", BoundingBox(minLon: -111.665, minLat: 40.57, maxLon: -111.615, maxLat: 40.61))
private let snowbird = mapped("snowbird", BoundingBox(minLon: -111.69, minLat: 40.555, maxLon: -111.63, maxLat: 40.605))
private let now = Date(timeIntervalSince1970: 1_768_438_800)

private func fix(_ lon: Double, _ lat: Double, accuracyM: Double = 10, ageS: TimeInterval = 0) -> Fix {
    Fix(coordinate: Coordinate(lon: lon, lat: lat), accuracyM: accuracyM, capturedAt: now.addingTimeInterval(-ageS))
}

private func decide(
    _ fix: Fix, current: String? = nil, userPicked: Bool = false, meet: Bool = false, suppressed: Bool = false
) -> ResortArrival.Decision {
    ResortArrival.decide(
        fix: fix, resorts: [alta, snowbird], current: current, userPicked: userPicked, meetUnderWay: meet,
        suppressed: suppressed
    )
}

@Test func arrivalOpensTheOneResortThePhoneIsInAndAsksWhenBoxesOverlap() {
    let altaBase = fix(-111.62, 40.59)
    let snowbirdBase = fix(-111.68, 40.58)
    let both = fix(-111.64, 40.59)
    #expect(decide(altaBase) == .open("alta"))
    #expect(decide(snowbirdBase) == .open("snowbird"))
    #expect(decide(both) == .ask(["alta", "snowbird"]))
    #expect(decide(fix(-105, 39)) == .stay)
    // Already there: nothing to do, also when another box overlaps.
    #expect(decide(both, current: "snowbird") == .stay)
    // The restored resort is not a pick, so standing elsewhere replaces it.
    #expect(decide(altaBase, current: "snowbird") == .open("alta"))
}

@Test func arrivalNeverOverridesTheUserAMeetOrDeveloperTesting() {
    let altaBase = fix(-111.62, 40.59)
    #expect(decide(altaBase, userPicked: true) == .stay)
    #expect(decide(altaBase, meet: true) == .stay)
    #expect(decide(altaBase, suppressed: true) == .stay)
    // A resort with no map cannot be opened.
    var unmapped = alta
    unmapped.bundleID = nil
    #expect(ResortArrival.decide(
        fix: altaBase, resorts: [unmapped], current: nil, userPicked: false, meetUnderWay: false, suppressed: false
    ) == .stay)
}

@Test func arrivalWaitsForAUsableFix() {
    #expect(ResortArrival.isUsable(fix(-111.62, 40.59), now: now))
    #expect(!ResortArrival.isUsable(fix(-111.6, 40.59, accuracyM: 1_500), now: now))
    #expect(!ResortArrival.isUsable(fix(-111.6, 40.59, ageS: 600), now: now))
}

// MARK: Prefetching meet options (D1)

@Test func prefetchSolvesTheNearestUnansweredFriendAndSpacesItsJobs() {
    var prefetch = MeetPrefetch()
    let me = Coordinate(lon: -122.95, lat: 50.10)
    let profile = SkierProfile.preset(.intermediate, userID: UUID())
    func friend(_ lon: Double, ageS: TimeInterval = 0, resort: String = "r") -> Presence {
        Presence(userID: UUID(), resortID: resort, lon: lon, lat: 50.10, capturedAt: now.addingTimeInterval(-ageS))
    }
    let near = friend(-122.951), far = friend(-122.90)
    let stale = friend(-122.9505, ageS: 600), elsewhere = friend(-122.9502, resort: "other")
    let all = [far, stale, elsewhere, near]
    func next() -> MeetPrefetch.Key? {
        prefetch.next(friends: all, resortID: "r", mine: me, profile: profile, at: now, now: now)
    }

    #expect(next()?.friend == near.userID)
    let options = MeetOptions(options: [], statusFreshness: .unavailable, degraded: false)
    prefetch.store(options, for: next()!, solvedInS: 3, now: now)
    // A slow solve keeps the next job four times its length away.
    #expect(prefetch.notBefore == now.addingTimeInterval(12))
    #expect(next()?.friend == far.userID)
    prefetch.store(nil, for: next()!, solvedInS: 0.1, now: now)
    #expect(prefetch.notBefore == now.addingTimeInterval(MeetPrefetch.minimumGapS))
    // Both answered (one with nothing): no job until someone moves.
    #expect(next() == nil)
    let moved = prefetch.next(
        friends: all, resortID: "r", mine: Coordinate(lon: -122.95, lat: 50.12), profile: profile, at: now, now: now
    )
    #expect(moved?.friend == near.userID)

    prefetch.forget(near.userID)
    #expect(prefetch.options(for: MeetPrefetch.Key(
        friend: near.userID, mine: me, theirs: Coordinate(lon: near.lon, lat: near.lat), profile: profile, at: now
    )) == nil)
}

/// Tapping a friend shows options at once. The friend's
/// profile read is held, so only prefetched options can be on screen.
@Test func tappingAFriendShowsPrefetchedOptionsBeforeAnyRead() async throws {
    let pair = try await Pair()
    let resort = try #require(await pair.a.resort())
    try #require(await eventually { await resort.hasPrefetchedOptions(for: pair.b.user) })

    await pair.world.backend.pause("profile")
    await pair.world.backend.pause("pace_model")
    resort.send(.proposeRequested(friend: pair.b.user))
    try #require(await eventually {
        if case .proposing(let proposing) = await pair.a.meetState() { return proposing.options != nil }
        return false
    })
    await pair.world.backend.resume("profile")
    await pair.world.backend.resume("pace_model")
    await pair.shutDown()
}

// MARK: Clearing presence (M2)

@Test func presenceIsClearedOnLeavingTheResortAndOnSignOut() async throws {
    let pair = try await Pair()
    let backend = pair.world.backend
    try #require(await eventually { await backend.storedPresence(of: pair.a.user) != nil })

    pair.a.app.send(.resortCleared)
    try #require(await eventually { await backend.storedPresence(of: pair.a.user) == nil })

    pair.a.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await pair.a.resortIsReady() })
    await pair.world.advance(3)
    pair.a.stand(at: TestResort.top)
    try #require(await eventually { await backend.storedPresence(of: pair.a.user) != nil })

    pair.a.app.send(.signOutRequested)
    try #require(await eventually { await pair.a.app.state == .signedOut(.userRequested) })
    #expect(await eventually { await backend.storedPresence(of: pair.a.user) == nil })
    await pair.shutDown()
}
