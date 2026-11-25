import CZlib
import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// A small resort that passes `BundleLoader`: a chair from base to top, a direct
/// blue run down, and a longer green way down in two edges through a junction.
enum TestResort {
    static let id = "test-resort"
    static let base = Node(id: "n1", lon: -122.95, lat: 50.10, eleM: 700, kind: .base)
    static let top = Node(id: "n2", lon: -122.95, lat: 50.11, eleM: 1_100, kind: .liftTop)
    static let junction = Node(id: "n3", lon: -122.93, lat: 50.105, eleM: 900, kind: .junction)
    static let baseRendezvous: RendezvousID = "test-base"
    static let directRun: GroupID = "trail:test-run"
    static let longWay: GroupID = "trail:long-way"

    /// The direct run bows west so it never lies on top of the lift line.
    static let directLine = [
        GeoPoint(lon: top.lon, lat: top.lat, eleM: 1_100),
        GeoPoint(lon: -122.955, lat: 50.105, eleM: 900),
        GeoPoint(lon: base.lon, lat: base.lat, eleM: 700),
    ]

    static func point(_ node: Node) -> GeoPoint { GeoPoint(lon: node.lon, lat: node.lat, eleM: node.eleM) }

    static func document(id: String = TestResort.id, withDirectRunRendezvous: Bool = true) -> BundleDocument {
        func length(_ line: [GeoPoint]) -> Double { Geo.lengthM(line.map(\.coordinate)) }
        let liftLine = [point(base), point(top)]
        let upper = [point(top), point(junction)]
        let lower = [point(junction), point(base)]
        return BundleDocument(
            resortID: id, name: "Test Resort", timezone: "America/Vancouver",
            bbox: BoundingBox(minLon: -123, minLat: 50, maxLon: -122.9, maxLat: 50.2),
            center: Coordinate(lon: -122.95, lat: 50.105),
            source: .init(
                extractID: "osm-test", osmExtractAt: Date(timeIntervalSince1970: 1_760_000_000),
                manifestVersion: 1
            ),
            builtAt: Date(timeIntervalSince1970: 1_760_000_100),
            nodes: [base, top, junction],
            edges: [
                Edge(
                    id: "w10:0", from: "n1", to: "n2", kind: .lift, group: "lift:test-chair",
                    name: "Test Chair", geometry: liftLine, lengthM: length(liftLine), verticalM: 400,
                    lift: LiftInfo(type: .chair, rideS: 420, capacityPPH: 2_400)
                ),
                Edge(
                    id: "w20:0", from: "n2", to: "n1", kind: .run, group: directRun,
                    name: "Test Run", difficulty: .blue, geometry: directLine,
                    lengthM: length(directLine), verticalM: -400, gradeMaxDeg: 20,
                    groomedDefault: true, aspectDeg: 180
                ),
                Edge(
                    id: "w30:0", from: "n2", to: "n3", kind: .run, group: longWay,
                    name: "Long Way", difficulty: .green, geometry: upper, lengthM: length(upper),
                    verticalM: -200, gradeMaxDeg: 12, groomedDefault: true, aspectDeg: 135
                ),
                Edge(
                    id: "w30:1", from: "n3", to: "n1", kind: .run, group: longWay,
                    name: "Long Way", difficulty: .green, geometry: lower, lengthM: length(lower),
                    verticalM: -200, gradeMaxDeg: 12, groomedDefault: true, aspectDeg: 225
                ),
            ],
            groups: [
                Group(id: "lift:test-chair", kind: .lift, name: "Test Chair", edgeIDs: ["w10:0"]),
                Group(id: directRun, kind: .trail, name: "Test Run", difficulty: .blue, edgeIDs: ["w20:0"]),
                Group(id: longWay, kind: .trail, name: "Long Way", difficulty: .green,
                      edgeIDs: ["w30:0", "w30:1"]),
            ],
            rendezvous: [
                Rendezvous(id: baseRendezvous, nodeID: "n1", kind: .liftBase, name: "Test Base",
                           confidence: 0.95, quality: 0.9, amenities: ["food"]),
            ]
        )
    }

    /// The stored bytes and their identity, as the pipeline would publish them.
    static func stored(id: String = TestResort.id) throws -> (data: Data, bundleID: BundleID) {
        let data = gzip(try document(id: id).encoded())
        return (data, try #require(BundleID(SHA256.hex(data))))
    }

    static func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        let status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        precondition(status == Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))) + 64)
        let written: Int = data.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { buffer in
                stream.next_in = UnsafeMutablePointer(
                    mutating: input.bindMemory(to: UInt8.self).baseAddress
                )
                stream.avail_in = UInt32(input.count)
                stream.next_out = buffer.baseAddress
                stream.avail_out = UInt32(buffer.count)
                precondition(deflate(&stream, Z_FINISH) == Z_STREAM_END)
                return buffer.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<written])
    }
}

/// Polls until the condition holds. Sessions are eventually consistent by design
/// (events are hints), so tests wait on outcomes, never on a number of turns.
func eventually(
    timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        do {
            try await Task.sleep(nanoseconds: 2_000_000)
        } catch {
            return false
        }
    }
    return await condition()
}

/// The shared server plus one published resort.
struct World {
    let backend: FakeBackend
    let clock: FakeClock
    let root: URL

    init() async throws {
        let start = Date(timeIntervalSince1970: 1_768_438_800)
        backend = FakeBackend(now: start)
        clock = FakeClock(now: start)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcore-tests-\(UUID().uuidString)", isDirectory: true)
        try await publish(TestResort.id)
    }

