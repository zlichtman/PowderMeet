import Foundation
import MapScene
import MountainCore

/// How much of one mountain a skier has skied: the named runs in its map
/// against the named runs in the run history there, matched by name as Run
/// Completion colours them (`RunOverlay.skiedKey`). Unnamed runs count toward
/// neither number: the history cannot tell one unnamed piece from another.
public enum MountainCompletion {
    public struct Count: Hashable, Sendable {
        /// Distinct named runs on the map the history has skied.
        public var skied: Int
        /// Distinct named runs on the map.
        public var total: Int

        public init(skied: Int, total: Int) {
            self.skied = skied
            self.total = total
        }

        public var fraction: Double { total > 0 ? Double(skied) / Double(total) : 0 }
    }

    /// How often each named run at a resort was skied, keyed by
    /// `RunOverlay.skiedKey`. A track that only passed near a trail did not
    /// ski it, so an approximate name is left out.
    public static func skiedRuns(_ history: ActivityHistory, resortName: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for day in history.resorts.first(where: { $0.name == resortName })?.days ?? [] {
            for run in day.runs {
                if let name = run.name, !run.nameIsApproximate { counts[RunOverlay.skiedKey(name), default: 0] += 1 }
            }
        }
        return counts
    }

    /// The map's named trails against the names skied. Two trail groups with
    /// one name are one run, as the history cannot tell them apart; a name
    /// skied that the map lacks counts for nothing.
    public static func count(trailNames: some Sequence<String>, skied: some Sequence<String>) -> Count {
        let runs = Set(trailNames.map(RunOverlay.skiedKey).filter { !$0.isEmpty })
        let done = runs.intersection(skied.map(RunOverlay.skiedKey))
        return Count(skied: done.count, total: runs.count)
    }

    public static func count(_ bundle: ResortBundle, history: ActivityHistory, resortName: String) -> Count {
        count(
            trailNames: bundle.groups.lazy.filter { $0.kind == .trail }.map(\.name),
            skied: skiedRuns(history, resortName: resortName).keys)
    }
}
