import Foundation
import MountainCore
import PowderMeetAPI

/// The profile's achievement badges (`specs/08-ACTIVITY.md` section 7): what
/// each one is, and which a skier has earned from the run history and the
/// meets the server keeps. Nothing about earning one is stored: those are the
/// record, so a badge can never disagree with what it was earned from.
public struct Badge: Hashable, Sendable, Identifiable {
    public enum Tier: Int, Sendable, Hashable, Comparable, CaseIterable {
        case bronze = 1, silver, gold

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Section: String, Sendable, Hashable, CaseIterable {
        case meeting = "Meeting up"
        case mountains = "Mountains"
        case runs = "Runs"
        case distance = "Distance"
        case days = "Days"
        case app = "PowderMeet"
    }

    /// Also the picture's name: `Badge-<id>`, with `-bronze`, `-silver` or
    /// `-gold` after it for a tiered badge.
    public var id: String
    public var title: String
    public var section: Section
    /// How it is earned, in a sentence.
    public var rule: String
    /// The three steps of a tiered badge, in words ("3", "10", "25").
    public var steps: [String]
    /// The same three steps as numbers, in the unit the rule names.
    public var targets: [Double] {
        steps.compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }
    /// False while the app reads nothing the badge could be earned from (the
    /// weather on a ski day, lifts ridden, a meet's place or both arrivals).
    public var isLive: Bool
    /// The rule for a skier who reads metric, for a badge whose rule names an
    /// imperial figure. What earns it is unchanged: the figures are the
    /// imperial ones converted, never rounded to a friendlier metric number
    /// that would be reached sooner or later than the badge.
    var metric: Metric?

    public var isTiered: Bool { !steps.isEmpty }

    /// Lengths (metres, kilometres, centimetres, °C) and speeds (km/h) are
    /// chosen apart: a UK phone reads metres and miles an hour.
    public struct Units: Sendable, Hashable {
        public var metricLengths: Bool
        public var metricSpeed: Bool

        public init(metricLengths: Bool, metricSpeed: Bool) {
            self.metricLengths = metricLengths
            self.metricSpeed = metricSpeed
        }

        public static let imperial = Units(metricLengths: false, metricSpeed: false)
    }

    struct Metric: Hashable, Sendable {
        var rule: String
        var isSpeed: Bool
        /// One of the rule's imperial units in the metric unit, for a tiered
        /// badge whose count is shown: feet to metres, miles to kilometres.
        var factor: Double?

        func applies(_ units: Units) -> Bool { isSpeed ? units.metricSpeed : units.metricLengths }
    }

    /// How it is earned, in the skier's units.
    public func rule(in units: Units) -> String {
        guard let metric, metric.applies(units) else { return rule }
        return metric.rule
    }

    /// A count in the rule's unit as the skier reads it.
    func shown(_ value: Double, in units: Units) -> Double {
        guard let metric, metric.applies(units), let factor = metric.factor else { return value }
        return value * factor
    }

    public func image(_ tier: Tier?) -> String {
        isTiered ? "Badge-\(id)-\(tier ?? .bronze)" : "Badge-\(id)"
    }
}

public enum Badges {
    /// Where a skier stands on one badge: earned or not, the tier reached on
    /// a tiered one, and how far along its count is.
    public struct Earned: Hashable, Sendable, Identifiable {
        public var badge: Badge
        public var isEarned: Bool
        public var tier: Badge.Tier?
        /// A tiered badge's count so far, in the unit its rule names; nil for
        /// the others and for a tiered badge nothing is recorded for yet.
        public var value: Double?
        public var id: String { badge.id }

        /// The step still to reach, or nil when gold is reached.
        public var nextTarget: Double? {
            guard let value else { return nil }
            return badge.targets.first { value < $0 }
        }

        /// The count so far and the step still to reach, in the skier's
        /// units; nil when nothing is counted yet or gold is reached. The
        /// count is rounded down and the step up, so a converted row never
        /// reads as reached before the badge is.
        public func progress(in units: Badge.Units) -> (value: Double, next: Double)? {
            guard let value, let next = nextTarget else { return nil }
            return (badge.shown(value, in: units).rounded(.down), badge.shown(next, in: units).rounded(.up))
        }
    }

    /// What the catalog says about a resort in the history, by its name.
    public struct ResortFacts: Sendable, Hashable {
        public var country: String?
        public var passes: [String]

        public init(country: String?, passes: [String]) {
            self.country = country
            self.passes = passes
        }
    }