    func publish(_ resortID: String) async throws {
        let stored = try TestResort.stored(id: resortID)
        await backend.addResort(PublishedResort(id: resortID, name: resortID, timezone: "America/Vancouver"))
        await backend.publishBundle(
            resortID: resortID, bundleID: stored.bundleID, data: stored.data,
            rendezvousIDs: [TestResort.baseRendezvous]
        )
    }

    func cleanUp() {
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            Issue.record("could not remove \(root.path): \(error)")
        }
    }

    /// Moves the device and server clocks together.
    func advance(_ seconds: TimeInterval) async {
        await backend.advance(by: seconds)
        clock.advance(by: seconds)
    }

    func status(closed: [GroupID]) -> ResortStatus {
        var groups: [GroupID: GroupState] = [:]
        for group in closed { groups[group] = .closed }
        return ResortStatus(
            resortID: TestResort.id, observedAt: clock.now, expiresAt: clock.now.addingTimeInterval(20 * 60),
            source: .epic, groups: groups
        )
    }
}

/// One phone: its own client, location and cache, and the session running on it.
final class Phone: Sendable {
    let user: UUID
    let client: FakeBackendClient
    let location = FakeLocationProvider()
    let reachability = FakeReachability()
    let dependencies: Dependencies
    let app: AppSession
    let task: Task<Void, Never>
    private let world: World

    static let pushToken = String(repeating: "ab", count: 32)

    /// `name` keeps the phone's caches apart and survives a "relaunch".
    init(_ name: String, user: UUID, world: World, signedIn: Bool = true, push: Bool = false) {
        self.user = user
        self.world = world
        client = world.backend.client(signedInAs: signedIn ? user : nil)
        dependencies = Dependencies(
            backend: client, location: location, clock: world.clock, reachability: reachability,
            push: FakePushRegistrar(
                token: push ? DeviceToken(token: Phone.pushToken, environment: .development) : nil
            ),
            cacheDirectory: world.root.appendingPathComponent(name, isDirectory: true), appBuild: "test"
        )
        let app = AppSession(dependencies: dependencies)
        self.app = app
        task = Task { await app.run() }
    }

    /// Kills the app: the run loop is cancelled and everything under it ends.
    func kill() async {
        task.cancel()
        await task.value
    }

    func isReady() async -> Bool {
        if case .ready = await app.state { return true }
        return false
    }

    func resort() async -> ResortSession? { await app.resortSession }

    func resortIsReady() async -> Bool {
        guard let resort = await app.resortSession else { return false }
        if case .ready = await resort.state { return true }
        return false
    }

    func meet() async -> MeetSession? { await app.resortSession?.meetSession }

    func meetState() async -> MeetSession.State? { await meet()?.state }

    /// A fix at this coordinate, captured now.
    func stand(at coordinate: Coordinate) {
        location.send(Fix(coordinate: coordinate, accuracyM: 5, capturedAt: world.clock.now))
    }

    func stand(at node: Node) { stand(at: node.coordinate) }
}

/// Two friends, both signed in, at the resort, each knowing where the other is:
/// `a` at the top, `b` at the base.
struct Pair {
    let world: World
    let a: Phone
    let b: Phone

    init() async throws {
        world = try await World()
        let alice = await world.backend.addUser(displayName: "Alice")
        let bob = await world.backend.addUser(displayName: "Bob")
        await world.backend.makeFriends(alice, bob)
        a = Phone("alice", user: alice, world: world)
        b = Phone("bob", user: bob, world: world)
        try await arrive()
    }

    private func arrive() async throws {
        for phone in [a, b] {
            try #require(await eventually { await phone.isReady() })
            phone.app.send(.resortSelected(TestResort.id))
            try #require(await eventually { await phone.resortIsReady() })
            // The server fans positions out to friends looking at this resort.
            try #require(await eventually {
                await world.backend.storedProfile(of: phone.user)?.currentResortID == TestResort.id
            })
        }
        a.stand(at: TestResort.top)
        b.stand(at: TestResort.base)
        try #require(await eventually { await a.resort()?.friends[b.user] != nil })
        try #require(await eventually { await b.resort()?.friends[a.user] != nil })
    }

    /// `a` proposes the base to `b` and waits until the proposal is out.
    func propose() async throws {
        let resort = try #require(await a.resort())
        resort.send(.proposeRequested(friend: b.user))
        try #require(await eventually {
            if case .proposing(let proposing) = await a.meetState() { return proposing.options != nil }
            return false
        })
        guard case .proposing(let proposing) = await a.meetState(),
              let index = proposing.options?.options.firstIndex(where: {
                  $0.rendezvous == TestResort.baseRendezvous
              }) else {
            Issue.record("the base is not among the options")
            return
        }
        let meet = try #require(await a.meet())
        meet.send(.optionPicked(index))
        meet.send(.sent)
        try #require(await eventually {
            if case .proposed = await a.meetState() { return true }
            return false
        })
    }

    /// `b` waits for the invitation and its own route, then accepts.
    func accept() async throws {
        try #require(await eventually {
            if case .incoming(let incoming) = await b.meetState() { return incoming.ownRoute != nil }
            return false
        })
        try #require(await b.meet()).send(.accepted)
        try #require(await eventually {
            if case .active = await b.meetState() { return true }
            return false
        })
    }

    func navigation(_ phone: Phone) async -> MeetSession.Navigation? {
        if case .active(let active) = await phone.meetState() { return active.navigation }
        return nil
    }

    func ended(_ phone: Phone) async -> MeetSession.Ended? {
        if case .ended(let ended) = await phone.meetState() { return ended }
        return nil
    }

    func shutDown() async {
        await a.kill()
        await b.kill()
        world.cleanUp()
    }
}
