import Foundation
import MountainCore

/// Where each person at the open resort has been: friends' positions as they
/// arrive on the user's topic and this phone's own fixes, kept in memory for
/// the timeline's replay. `ResortSession` owns one and it ends with the
/// session; nothing is written to disk or sent anywhere.
///
/// A value: the session hands out copies (`ResortSession.breadcrumbs`,
/// `breadcrumbUpdates()`), so the map can scrub through one on the main actor
/// without a hop per frame. Lookups are binary searches, so a scrub costs
/// O(people × log crumbs) and needs no cache.
public struct Breadcrumbs: Sendable, Hashable {
    public struct Crumb: Sendable, Hashable {
        public var coordinate: Coordinate
        /// The sender's capture time.
        public var at: Date

        public init(coordinate: Coordinate, at: Date) {
            self.coordinate = coordinate
            self.at = at
        }
    }

    /// One crumb per person every 10 s at most.
    public static let minimumIntervalS = 10.0
    /// Eight hours at the minimum interval: a whole ski day.
    public static let maximumPerPerson = 2_880
    /// A position older than this is not shown as where someone is (the
    /// presence TTL).
    public static let staleAfterS = 15.0 * 60
    /// Two crumbs further apart than this are not joined by interpolation.
    public static let interpolationGapS = 60.0

    /// Oldest first, per person.
    public private(set) var trails: [UUID: [Crumb]] = [:]

    public init() {}

    public var people: Set<UUID> { Set(trails.keys) }

    /// The span the timeline can replay, or nil before the first crumb.
    public var timeRange: ClosedRange<Date>? {
        let firsts = trails.values.compactMap(\.first?.at)
        let lasts = trails.values.compactMap(\.last?.at)
        guard let start = firsts.min(), let end = lasts.max() else { return nil }
        return start...end
    }

    /// Adds a position. True when it was kept: not older than the last one,
    /// and at least `minimumIntervalS` after it.
    @discardableResult
    public mutating func record(_ user: UUID, at coordinate: Coordinate, time: Date) -> Bool {
        if let last = trails[user]?.last, time.timeIntervalSince(last.at) < Self.minimumIntervalS {
            return false
        }
        trails[user, default: []].append(Crumb(coordinate: coordinate, at: time))
        if let count = trails[user]?.count, count > Self.maximumPerPerson {
            trails[user]?.removeFirst(count - Self.maximumPerPerson)
        }
        return true
    }

    /// Forgets one person (an unfriend or a block).
    public mutating func remove(_ user: UUID) {
        trails[user] = nil
    }

    /// A person's crumbs at or after `since`, oldest first.
    public func trail(for user: UUID, since: Date) -> [Crumb] {
        guard let crumbs = trails[user] else { return [] }
        return Array(crumbs[Self.firstIndex(in: crumbs, atOrAfter: since)...])
    }

    /// Where everyone was at `instant`: between two crumbs less than
    /// `interpolationGapS` apart, the point between them; otherwise the last
    /// crumb before it, unless that is over `staleAfterS` old. Someone with no
    /// crumb by then is absent.
    public func positions(at instant: Date) -> [UUID: Coordinate] {
        var result: [UUID: Coordinate] = [:]
        for (user, crumbs) in trails {
            let next = Self.firstIndex(in: crumbs, atOrAfter: instant)
            if next < crumbs.count, crumbs[next].at == instant {
                result[user] = crumbs[next].coordinate
                continue
            }
            guard next > 0 else { continue }
            let before = crumbs[next - 1]
            if next < crumbs.count, case let after = crumbs[next],
               after.at.timeIntervalSince(before.at) <= Self.interpolationGapS {
                let share = instant.timeIntervalSince(before.at) / after.at.timeIntervalSince(before.at)
                result[user] = Coordinate(
                    lon: before.coordinate.lon + (after.coordinate.lon - before.coordinate.lon) * share,
                    lat: before.coordinate.lat + (after.coordinate.lat - before.coordinate.lat) * share
                )
            } else if instant.timeIntervalSince(before.at) <= Self.staleAfterS {
                result[user] = before.coordinate
            }
        }
        return result
    }

    /// The first index whose crumb is at or after `time` (`crumbs.count` when none).
    private static func firstIndex(in crumbs: [Crumb], atOrAfter time: Date) -> Int {
        var low = 0, high = crumbs.count
        while low < high {
            let mid = (low + high) / 2
            if crumbs[mid].at < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
