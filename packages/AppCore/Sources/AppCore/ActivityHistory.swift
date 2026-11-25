import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

/// The skier's descents as the Profile draws them: resorts, each with its ski
/// days, each with its runs, plus the lifetime totals and the pace evidence.
/// A pure projection of `descents` rows; nothing here is stored.
public struct ActivityHistory: Sendable, Hashable {
    public struct Run: Sendable, Hashable, Identifiable {
        public var id: UUID
        /// The trail from the resort bundle, when the run could be placed.
        public var name: String?
        /// The name is the nearest trail, not a match.
        public var nameIsApproximate: Bool
        public var difficulty: Difficulty?
        public var startedAt: Date
        public var durationS: Double
        public var verticalM: Double?
        public var distanceM: Double?
        public var topSpeedMS: Double?
        public var avgSpeedMS: Double?
        /// `descents.source`: slopes, gpx, tcx, fit, live, healthkit.
        public var source: String

        /// The run as the logs and its detail name it: "Near Franz's Run" when
        /// the name is only the nearest trail's, else `TerrainName.run`.
        public var title: String {
            guard let name = TerrainName.named(name) else { return TerrainName.run(nil, difficulty: difficulty) }
            return nameIsApproximate ? "Near \(name)" : name
        }
    }

    public struct Day: Sendable, Hashable, Identifiable {
        /// Resort and day, unique in the history.
        public var id: String
        /// `yyyy-MM-dd` at the resort.
        public var day: String
        public var resortName: String
        /// In time order.
        public var runs: [Run]
        public var sourceApp: String?

        public var verticalM: Double { runs.reduce(0) { $0 + ($1.verticalM ?? 0) } }
        public var distanceM: Double { runs.reduce(0) { $0 + ($1.distanceM ?? 0) } }
        public var topSpeedMS: Double? { runs.compactMap(\.topSpeedMS).max() }
        public var startedAt: Date { runs.first?.startedAt ?? .distantPast }
    }

    public struct Resort: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Newest first.
        public var days: [Day]

        public var runCount: Int { days.reduce(0) { $0 + $1.runs.count } }
    }

    public struct Totals: Sendable, Hashable {
        public var runs = 0
        public var days = 0
        public var distanceM = 0.0
        public var verticalM = 0.0
        public var topSpeedMS: Double?
        /// Distance over time on the runs that have both; lift rides and
        /// lunch are not in it.
        public var avgSpeedMS: Double?
    }

    public static let unknownResort = "Unknown resort"

    /// Newest resort first.
    public var resorts: [Resort]
    /// Every ski day across resorts, newest first: the log's rows.
    public var days: [Day] {
        resorts.flatMap(\.days).sorted { ($0.day, $0.startedAt) > ($1.day, $1.startedAt) }
    }
    public var allRunIDs: [UUID] { resorts.flatMap(\.days).flatMap(\.runs).map(\.id) }
    public var totals: Totals
    public var evidence: [Difficulty: PaceCalibration.Evidence]
    /// The hardest marked run in the log (green to double black); nil until a
    /// run carries a rating.
    public var hardestSkied: Difficulty?

    public var isEmpty: Bool { totals.runs == 0 }
    /// Runs that taught the pace model something.
    public var calibrationRuns: Int

    public init(_ rows: [DescentSummary] = []) {
        var totals = Totals()
        var evidence: [Difficulty: PaceCalibration.Evidence] = [:]
        var calibrated = 0
        var hardest: Difficulty?
        var timedDistance = 0.0
        var timedSeconds = 0.0
        var days: [String: (resort: String, day: Day)] = [:]

        for row in rows.sorted(by: { $0.startedAt < $1.startedAt }) {
            let stats = row.stats ?? DescentStatsRow()
            let duration = row.endedAt.timeIntervalSince(row.startedAt)
            let run = Run(
                id: row.descentID, name: stats.trailName,
                nameIsApproximate: stats.trailName != nil && stats.matched != true,
                difficulty: stats.difficulty.flatMap(Difficulty.init(rawValue:)),
                startedAt: row.startedAt, durationS: duration, verticalM: stats.verticalM,
                distanceM: stats.distanceM, topSpeedMS: stats.topSpeedMS, avgSpeedMS: stats.avgSpeedMS,
                source: row.source.rawValue
            )
            let resort = stats.resortName ?? Self.unknownResort
            let dayKey = stats.localDay ?? Self.utcDay(row.startedAt)
            let key = "\(resort)|\(dayKey)"
            var entry = days[key]
                ?? (resort, Day(id: key, day: dayKey, resortName: resort, runs: [], sourceApp: stats.sourceApp))
            entry.day.runs.append(run)
            days[key] = entry

            totals.runs += 1
            if let rank = run.difficulty?.ladderRank, rank > (hardest?.ladderRank ?? -1) {
                hardest = run.difficulty
            }
            totals.verticalM += stats.verticalM ?? 0
            totals.distanceM += stats.distanceM ?? 0
            if let top = stats.topSpeedMS { totals.topSpeedMS = max(totals.topSpeedMS ?? 0, top) }
            if let distance = stats.distanceM, distance > 0, duration > 0 {
                // Moving time when the phone measured a moving speed.
                let seconds = stats.avgSpeedMS.flatMap { $0 > 0 ? distance / $0 : nil } ?? duration
                timedDistance += distance
                timedSeconds += seconds
            }

            var taught = false
            for (key, pace) in stats.pace ?? [:] {
                guard let difficulty = Difficulty(rawValue: key), pace.movingS > 0, pace.lengthM > 0 else { continue }
                evidence[difficulty, default: .init()].add(movingS: pace.movingS, lengthM: pace.lengthM)
                taught = true
            }
            if taught { calibrated += 1 }
        }

        totals.days = days.count
        if timedSeconds > 0 { totals.avgSpeedMS = timedDistance / timedSeconds }

        var byResort: [String: [Day]] = [:]
        for entry in days.values { byResort[entry.resort, default: []].append(entry.day) }
        resorts = byResort.map { name, days in
            Resort(name: name, days: days.sorted { ($0.day, $0.startedAt) > ($1.day, $1.startedAt) })
        }.sorted {
            let a = $0.days.first?.startedAt ?? .distantPast, b = $1.days.first?.startedAt ?? .distantPast
            return (a, $1.name) > (b, $0.name)
        }
        self.totals = totals
        self.evidence = evidence
        hardestSkied = hardest
        calibrationRuns = calibrated
    }

    /// The level the runs in the log back: the lowest one whose limit covers
    /// the hardest run skied. Nil with no rated run.
    public var backedAbility: Ability? {
        guard let rank = hardestSkied?.ladderRank else { return nil }
        return Ability.allCases.first {
            (SkierProfile.preset($0, userID: UUID()).maxDifficulty.ladderRank ?? 0) >= rank
        }
    }

    private static func utcDay(_ date: Date) -> String {
        ActivityDay.string(date, in: TimeZone(secondsFromGMT: 0) ?? .gmt)
    }
}

