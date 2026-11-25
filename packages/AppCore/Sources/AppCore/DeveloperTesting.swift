import Foundation
import MountainCore
import Synchronization

// Developer testing (`specs/07-CLIENT.md` section 8): the pieces Debug and
// TestFlight builds put in `Dependencies` so a tester can pretend the time and
// where they stand. Nothing here decides who may use them; the app's gate does,
// and an App Store build never builds them.

// MARK: Pretend time

/// The solve clock developer testing moves, so a meet can be tried at 10:30
/// mountain time from a sofa at midnight. Only `Dependencies.solveClock` is one:
/// fix ageing, timers and server expiries keep the real clock. Sleeping is the
/// base clock's.
public final class AdjustableClock: Clock {
    private let base: any Clock
    private let offsetS: Mutex<TimeInterval>

    public init(base: any Clock = SystemClock(), offset: TimeInterval = 0) {
        self.base = base
        offsetS = Mutex(offset)
    }

    /// Seconds added to the base clock; 0 is real time.
    public var offset: TimeInterval { offsetS.withLock { $0 } }

    /// Takes effect at the next solve; a solve already made keeps its instant.
    public func setOffset(_ value: TimeInterval) {
        offsetS.withLock { $0 = value }
    }

    public var now: Date { base.now.addingTimeInterval(offset) }

    public func sleep(for seconds: TimeInterval) async throws {
        try await base.sleep(for: seconds)
    }

    /// The offset that makes the clock read `minuteOfDay` minutes after local
    /// midnight today in `timeZone`. Earlier than now is negative.
    public static func offset(toMinuteOfDay minuteOfDay: Int, in timeZone: TimeZone, now: Date) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: now)
        return midnight.addingTimeInterval(TimeInterval(minuteOfDay * 60)).timeIntervalSince(now)
    }

    /// Minutes after local midnight in `timeZone` at `date`.
    public static func minuteOfDay(_ date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

// MARK: Teleport

/// Where this phone is: its own fixes, or a place set by hand ("teleport"),
/// which wins until it is released. A placed position is reported every few
/// seconds, as a phone standing still reports, and every fix is newer than the
/// last one sent, so sessions keep routing from it (I-14, I-19). Fixes from the
/// base provider are dropped while a place is set.
///
/// The demo has no base provider: it always stands where it was put.
public final class PlaceableLocationProvider: LocationProvider {
    public static let intervalS = 5.0
    /// Placed fixes claim this accuracy, inside routing grade.
    public static let placedAccuracyM = 8.0

    private struct State {
        var placed: Coordinate?
        var last: Coordinate?
        var lastSentAt: Date?
        var ticker: Task<Void, Never>?
        var relay: Task<Void, Never>?
    }

    private let base: (any LocationProvider)?
    private let clock: any Clock
    private let cast = Multicast<Fix>()
    private let state = Mutex(State())

    /// - Parameter clock: stamps placed fixes; the sessions' own clock.
    public init(base: (any LocationProvider)?, clock: any Clock = SystemClock()) {
        self.base = base
        self.clock = clock
        guard let base else { return }
        // Subscribed for the provider's whole life: recording and meets keep
        // fixes coming while no resort is open.
        let fixes = base.fixes()
        let relay = Task { [weak self] in
            for await fix in fixes {
                self?.relay(fix)
            }
        }
        state.withLock { $0.relay = relay }
    }

    deinit {
        state.withLock { state in
            state.relay?.cancel()
            state.ticker?.cancel()
        }
    }

    public func fixes() -> AsyncStream<Fix> { cast.stream() }

    /// The base provider's own fixes, placed or not; none in the demo, which
    /// has no phone position. A teleport or a rehearsal is never recorded as a run.
    public func deviceFixes() -> AsyncStream<Fix> {
        base?.deviceFixes() ?? AsyncStream { $0.finish() }
    }

    public func start() async { await base?.start() }

    public func stop() async { await base?.stop() }

    /// The place set by hand, or nil while the phone's own fixes are used.
    public var placed: Coordinate? { state.withLock { $0.placed } }

    /// The last position sent, placed or not.
    public var lastCoordinate: Coordinate? { state.withLock { $0.last } }

    /// Stands here from now on, reported at once and then every `intervalS`.
    public func place(at coordinate: Coordinate) {
        let old = state.withLock { state -> Task<Void, Never>? in
            state.placed = coordinate
            let old = state.ticker
            state.ticker = nil
            return old
        }
        old?.cancel()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.sendPlaced()
                do {
                    try await Task.sleep(for: .seconds(Self.intervalS))
                } catch {
                    return
                }
            }
        }
        let stale = state.withLock { state -> Task<Void, Never>? in
            // Another place() may have run meanwhile; the newest ticker wins.
            let stale = state.ticker
            state.ticker = ticker
            return stale
        }
        stale?.cancel()
    }

    /// Back to the phone's own fixes, from the next one it reports.
    public func release() {
        let ticker = state.withLock { state -> Task<Void, Never>? in
            state.placed = nil
            defer { state.ticker = nil }
            return state.ticker
        }
        ticker?.cancel()
    }

    private func relay(_ fix: Fix) {
        let send = state.withLock { state -> Bool in
            guard state.placed == nil else { return false }
            state.last = fix.coordinate
            state.lastSentAt = max(state.lastSentAt ?? fix.capturedAt, fix.capturedAt)
            return true
        }
        if send { cast.send(fix) }
    }

    private func sendPlaced() {
        let now = clock.now
        let fix = state.withLock { state -> Fix? in
            guard let placed = state.placed else { return nil }
            // Strictly newer than anything sent before, real or placed.
            var at = now
            if let last = state.lastSentAt, at <= last { at = last.addingTimeInterval(0.001) }
            state.lastSentAt = at
            state.last = placed
            return Fix(coordinate: placed, accuracyM: Self.placedAccuracyM, capturedAt: at)
        }
        if let fix { cast.send(fix) }
    }
}

// MARK: Placing on the map

/// Turns a tap on the map into a place a skier can stand: the nearest point on
/// a run or lift, so the solver can route from it.
public enum DeveloperPlacement {
    /// A tap farther than this from every run and lift is refused.
    public static let snapRadiusM = 250.0

    /// The nearest point on the mountain's graph, or nil when the tap is off the
    /// mountain.
    public static func snap(_ point: Coordinate, in bundle: ResortBundle) -> Coordinate? {
        var best: PolylineProjection?
        for edge in bundle.graph.edges {
            guard let projection = Geo.project(point, onto: edge.coordinates) else { continue }
            if best.map({ projection.distanceM < $0.distanceM }) ?? true { best = projection }
        }
        guard let best, best.distanceM <= snapRadiusM else { return nil }
        return best.closest
    }
}