    /// A meet-up reached: the server completed the meet because both skiers
    /// arrived. A meet ended by hand, even side by side, is not one.
    public struct ReachedMeet: Sendable, Hashable {
        public var partner: UUID
        public var reachedAt: Date?
        /// The resort's zone, for the time of day it was reached; nil when
        /// the catalog does not know it.
        public var timeZone: TimeZone?

        public init(partner: UUID, reachedAt: Date?, timeZone: TimeZone?) {
            self.partner = partner
            self.reachedAt = reachedAt
            self.timeZone = timeZone
        }

        /// Before 9:30 on the resort's clock.
        var isFirstChair: Bool {
            guard let reachedAt, let timeZone else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let time = calendar.dateComponents([.hour, .minute], from: reachedAt)
            return (time.hour ?? 24) * 60 + (time.minute ?? 0) < 9 * 60 + 30
        }
    }

    /// The meet-ups reached among the skier's meets (`meet_history`).
    /// - Parameter zones: each resort's IANA zone by resort id, from the catalog.
    public static func reached(_ meets: [Meet], me: UUID, zones: [String: String]) -> [ReachedMeet] {
        meets.filter { $0.status == .completed && $0.endReason == .arrived && $0.involves(me) }.map {
            ReachedMeet(
                partner: $0.partner(of: me), reachedAt: $0.endedAt,
                timeZone: zones[$0.resortID].flatMap(TimeZone.init(identifier:)))
        }
    }

    static let feet = 0.3048
    static let mile = 1609.344
    static let mph = 0.44704
    /// A mile, and so a mile an hour, in kilometres.
    static let kilometresPerMile = mile / 1000

    public static let all: [Badge] = [
        badge("first-meet", "First Meet", .meeting, "Reach your first meet-up."),
        badge("crew", "Crew", .meeting, "Meet up with different friends.", ["3", "10", "25"]),
        badge("regulars", "Regulars", .meeting, "Reach meet-ups.", ["10", "50", "100"]),
        badge("right-on-time", "Right On Time", .meeting, "Arrive within a minute of your friend, five times.", live: false),
        badge("summit-meeting", "Summit Meeting", .meeting, "Meet at a mountain's highest lift top.", live: false),
        badge("lodge-lizards", "Lodge Lizards", .meeting, "Meet at a lodge ten times.", live: false),
        badge("found-you", "Found You", .meeting, "Meet in falling snow or poor visibility.", live: false),
        badge("first-chair-crew", "First Chair Crew", .meeting, "Reach a meet-up before 9:30."),

        badge("first-tracks", "First Tracks", .mountains, "Log your first run."),
        badge("explorer", "Explorer", .mountains, "Ski different resorts.", ["3", "10", "25"]),
        badge("passport", "Passport", .mountains, "Ski in different countries.", ["2", "4", "6"]),
        badge("whole-mountain", "Whole Mountain", .mountains, "Ski every named run on one mountain.", live: false),
        badge("halfway-there", "Halfway There", .mountains, "Ski half of one mountain's named runs.", live: false),
        badge("lift-collector", "Lift Collector", .mountains, "Ride every lift on one mountain.", live: false),
        badge("home-mountain", "Home Mountain", .mountains, "Ski days at one resort.", ["10", "25", "50"]),
        badge("epic-and-ikon", "Epic and Ikon", .mountains, "Ski a day at a resort on each pass."),

        badge("green-light", "Green Light", .runs, "Ski 25 green runs."),
        badge("true-blue", "True Blue", .runs, "Ski 50 blue runs."),
        badge("black-diamond", "Black Diamond", .runs, "Ski 25 black runs."),
        badge("double-trouble", "Double Trouble", .runs, "Ski 10 double-black runs."),
        badge("century", "Century", .runs, "Ski runs.", ["100", "500", "1,000"]),
        badge("steep-seeker", "Steep Seeker", .runs, "Ski a run that pitches 35° or more.", live: false),
        badge("north-face", "North Face", .runs, "Ski 25 north-facing runs.", live: false),
        badge("mogul-hound", "Mogul Hound", .runs, "Ski 10 mogul runs.", live: false),
        badge("corduroy", "Corduroy", .runs, "Ski 25 groomed runs before 10:00.", live: false),

        badge("vertical", "Vertical", .distance, "Vertical feet skied in all.", ["10,000", "100,000", "1,000,000"],
              metric: Badge.Metric(rule: "Vertical metres skied in all.", isSpeed: false, factor: feet)),
        badge("everest", "Everest", .distance, "Ski 29,032 ft of vertical in one day.",
              metric: Badge.Metric(rule: "Ski 8,849 m of vertical in one day.", isSpeed: false)),
        badge("marathon", "Marathon", .distance, "Ski 26.2 miles in one day.",
              metric: Badge.Metric(rule: "Ski 42.2 km in one day.", isSpeed: false)),
        badge("long-hauler", "Long Hauler", .distance, "Miles skied in all.", ["100", "500", "1,000"],
              metric: Badge.Metric(rule: "Kilometres skied in all.", isSpeed: false, factor: kilometresPerMile)),
        badge("need-for-speed", "Need for Speed", .distance, "Top speed in miles an hour.", ["40", "50", "60"],
              metric: Badge.Metric(rule: "Top speed in kilometres an hour.", isSpeed: true, factor: kilometresPerMile)),
        badge("bell-to-bell", "Bell to Bell", .distance, "Ski from first lift to last in one day.", live: false),

        badge("opening-day", "Opening Day", .days, "Ski a day in November or earlier in the season."),
        badge("closing-day", "Closing Day", .days, "Ski a day in May or later in the season."),
        badge("regular", "Regular", .days, "Ski days in one season.", ["5", "20", "50"]),
        badge("streak", "Streak", .days, "Ski days in a row.", ["3", "5", "7"]),
        badge("powder-day", "Powder Day", .days, "Ski a day with six inches or more of new snow.", live: false,
              metric: Badge.Metric(rule: "Ski a day with 15 cm or more of new snow.", isSpeed: false)),
        badge("bluebird", "Bluebird", .days, "Ski a clear day with no wind.", live: false),
        badge("storm-chaser", "Storm Chaser", .days, "Ski a day of heavy snow and wind.", live: false),
        badge("cold-snap", "Cold Snap", .days, "Ski a day below 0°F.", live: false,
              metric: Badge.Metric(rule: "Ski a day below −18°C.", isSpeed: false)),

        badge("logbook", "Logbook", .app, "Log ten ski days."),
        badge("proven", "Proven", .app, "Have your level backed by your own runs."),
        badge("early-adopter", "Early Adopter", .app, "Use PowderMeet in the beta."),
    ]