/// The ski day a moment belongs to, as `yyyy-MM-dd` in the resort's zone.
public enum ActivityDay {
    public static func string(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year ?? 0, 4))-\(pad(parts.month ?? 0, 2))-\(pad(parts.day ?? 0, 2))"
    }

    /// Noon UTC on the day, for formatting it without shifting the date.
    public static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// A zone good enough to tell ski days apart where no resort is known:
    /// the whole-hour offset of the longitude.
    public static func approximateZone(lon: Double) -> TimeZone {
        TimeZone(secondsFromGMT: Int((lon / 15).rounded()) * 3_600) ?? .gmt
    }
}

/// Turns what the skier's own runs show into the per-difficulty speeds the
/// solver reads from `profiles.baseline_speeds` (`specs/08-ACTIVITY.md`
/// section 4). The answer is always recomputed from the ability preset and the
/// whole history, so importing, deleting or importing again cannot drift it.
public enum PaceCalibration {
    public struct Evidence: Sendable, Hashable {
        public var movingS = 0.0
        public var lengthM = 0.0
        /// Runs that contributed.
        public var runs = 0

        public init() {}

        mutating func add(movingS: Double, lengthM: Double) {
            self.movingS += movingS
            self.lengthM += lengthM
            runs += 1
        }

        public var speedMS: Double? { movingS > 0 ? lengthM / movingS : nil }
    }

    /// Runs' worth of weight the preset keeps, so three fast laps do not
    /// rewrite a skier.
    static let presetWeight = 8.0
    /// A measured speed outside this share of the preset is not believed past
    /// the bound: GPS noise and a day of racing a friend both exist.
    static let factorRange = 0.5...1.6

    /// The speeds for an ability, moved toward what the runs show. A
    /// difficulty with no evidence keeps the preset, which has one for every
    /// rating.
    public static func baselineSpeeds(
        ability: Ability, evidence: [Difficulty: Evidence]
    ) -> [String: Double] {
        var speeds: [String: Double] = [:]
        for (difficulty, preset) in SkierProfile.preset(ability, userID: UUID()).baselineSpeedMS {
            var speed = preset
            if let seen = evidence[difficulty], let observed = seen.speedMS, seen.runs > 0, preset > 0 {
                let n = Double(seen.runs)
                let factor = (n * (observed / preset) + presetWeight) / (n + presetWeight)
                speed = preset * min(max(factor, factorRange.lowerBound), factorRange.upperBound)
            }
            speeds[difficulty.rawValue] = (speed * 100).rounded() / 100
        }
        return speeds
    }
}
