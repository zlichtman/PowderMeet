import Foundation
import MountainCore
import PowderMeetAPI
import Synchronization

// The device-side services a session needs, as protocols with fakes. The live
// implementations (CoreLocation, NWPathMonitor, UIApplication) belong to the app.

/// One stream fanned out to any number of consumers.
public final class Multicast<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    public init() {}

    /// A new consumer. `initial` is delivered first, before anything sent later.
    public func stream(initial: Element? = nil) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        if let initial { continuation.yield(initial) }
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        return stream
    }

    public func send(_ element: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for target in targets { target.yield(element) }
    }

    public var consumerCount: Int { continuations.withLock { $0.count } }
}

// MARK: Clock

/// The device's time. Server expiries never use it (I-24); it ages fixes, paces
/// timers and stamps solves.
public protocol Clock: Sendable {
    var now: Date { get }
    /// Throws `CancellationError` when the task is cancelled first.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Another clock moved by a fixed offset. The demo solves on one so night-time
/// testing prices the mountain at midday; sleeping is the base clock's.
public struct ShiftedClock: Clock {
    public let base: any Clock
    public let offset: TimeInterval

    public init(base: any Clock, offset: TimeInterval) {
        self.base = base
        self.offset = offset
    }

    public var now: Date { base.now.addingTimeInterval(offset) }

    public func sleep(for seconds: TimeInterval) async throws {
        try await base.sleep(for: seconds)
    }
}

/// A clock tests move by hand. Sleepers wake when `advance` passes their deadline.
public final class FakeClock: Clock {
    private struct State {
        var now: Date
        var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<UUID> = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_768_438_800)) {
        state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }

    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = state.now.addingTimeInterval(seconds)
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in ready.keys { state.sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    public func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if seconds <= 0 { return .success(()) }
                    state.sleepers[id] = (state.now.addingTimeInterval(seconds), continuation)
                    return nil
                }
                if let resumeNow { continuation.resume(with: resumeNow) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return sleeper.continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }
}

// MARK: Location

/// One source of fixes for presence, navigation and recording. `fixes()` may be
/// called any number of times; every consumer sees every fix.
public protocol LocationProvider: Sendable {
    func fixes() -> AsyncStream<Fix>
    /// Only where the phone really is, never a position set by hand in
    /// developer testing: what live recording stores as the user's runs.
    func deviceFixes() -> AsyncStream<Fix>
    /// Starts updates. Called when the first session needs them.
    func start() async
    func stop() async
}

extension LocationProvider {
    public func deviceFixes() -> AsyncStream<Fix> { fixes() }
}

public final class FakeLocationProvider: LocationProvider {
    private let multicast = Multicast<Fix>()
    private let running = Mutex(false)

    public init() {}

    public var isRunning: Bool { running.withLock { $0 } }

    public var consumerCount: Int { multicast.consumerCount }

    public func fixes() -> AsyncStream<Fix> { multicast.stream() }

    public func start() async { running.withLock { $0 = true } }

    public func stop() async { running.withLock { $0 = false } }

    public func send(_ fix: Fix) { multicast.send(fix) }
}

/// I-14: only a routing-grade fix may start or change a route or publish presence.
public enum FixQuality {
    public static let maximumAgeS = 75.0
    public static let maximumAccuracyM = 50.0
    /// A capture time this far ahead of the device clock is not plausible.
    public static let maximumFutureSkewS = 10.0

    public static func isRoutingGrade(_ fix: Fix, now: Date) -> Bool {
        let age = now.timeIntervalSince(fix.capturedAt)
        return fix.coordinate.isValid && fix.accuracyM >= 0 && fix.accuracyM <= maximumAccuracyM
            && age < maximumAgeS && age >= -maximumFutureSkewS
    }
}

// MARK: Reachability

public protocol Reachability: Sendable {
    /// Changes only; the session assumes it starts online.
    func changes() -> AsyncStream<Bool>
}

public final class FakeReachability: Reachability {
    private let multicast = Multicast<Bool>()

    public init() {}

    public func changes() -> AsyncStream<Bool> { multicast.stream() }

    public func set(online: Bool) { multicast.send(online) }
}

// MARK: Push

public struct DeviceToken: Sendable, Hashable {
    /// Hex of the APNs token.
    public var token: String
    public var environment: PushEnvironment

    public init(token: String, environment: PushEnvironment) {
        self.token = token
        self.environment = environment
    }
}

// MARK: Background time

/// A little time from the system to finish work that started just before the
/// app was suspended, such as saving the run that ended as the phone locked.
/// The app supplies UIKit's background task; elsewhere the work simply runs.
public protocol BackgroundGrace: Sendable {
    func hold<Value: Sendable>(_ name: String, _ work: @Sendable () async -> Value) async -> Value
}

public struct NoBackgroundGrace: BackgroundGrace {
    public init() {}

    public func hold<Value: Sendable>(_ name: String, _ work: @Sendable () async -> Value) async -> Value {
        await work()
    }
}

public protocol PushRegistrar: Sendable {
    /// The APNs token, or nil when notifications are off or registration failed.
    func deviceToken() async -> DeviceToken?
    /// Every token APNs hands the phone from now on (the current one first, if
    /// any): permission granted after sign-in, an answer slower than the startup
    /// wait, and a token iOS replaces all reach the server this way.
    func tokenChanges() -> AsyncStream<DeviceToken>
}

public struct FakePushRegistrar: PushRegistrar {
    public var token: DeviceToken?
    private let changes = Multicast<DeviceToken>()

    public init(token: DeviceToken? = nil) {
        self.token = token
    }

    public func deviceToken() async -> DeviceToken? { token }

    public func tokenChanges() -> AsyncStream<DeviceToken> { changes.stream() }

    /// APNs hands the phone a new token.
    public func receive(_ token: DeviceToken) { changes.send(token) }
}

// MARK: Task bookkeeping

/// Counts the effect tasks sessions have running, by name. After sign-out it must
/// read zero, which the session tests check.
public final class TaskCensus: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    public init() {}

    public var running: Int { counts.withLock { $0.values.reduce(0, +) } }

    public var runningNames: [String] {
        counts.withLock { $0.filter { $0.value > 0 }.keys.sorted() }
    }

    func enter(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }

    func leave(_ name: String) {
        counts.withLock { counts in
            counts[name, default: 0] -= 1
            if counts[name, default: 0] <= 0 { counts[name] = nil }
        }
    }
}

/// The effect tasks one session owns, by name. Starting a name again cancels the
/// task that had it. Leaving a state cancels its names; tearing the session down
/// cancels and awaits them all. There are no generation counters: a cancelled
/// effect sees `Task.isCancelled` and posts nothing.
struct TaskBag {
    let census: TaskCensus
    private var tasks: [String: Task<Void, Never>] = [:]

    init(census: TaskCensus) {
        self.census = census
    }

    mutating func start(_ name: String, _ operation: @escaping @Sendable () async -> Void) {
        tasks[name]?.cancel()
        let census = census
        census.enter(name)
        tasks[name] = Task {
            await operation()
            census.leave(name)
        }
    }

    /// Whether an effect was started under this name and not cancelled since.
    func has(_ name: String) -> Bool {
        tasks[name] != nil
    }

    /// Cancels one effect and returns it so the caller can await its end.
    @discardableResult
    mutating func cancel(_ name: String) -> Task<Void, Never>? {
        let task = tasks.removeValue(forKey: name)
        task?.cancel()
        return task
    }

    mutating func cancelAll() -> [Task<Void, Never>] {
        let all = Array(tasks.values)
        tasks = [:]
        for task in all { task.cancel() }
        return all
    }
}