    private static func badge(
        _ id: String, _ title: String, _ section: Badge.Section, _ rule: String, _ steps: [String] = [],
        live: Bool = true, metric: Badge.Metric? = nil
    ) -> Badge {
        Badge(id: id, title: title, section: section, rule: rule, steps: steps, isLive: live, metric: metric)
    }

    /// The badges this history has earned, in `all`'s order.
    public static func earned(
        _ history: ActivityHistory, meets: [ReachedMeet]? = nil, facts: [String: ResortFacts],
        levelIsBacked: Bool, isBeta: Bool
    ) -> [Earned] {
        standings(history, meets: meets, facts: facts, levelIsBacked: levelIsBacked, isBeta: isBeta)
            .filter(\.isEarned)
    }

    /// Every badge with where this history stands on it, in `all`'s order.
    /// - Parameters:
    ///   - meets: the meet-ups reached, or nil before they have been read: the
    ///     meet badges then stand at nothing rather than at none reached.
    ///   - facts: the catalog's country and passes for each resort name in the history.
    ///   - levelIsBacked: the pace model has a level worked out from the runs.
    ///   - isBeta: this copy of the app is a beta build.
    public static func standings(
        _ history: ActivityHistory, meets: [ReachedMeet]? = nil, facts: [String: ResortFacts],
        levelIsBacked: Bool, isBeta: Bool
    ) -> [Earned] {
        let days = history.resorts.flatMap(\.days)
        let runs = days.flatMap(\.runs)
        let resorts = history.resorts.filter { $0.name != ActivityHistory.unknownResort }
        // One calendar day skied at two resorts is one day.
        let dates = Set(days.map(\.day))
        let byDate = Dictionary(grouping: days, by: \.day)

        func count(_ difficulty: Difficulty) -> Int { runs.count { $0.difficulty == difficulty } }
        var values: [String: Double] = [:]
        var plain: Set<String> = []
        /// A tiered badge's count; its steps are the badge's own.
        func give(_ id: String, _ value: Double) { values[id] = value }
        func give(_ id: String, if earned: Bool) { if earned { plain.insert(id) } }

        if let meets {
            give("first-meet", if: !meets.isEmpty)
            give("crew", Double(Set(meets.map(\.partner)).count))
            give("regulars", Double(meets.count))
            give("first-chair-crew", if: meets.contains(where: \.isFirstChair))
        }

        give("first-tracks", if: !runs.isEmpty)
        give("explorer", Double(resorts.count))
        give("passport", Double(Set(resorts.compactMap { facts[$0.name]?.country }).count))
        give("home-mountain", Double(resorts.map(\.days.count).max() ?? 0))
        let passes = Set(resorts.flatMap { facts[$0.name]?.passes ?? [] }.map { $0.lowercased() })
        give("epic-and-ikon", if: passes.contains { $0.contains("epic") } && passes.contains { $0.contains("ikon") })

        give("green-light", if: count(.green) >= 25)
        give("true-blue", if: count(.blue) >= 50)
        give("black-diamond", if: count(.black) >= 25)
        give("double-trouble", if: count(.doubleBlack) >= 10)
        give("century", Double(runs.count))

        give("vertical", history.totals.verticalM / feet)
        give("long-hauler", history.totals.distanceM / mile)
        give("need-for-speed", (history.totals.topSpeedMS ?? 0) / mph)
        give("everest", if: byDate.values.contains { $0.reduce(0) { $0 + $1.verticalM } >= 29_032 * feet })
        give("marathon", if: byDate.values.contains { $0.reduce(0) { $0 + $1.distanceM } >= 26.2 * mile })

        let months = dates.compactMap { Int($0.dropFirst(5).prefix(2)) }
        give("opening-day", if: months.contains { (9...11).contains($0) })
        give("closing-day", if: months.contains { (5...7).contains($0) })
        give("regular", Double(Dictionary(grouping: dates, by: season).values.map(\.count).max() ?? 0))
        give("streak", Double(longestStreak(dates)))

        give("logbook", if: dates.count >= 10)
        give("proven", if: levelIsBacked)
        give("early-adopter", if: isBeta)

        return all.map { badge in
            guard badge.isTiered else {
                return Earned(badge: badge, isEarned: plain.contains(badge.id), tier: nil, value: nil)
            }
            guard let value = values[badge.id] else {
                return Earned(badge: badge, isEarned: false, tier: nil, value: nil)
            }
            let tier = Array(zip(Badge.Tier.allCases, badge.targets)).last { value >= $0.1 }?.0
            return Earned(badge: badge, isEarned: tier != nil, tier: tier, value: value)
        }
    }

