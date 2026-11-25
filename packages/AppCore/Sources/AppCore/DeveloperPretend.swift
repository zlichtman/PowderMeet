import Foundation
import MountainCore

// Developer testing (`specs/07-CLIENT.md` section 8): where dev people start,
// the solver-time presets and the pretend weather. Pure values, so the Dev page
// stays a projection and a test can pin each one down.

// MARK: Starting spots

/// Spots a skier could stand on, spread across the mountain, for this phone's
/// teleport and the dev people when they are switched on. Seeded, so the same
/// mountain and shuffle give the same spots on every launch.
public enum DeveloperSpots {
    /// The seed for a mountain: stable across launches (`hashValue` is not).
    public static func seed(for resortID: String, shuffle: Int = 0) -> UInt64 {
        // FNV-1a.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in resortID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash &+ UInt64(truncatingIfNeeded: shuffle) &* 0x9e37_79b9_7f4a_7c15
    }

    /// `count` distinct spots, or fewer on a mountain with fewer places. Meeting
    /// places and lift tops come first, where a skier waits; any graph node
    /// fills in on a small map. Each pick is random among the candidates at
    /// least half as far from those already chosen as the farthest one, so
    /// the spots never bunch in one corner.
    public static func pick(_ count: Int, in bundle: ResortBundle, seed: UInt64) -> [Coordinate] {
        let nodes = bundle.graph.nodes
        var preferred = Set(bundle.rendezvous.map(\.nodeID))
        for edge in bundle.graph.edges where edge.kind == .lift { preferred.insert(edge.to) }
        var ids = preferred.filter { nodes[$0] != nil }
        if ids.count < count { ids.formUnion(nodes.keys) }
        // Sorted, since a set's order changes from launch to launch.
        var candidates = ids.sorted().compactMap { nodes[$0]?.coordinate }
        var generator = SplitMix64(seed: seed)
        var chosen: [Coordinate] = []
        while chosen.count < count, !candidates.isEmpty {
            let index: Int
            if chosen.isEmpty {
                index = Int(generator.next() % UInt64(candidates.count))
            } else {
                let distances = candidates.map { candidate in
                    chosen.map { Geo.haversineM($0, candidate) }.min() ?? 0
                }
                let farthest = distances.max() ?? 0
                let eligible = distances.indices.filter { distances[$0] >= farthest / 2 }
                index = eligible[Int(generator.next() % UInt64(eligible.count))]
            }
            chosen.append(candidates.remove(at: index))
        }
        return chosen
    }
}

/// A small seeded generator, the same sequence on every platform and launch.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

// MARK: Solver time

/// When the mountain's lifts run on one day, as the solver reads their hours.
public struct LiftDay: Sendable, Hashable {
    /// The first lift's opening, minutes after local midnight.
    public let openMinute: Int
    /// The last lift's closing; a lift stops loading at this minute.
    public let closeMinute: Int

    /// The solver's window for a lift with no hours on the map
    /// (`MeetSolver` `Traversal.Lift.fallbackOpenMinute` and `fallbackCloseMinute`).
    static let fallbackOpenMinute = 7 * 60
    static let fallbackCloseMinute = 21 * 60

    /// The day's span over every lift, on an ISO weekday (1 = Monday); nil on
    /// a mountain with no lifts or none running that day.
    public static func of(_ bundle: ResortBundle, weekday: Int) -> LiftDay? {
        var open: Int?
        var close: Int?
        for edge in bundle.graph.edges {
            guard let lift = edge.lift else { continue }
            let windows = lift.operatingHours.isEmpty
                ? [(fallbackOpenMinute, fallbackCloseMinute)]
                : lift.operatingHours.filter { $0.days.contains(weekday) }.map { ($0.openMinute, $0.closeMinute) }
            for (from, to) in windows {
                open = min(open ?? from, from)
                close = max(close ?? to, to)
            }
        }
        guard let open, let close, open < close else { return nil }
        return LiftDay(openMinute: open, closeMinute: close)
    }

    /// At least one lift is loading at this minute, by the same half-open
    /// windows the solver uses (open at the opening minute, shut at the closing one).
    public static func anyLiftRuns(_ bundle: ResortBundle, weekday: Int, minute: Int) -> Bool {
        bundle.graph.edges.contains { edge in
            guard let lift = edge.lift else { return false }
            if lift.operatingHours.isEmpty { return minute >= fallbackOpenMinute && minute < fallbackCloseMinute }
            return lift.operatingHours.contains {
                $0.days.contains(weekday) && minute >= $0.openMinute && minute < $0.closeMinute
            }
        }
    }

