import Foundation
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

// A returning user's launch: straight to `ready` and the map from what is on
// disk, with the server still the authority once it answers.

/// Signs a user in, opens the resort and kills the app, leaving its caches.
private func firstRun(_ world: World) async throws -> Phone {
    let user = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: user, world: world, push: true)
    try #require(await eventually { await phone.isReady() })
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await phone.resortIsReady() })
    try #require(await eventually {
        phone.dependencies.launch.snapshot(for: user)?.profile.currentResortID == TestResort.id
    })
    await phone.kill()
    return phone
}

@Test func aReturningUserReachesTheMapBeforeTheNetworkAnswers() async throws {
    let world = try await World()
    let first = try await firstRun(world)
    // The profile changes on the server while the app is closed.
    _ = try await world.backend.client(signedInAs: first.user)
        .profileUpdate(ProfilePatch().displayName("Alice B"))

    // Relaunch with every startup read held: nothing from the network arrives.
    await world.backend.pause("profile")
    await world.backend.pause("published_resorts")
    let phone = Phone("alice", user: first.user, world: world, push: true)
    try #require(await eventually {
        if case .ready(let profile) = await phone.app.state {
            return profile.displayName == "Alice" && profile.currentResortID == TestResort.id
        }
        return false
    })
    // The app reopens the cached resort, and its bundle comes from disk.
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await phone.resortIsReady() })
    #expect(await world.backend.calls.filter { $0.name == "bundle_data" }.count == 1)

    // The server answers: its profile replaces the cached one.
    await world.backend.resume("profile")
    await world.backend.resume("published_resorts")
    try #require(await eventually {
        if case .ready(let profile) = await phone.app.state { return profile.displayName == "Alice B" }
        return false
    })
    #expect(phone.dependencies.launch.snapshot(for: first.user)?.profile.displayName == "Alice B")

    await phone.kill()
    world.cleanUp()
}

/// The launch's own first foreground arrives while the startup load is still
/// running; restarting it then left the live connection unjoined.
@Test func theFirstForegroundDoesNotRestartARunningStartup() async throws {
    let world = try await World()
    let first = try await firstRun(world)
    let subscribed = await world.backend.callCount("subscribe_user")
    let loaded = await world.backend.callCount("meet_current")

    await world.backend.pause("profile")
    let phone = Phone("alice", user: first.user, world: world, push: true)
    try #require(await eventually { await phone.isReady() })
    try #require(await eventually { await world.backend.callCount("subscribe_user") == subscribed + 1 })
    phone.app.send(.foregrounded)
    // A restart would subscribe again straight away; give it the chance.
    try await Task.sleep(for: .milliseconds(300))
    #expect(await world.backend.callCount("subscribe_user") == subscribed + 1)
    await world.backend.resume("profile")
    // The held load runs to its end: `meet_current` is its last read.
    try #require(await eventually { await world.backend.callCount("meet_current") >= loaded + 1 })
    #expect(await world.backend.callCount("subscribe_user") == subscribed + 1)
    #expect(phone.dependencies.census.runningNames.contains("realtime"))

    await phone.kill()
    world.cleanUp()
}

@Test func aCachedProfileTheServerNoLongerKnowsDropsToSignIn() async throws {
    let world = try await World()
    let first = try await firstRun(world)
    try await world.backend.client(signedInAs: first.user).accountDelete()

    let phone = Phone("alice", user: first.user, world: world)
    try #require(await eventually { await phone.app.state == .signedOut(.sessionExpired) })
    #expect(phone.dependencies.launch.snapshot(for: first.user) == nil)
    #expect(await phone.app.resortSession == nil)
    #expect(phone.dependencies.census.running == 0, "still running: \(phone.dependencies.census.runningNames)")

    await phone.kill()
    world.cleanUp()
}

@Test func aCachedLaunchWithoutANetworkStaysUsableAndLoadsWhenItReturns() async throws {
    let world = try await World()
    let first = try await firstRun(world)
    let registered = await world.backend.callCount("device_token_register")

    await world.backend.setOnline(false)
    let phone = Phone("alice", user: first.user, world: world, push: true)
    try #require(await eventually { await phone.isReady() })
    phone.app.send(.resortSelected(TestResort.id))
    try #require(await eventually { await phone.resortIsReady() })
    // The startup load has been tried and has failed; the session is not `failed`.
    try #require(await eventually {
        await world.backend.calls.filter { $0.name == "subscribe_user" }.count >= 2
    })
    #expect(await phone.isReady())

    // The connection comes back: startup runs to its end this time.
    await world.backend.setOnline(true)
    phone.reachability.set(online: false)
    phone.reachability.set(online: true)
    try #require(await eventually {
        await world.backend.callCount("device_token_register") == registered + 1
    })
    #expect(await phone.isReady())

    await phone.kill()
    world.cleanUp()
}

@Test func aSnapshotForAnotherUserIsNeverUsed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launch-cache-\(UUID().uuidString)", isDirectory: true)
    let cache = LaunchCache(directory: directory)
    let alice = UUID(), bob = UUID()
    cache.save(LaunchSnapshot(
        profile: Profile(id: alice, displayName: "Alice", baselineSpeeds: ["blue": 8]),
        savedAt: Date(timeIntervalSince1970: 1_768_438_800)
    ))
    #expect(cache.snapshot(for: alice)?.profile.displayName == "Alice")
    #expect(cache.snapshot(for: bob) == nil)
    // Reading as someone else removed it: nothing of Alice's is left on the phone.
    #expect(cache.snapshot(for: alice) == nil)
    try FileManager.default.removeItem(at: directory)
}