    /// The winter a `yyyy-MM-dd` day belongs to, named by the year it starts
    /// in: a season runs from July to June.
    static func season(_ day: String) -> Int {
        let year = Int(day.prefix(4)) ?? 0
        let month = Int(day.dropFirst(5).prefix(2)) ?? 1
        return month >= 7 ? year : year - 1
    }

    /// The most `yyyy-MM-dd` days in a row.
    static func longestStreak(_ dates: Set<String>) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let ordinals = Set(dates.compactMap { day -> Int? in
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            return Int((date.timeIntervalSinceReferenceDate / 86_400).rounded())
        })
        var best = 0
        for start in ordinals where !ordinals.contains(start - 1) {
            var length = 1
            while ordinals.contains(start + length) { length += 1 }
            best = max(best, length)
        }
        return best
    }
}

/// Which badges have just been earned, against the ones this phone already
/// saw earned for the account (`specs/08-ACTIVITY.md` section 7). The badges
/// themselves are still worked out from the history; only what has been
/// announced is remembered, so the moment comes once.
public enum BadgeMoments {
    public struct Outcome: Hashable, Sendable {
        /// Badges earned, or a tier reached, since `seen`, in `Badges.all`'s order.
        public var newlyEarned: [Badges.Earned]
        /// What to remember now: never less than before, so a deleted log
        /// earned again is not announced twice.
        public var seen: Set<String>
    }

    /// Each earned badge by its id, and a tiered one by every tier up to the
    /// one reached ("explorer.bronze", "explorer.silver").
    public static func keys(_ standings: [Badges.Earned]) -> Set<String> {
        var keys: Set<String> = []
        for standing in standings where standing.isEarned {
            guard let tier = standing.tier else {
                keys.insert(standing.badge.id)
                continue
            }
            for reached in Badge.Tier.allCases where reached <= tier {
                keys.insert("\(standing.badge.id).\(reached)")
            }
        }
        return keys
    }

    /// `seen` is nil when nothing is remembered for the account on this phone
    /// (the first launch of a build that announces badges, or a new phone):
    /// everything already earned is remembered and nothing is announced.
    public static func check(_ standings: [Badges.Earned], seen: Set<String>?) -> Outcome {
        let now = keys(standings)
        guard let seen else { return Outcome(newlyEarned: [], seen: now) }
        let fresh = standings.filter { standing in
            guard standing.isEarned else { return false }
            let key = standing.tier.map { "\(standing.badge.id).\($0)" } ?? standing.badge.id
            return !seen.contains(key)
        }
        return Outcome(newlyEarned: fresh, seen: seen.union(now))
    }
}