    /// The ISO weekday (1 = Monday … 7 = Sunday) at an instant in a zone.
    public static func weekday(_ date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Gregorian weekday: 1 = Sunday.
        return (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }
}

/// Times of day the Dev page jumps the solver to.
public enum SolverTimePreset: String, CaseIterable, Sendable, Hashable {
    case firstChair, midMorning, midday, lastChair, night

    public var label: String {
        switch self {
        case .firstChair: "First Chair"
        case .midMorning: "Mid-Morning"
        case .midday: "Midday"
        case .lastChair: "Last Chair"
        case .night: "Night"
        }
    }

    /// Used when the map has no lift hours that day.
    static let defaultDay = LiftDay(openMinute: 9 * 60, closeMinute: 16 * 60)
    /// Last chair stands this long before the last lift shuts, so lifts still load.
    static let lastChairLeadMinutes = 15

    /// The minute of day this preset sets, on a day whose lifts run as `day` says.
    public func minuteOfDay(on day: LiftDay?) -> Int {
        let day = day ?? Self.defaultDay
        switch self {
        case .firstChair: return day.openMinute
        case .midMorning: return 10 * 60 + 30
        case .midday: return 12 * 60 + 30
        case .lastChair: return max(day.openMinute, day.closeMinute - Self.lastChairLeadMinutes)
        case .night: return 21 * 60 + 30
        }
    }
}

// MARK: Pretend weather

/// Weather the solver and this phone's weather card read in place of the
/// mountain's forecast. `SandboxedBackend` swaps it into `resort_conditions`
/// reads; the backend is never told.
public enum PretendWeather: String, CaseIterable, Sendable, Hashable {
    case real, clearAndCold, warmAndSlushy, snowing, storm, flatLight

    /// `Conditions.source` of a pretend row: `ResortSession` keeps it out of
    /// the cache, so a relaunch never shows it as the real forecast.
    public static let source = "developer"

    public var label: String {
        switch self {
        case .real: "Real"
        case .clearAndCold: "Clear and Cold"
        case .warmAndSlushy: "Warm and Slushy"
        case .snowing: "Snowing"
        case .storm: "Storm"
        case .flatLight: "Flat Light"
        }
    }

    /// What it is, in a line.
    public var detail: String {
        switch self {
        case .real: "The mountain's own forecast"
        case .clearAndCold: "−15 °C, calm, blue sky"
        case .warmAndSlushy: "6 °C, sunny, soft snow"
        case .snowing: "−6 °C, 18 cm new, poor visibility"
        case .storm: "−10 °C, gusts to 95 km/h, heavy snow"
        case .flatLight: "−3 °C, fog, 300 m visibility"
        }
    }

    /// The reading it holds all day; nil for real weather.
    var sample: ConditionsSample? {
        let at = Date(timeIntervalSince1970: 0)
        switch self {
        case .real:
            return nil
        case .clearAndCold:
            return ConditionsSample(
                at: at, tempC: -15, windMS: 2, gustMS: 4, visibilityM: 40_000, cloudPct: 0, weatherCode: 0,
                cloudLowPct: 0)
        case .warmAndSlushy:
            return ConditionsSample(
                at: at, tempC: 6, windMS: 2, gustMS: 4, visibilityM: 30_000, cloudPct: 10, weatherCode: 1,
                cloudLowPct: 0)
        case .snowing:
            return ConditionsSample(
                at: at, tempC: -6, windMS: 4.5, gustMS: 8, visibilityM: 1_400, cloudPct: 100, snow24hCM: 18,
                precipMMH: 1.4, weatherCode: 73, cloudLowPct: 100)
        case .storm:
            return ConditionsSample(
                at: at, tempC: -10, windMS: 16, gustMS: 26, visibilityM: 600, cloudPct: 100, snow24hCM: 25,
                precipMMH: 3, weatherCode: 75, windDirDeg: 270, cloudLowPct: 100)
        case .flatLight:
            return ConditionsSample(
                at: at, tempC: -3, windMS: 2, gustMS: 4, visibilityM: 300, cloudPct: 100, weatherCode: 45,
                cloudLowPct: 100)
        }
    }

    /// The mountain's row with this weather in every hour from a day before
    /// `now` to a day and a half after, so a pretend time anywhere in that span
    /// still reads it; the row reads as fresh for the same span. Real weather
    /// returns `real` unchanged.
    public func apply(to real: Conditions?, resortID: String, now: Date) -> Conditions? {
        guard let sample else { return real }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        func at(_ date: Date) -> ConditionsSample {
            var copy = sample
            copy.at = date
            return copy
        }
        return Conditions(
            resortID: resortID, observedAt: now, expiresAt: now.addingTimeInterval(36 * 3_600),
            source: Self.source, current: at(now),
            hourly: (-24...36).map { at(hour.addingTimeInterval(Double($0) * 3_600)) },
            elevationM: real?.elevationM
        )
    }
}
