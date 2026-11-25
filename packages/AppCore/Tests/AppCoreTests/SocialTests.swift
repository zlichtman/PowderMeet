import Foundation
import PowderMeetAPI
import Testing
@testable import AppCore

// The profile photo and friends by code, end to end against the fake server:
// a replaced or removed photo leaves no file behind, a failed save leaves no
// orphan, other people's photos leave the phone at sign-out, and a code that
// names nobody (or the user) says so instead of "try again".

private func profile(_ phone: Phone) async -> Profile? {
    if case .ready(let profile) = await phone.app.state { return profile }
    return nil
}

@Test func aPhotoReplacesTheLastAndRemovingItLeavesNoFile() async throws {
    let world = try await World()
    let me = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: me, world: world)
    try #require(await eventually { await phone.isReady() })

    try await phone.app.setAvatar(jpeg: Data([0xFF, 0xD8, 1]))
    let first = try #require(await profile(phone)?.avatarURL)
    #expect(AvatarPath.isValid(first, for: me))
    #expect(await world.backend.avatarPaths(of: me) == [first])

    try await phone.app.setAvatar(jpeg: Data([0xFF, 0xD8, 2]))
    let second = try #require(await profile(phone)?.avatarURL)
    #expect(second != first)
    #expect(await world.backend.avatarPaths(of: me) == [second], "the old photo's file is removed")

    // The save is refused after the upload: the new file goes, the old stays.
    await world.backend.failNext("profile_update", with: .server(status: 503, message: "down"))
    await #expect(throws: PowderMeetError.network(.server(status: 503))) {
        try await phone.app.setAvatar(jpeg: Data([0xFF, 0xD8, 3]))
    }
    #expect(await profile(phone)?.avatarURL == second)
    #expect(await world.backend.avatarPaths(of: me) == [second])

    try await phone.app.removeAvatar()
    #expect(await profile(phone)?.avatarURL == nil)
    #expect(await world.backend.avatarPaths(of: me).isEmpty)
    await phone.kill()
    world.cleanUp()
}

@Test func friendsPhotosLeaveThePhoneAtSignOut() async throws {
    let world = try await World()
    let me = await world.backend.addUser(displayName: "Alice")
    let bob = await world.backend.addUser(displayName: "Bob")
    let path = AvatarPath.new(for: bob)
    await world.backend.storeAvatar(Data([1, 2, 3]), at: path)
    let phone = Phone("alice", user: me, world: world)
    try #require(await eventually { await phone.isReady() })

    let avatars = phone.dependencies.avatars
    #expect(await avatars.data(for: path, from: phone.client) == Data([1, 2, 3]))
    #expect(await avatars.data(for: "../../etc/passwd", from: phone.client) == nil)
    #expect(FileManager.default.fileExists(atPath: avatars.directory.path))
    // Kept on disk: the second ask is not a download.
    let downloads = await world.backend.callCount("avatar_data")
    #expect(await avatars.data(for: path, from: phone.client) == Data([1, 2, 3]))
    #expect(await world.backend.callCount("avatar_data") == downloads)

    phone.app.send(.signOutRequested)
    try #require(await eventually { await phone.app.state == .signedOut(.userRequested) })
    #expect(!FileManager.default.fileExists(atPath: avatars.directory.path))
    await phone.kill()
    world.cleanUp()
}

@Test func aReplacedPhotoLeavesTheCacheToo() async throws {
    let world = try await World()
    let me = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: me, world: world)
    try #require(await eventually { await phone.isReady() })
    let directory = phone.dependencies.avatars.directory
    func cached(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_")).path)
    }

    try await phone.app.setAvatar(jpeg: Data([0xFF, 0xD8, 1]))
    let first = try #require(await profile(phone)?.avatarURL)
    #expect(cached(first))
    try await phone.app.setAvatar(jpeg: Data([0xFF, 0xD8, 2]))
    let second = try #require(await profile(phone)?.avatarURL)
    #expect(!cached(first) && cached(second))
    try await phone.app.removeAvatar()
    #expect(!cached(second))
    await phone.kill()
    world.cleanUp()
}

/// The photo's files go before `account_delete`; if the delete then fails,
/// the account that stays must not name a photo that is gone.
@Test func aFailedAccountDeleteUnlinksThePhotoItRemoved() async throws {
    let world = try await World()
    let me = await world.backend.addUser(displayName: "Alice")
    let phone = Phone("alice", user: me, world: world)
    try #require(await eventually { await phone.isReady() })
    try await phone.app.setAvatar(jpeg: Data([0xFF, 0xD8, 1]))

    await world.backend.failNext("account_delete", with: .server(status: 503, message: "down"))
    phone.app.send(.deleteAccountRequested)
    try #require(await eventually { await world.backend.storedProfile(of: me)?.avatarURL == nil })
    #expect(await profile(phone)?.avatarURL == nil)
    #expect(await world.backend.avatarPaths(of: me).isEmpty)
    await phone.kill()
    world.cleanUp()
}
