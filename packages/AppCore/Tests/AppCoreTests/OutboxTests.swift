import Foundation
import PowderMeetAPI
import Testing
@testable import AppCore

/// A queued upload that fails for a reason the server does not name (a captive
/// portal, a cut-off answer) stays queued; only a typed refusal sets it aside.
@Test func onlyATypedRefusalSetsAQueuedUploadAside() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let client = world.backend.client(signedInAs: user)
    let directory = world.root.appendingPathComponent("outbox", isDirectory: true)
    let rejected = directory.appendingPathComponent("rejected", isDirectory: true)
    let outbox = OutboxQueue(directory: directory)
    await outbox.enqueue(key: "event:1", user: user, .clientEvent(kind: "test", props: [:]))

    for failure: BackendError in [
        .server(status: 0, message: "secure connection failed"),
        .server(status: 400, message: "PGRST000"),
        .decoding("truncated"),
        .notFound,
    ] {
        await world.backend.failNext("client_event", with: failure)
        await outbox.drain(backend: client, user: user)
        #expect(await outbox.pending.count == 1, "set aside on \(failure)")
    }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))

    await world.backend.failNext("client_event", with: .invalid)
    await outbox.drain(backend: client, user: user)
    #expect(await outbox.pending.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: rejected.path).count == 1)
}

/// A deleted account's queued and refused uploads leave the phone; another
/// account's queue on the same phone stays.
@Test func discardingAUserRemovesOnlyTheirUploads() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let alice = await world.backend.addUser(displayName: "Alice")
    let bob = await world.backend.addUser(displayName: "Bob")
    let directory = world.root.appendingPathComponent("outbox", isDirectory: true)
    let rejected = directory.appendingPathComponent("rejected", isDirectory: true)
    let corrupt = directory.appendingPathComponent("corrupt", isDirectory: true)
    let outbox = OutboxQueue(directory: directory)
    for user in [alice, bob] {
        await outbox.enqueue(key: "refused", user: user, .clientEvent(kind: "test", props: [:]))
        await world.backend.failNext("client_event", with: .invalid)
        await outbox.drain(backend: world.backend.client(signedInAs: user), user: user)
        await outbox.enqueue(key: "queued", user: user, .clientEvent(kind: "test", props: [:]))
    }
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: corrupt.appendingPathComponent("broken.json"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: rejected.path).count == 2)

    await outbox.discard(user: alice)
    #expect(await outbox.pending.map(\.user) == [bob])
    #expect(try FileManager.default.contentsOfDirectory(atPath: rejected.path).count == 1)
    #expect(!FileManager.default.fileExists(atPath: corrupt.path))
    // What is on disk agrees after a relaunch.
    #expect(await OutboxQueue(directory: directory).pending.map(\.user) == [bob])
}

@Test func aDeletedAccountsRecordingFileIsRemoved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("recording-\(UUID().uuidString)", isDirectory: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) } catch {}
    }
    let user = UUID(), other = UUID()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for id in [user, other] {
        try Data("{}".utf8).write(to: directory.appendingPathComponent("\(id.uuidString.lowercased()).json"))
    }
    try LiveRecorder.discardRecording(of: user, in: directory)
    try LiveRecorder.discardRecording(of: user, in: directory)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
        == ["\(other.uuidString.lowercased()).json"])
}

/// Deleting the account removes its waiting uploads with it; signing out
/// keeps them for when the account signs back in.
@Test func accountDeletionDiscardsQueuedUploadsAndSignOutKeepsThem() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    for deleting in [false, true] {
        let user = await world.backend.addUser(displayName: deleting ? "Del" : "Out")
        let phone = Phone(deleting ? "del" : "out", user: user, world: world)
        try #require(await eventually { await phone.isReady() })
        // The upload hangs until the session's drain loop is cancelled.
        await world.backend.pause("client_event")
        await phone.dependencies.outbox.enqueue(key: "event:1", user: user, .clientEvent(kind: "test", props: [:]))
        phone.app.send(deleting ? .deleteAccountRequested : .signOutRequested)
        try #require(await eventually {
            await phone.app.state == .signedOut(deleting ? .accountDeleted : .userRequested)
        })
        await world.backend.resume("client_event")
        #expect(await phone.dependencies.outbox.pending.count == (deleting ? 0 : 1))
        await phone.kill()
    }
}

/// A queued upload stuck timing out (a long track on a weak signal) does not
/// hold back the meet progress queued after it.
@Test func meetProgressGoesAheadOfAStuckUpload() async throws {
    let world = try await World()
    defer { world.cleanUp() }
    let user = await world.backend.addUser(displayName: "Alice")
    let client = world.backend.client(signedInAs: user)
    let outbox = OutboxQueue(directory: world.root.appendingPathComponent("outbox", isDirectory: true))
    await outbox.enqueue(key: "event:1", user: user, .clientEvent(kind: "test", props: [:]))
    let meet = UUID()
    await outbox.enqueue(
        key: "progress:\(meet.uuidString)", user: user,
        .progress(.init(meetID: meet, etaS: 60, etaSdS: 10, remainingM: 300, state: .navigating, fixAt: world.clock.now))
    )
    await world.backend.failNext("client_event", with: .timeout)
    await outbox.drain(backend: client, user: user)
    #expect(await world.backend.callCount("meet_progress_update") == 1)
}
