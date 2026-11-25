import Foundation
import MountainCore

/// Version of the matching algorithm. Stored with every `descent_matches` row,
/// so it MUST be incremented on any change that can alter a match.
public let MatcherVersion: Int = 3

/// One matched edge of a descent, in the shape of a `descent_matches.matched`
/// element (`specs/02-DOMAIN.md` section 8).
public struct MatchObservation: Sendable, Hashable, Codable {
    public var edgeID: EdgeID
    /// When the track is first placed on this edge.
    public var enterAt: Date
    /// When it is first placed on the next edge, or the last matched sample.
    public var exitAt: Date
    /// Seconds of trustworthy forward skiing on this edge: intervals whose two
    /// fixes both project onto it, moving down it, outside any sustained
    /// pause. Zero when there is too little of it (under 5 s or 15 m) to
    /// measure pace; the edge is then part of the route but must not train.
    public var movingS: Double
    /// The rest of the time between `enterAt` and `exitAt`.
    public var stoppedS: Double
    /// Metres covered during `movingS`, so `lengthM / movingS` is the pace
    /// observed on this edge. Zero whenever `movingS` is.
    public var lengthM: Double
    /// Peak over a rolling three-interval window within `movingS`.
    public var peakSpeedMS: Double?

    public init(
        edgeID: EdgeID, enterAt: Date, exitAt: Date, movingS: Double, stoppedS: Double,
        lengthM: Double, peakSpeedMS: Double? = nil
    ) {
        self.edgeID = edgeID
        self.enterAt = enterAt
        self.exitAt = exitAt
        self.movingS = movingS
        self.stoppedS = stoppedS
        self.lengthM = lengthM
        self.peakSpeedMS = peakSpeedMS
    }

    /// Whether this edge carries a pace measurement.
    public var hasPace: Bool { movingS > 0 && lengthM > 0 }

    private enum CodingKeys: String, CodingKey {
        case edgeID = "edge_id"
        case enterAt = "enter_at"
        case exitAt = "exit_at"
        case movingS = "moving_s"
        case stoppedS = "stopped_s"
        case lengthM = "length_m"
        case peakSpeedMS = "peak_speed_ms"
    }
}

/// Why a descent could not be placed on the graph. Evidence for audits; a
/// rejected descent is still stored, only without a match.
public enum TrailMatchFailure: Error, Sendable, Hashable {
    /// Fewer than two points, or the track climbs.
    case invalidDescent
    /// The bundle has no run edge with geometry.
    case noTrailGeometry
    /// Under half the track's distance lies on the map: `matched` of the
    /// `sampled` frames were placed on an edge.
    case insufficientCoverage(matched: Int, sampled: Int)
}

/// One stretch of a descent on one trail, or off the map, in travel order:
/// what the activity log lists and what per-run pace is measured over.
/// Consecutive edges of one trail (same group, or same name without a
/// group) form one section.
public struct RunSection: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case run
        /// A mapped link between runs (a cat track or traverse with no run tag).
        case connection
        /// Not within reach of any mapped run or connection.
        case offMap = "off_map"
    }

    public var kind: Kind
    /// The edge's name, else its group's; nil for an unnamed section.
    public var name: String?
    public var groupID: GroupID?
    public var difficulty: Difficulty?
    /// Edges in travel order; empty off the map.
    public var edgeIDs: [EdgeID]
    public var enterAt: Date
    public var exitAt: Date
    /// Metres travelled along the track in this section.
    public var distanceM: Double

    public init(
        kind: Kind, name: String?, groupID: GroupID?, difficulty: Difficulty?, edgeIDs: [EdgeID],
        enterAt: Date, exitAt: Date, distanceM: Double
    ) {
        self.kind = kind
        self.name = name
        self.groupID = groupID
        self.difficulty = difficulty
        self.edgeIDs = edgeIDs
        self.enterAt = enterAt
        self.exitAt = exitAt
        self.distanceM = distanceM
    }

    public var durationS: Double { exitAt.timeIntervalSince(enterAt) }

    func sameTrail(as other: RunSection) -> Bool {
        guard kind == other.kind else { return false }
        if let groupID, let otherGroup = other.groupID { return groupID == otherGroup }
        return groupID == nil && other.groupID == nil && name == other.name
    }

    /// This section extended over `later`, which follows it.
    func extended(over later: RunSection) -> RunSection {
        var result = self
        for id in later.edgeIDs where result.edgeIDs.last != id { result.edgeIDs.append(id) }
        result.exitAt = later.exitAt
        result.distanceM += later.distanceM
        if result.difficulty == nil { result.difficulty = later.difficulty }
        return result
    }

    /// Folds each section too short to name (under 5 s, or a connection under
    /// 15 s) into the one before it (the one after it at the start), keeping
    /// that section's identity, and joins neighbours of one trail.
    static func absorbingSlivers(_ sections: [RunSection]) -> [RunSection] {
        guard sections.count > 1 else { return sections }
        func isSliver(_ s: RunSection) -> Bool {
            s.durationS < 5 || (s.kind == .connection && s.durationS < 15)
        }
        var result: [RunSection] = []
        var leading: [RunSection] = []
        for section in sections {
            if isSliver(section) {
                if let last = result.popLast() {
                    var grown = last
                    grown.exitAt = section.exitAt
                    grown.distanceM += section.distanceM
                    result.append(grown)
                } else {
                    leading.append(section)
                }
                continue
            }
            var section = section
            if let first = leading.first {
                section.enterAt = first.enterAt
                section.distanceM += leading.reduce(0) { $0 + $1.distanceM }
                leading = []
            }
            if let last = result.last, last.sameTrail(as: section) {
                result[result.count - 1] = last.extended(over: section)
            } else {
                result.append(section)
            }
        }
        // Every section was a sliver: keep them as they were.
        return result.isEmpty ? sections : result
    }

    /// The sections as the activity log lists them: slivers absorbed, then
    /// two corrections for what GPS does near trails, each measured on the
    /// corpus (`MatchQualityTests`):
    /// - a blip off the map under 20 s between two stretches of one trail is
    ///   drift at the edge of a wide trail, so the trail carries on through it;
    /// - a trail touched for under 10 s between two stretches off the map was
    ///   crossed, not skied, so the stretch stays off the map.
    static func tidied(_ sections: [RunSection]) -> [RunSection] {
        var result = absorbingSlivers(sections)
        func joined(_ list: [RunSection]) -> [RunSection] {
            var out: [RunSection] = []
            for section in list {
                if let last = out.last, last.sameTrail(as: section) {
                    out[out.count - 1] = last.extended(over: section)
                } else {
                    out.append(section)
                }
            }
            return out
        }
        var index = 1
        while index + 1 < result.count {
            let (before, middle, after) = (result[index - 1], result[index], result[index + 1])
            if middle.kind == .offMap, middle.durationS < 20, before.kind != .offMap, before.sameTrail(as: after) {
                var bridged = before
                bridged.exitAt = middle.exitAt
                bridged.distanceM += middle.distanceM
                result.replaceSubrange((index - 1)...(index + 1), with: [bridged.extended(over: after)])
                index = max(1, index - 1)
            } else if middle.kind != .offMap, middle.durationS < 10, before.kind == .offMap, after.kind == .offMap {
                var crossed = before
                crossed.exitAt = after.exitAt
                crossed.distanceM += middle.distanceM + after.distanceM
                result.replaceSubrange((index - 1)...(index + 1), with: [crossed])
                index = max(1, index - 1)
            } else {
                index += 1
            }
        }
        return joined(result)
    }
}

/// The derivation of a descent against one bundle. `sections` places the
/// whole descent, on named or unnamed trails or off the map. `matched` holds
/// the edges it was placed on when at least half its distance is on the map;
/// otherwise it is empty and `failure` says why. Consecutive matched edges
/// are usually joined in the graph but need not be: the matcher may step
/// between trails that touch without a shared node.
public struct DescentMatch: Sendable, Hashable {
    public var bundleID: BundleID
    public var matcherVersion: Int
    /// In travel order.
    public var matched: [MatchObservation]
    /// Fraction of the track's distance placed on a run or connection, 0...1.
    public var coverage: Double
    /// A geometry score in 0...1 (55 % coverage, 35 % closeness, 10 % heading
    /// agreement). It is a score for ranking and gating, not a probability.
    public var confidence: Double
    /// For a one-line label: on the named trail skied furthest (an unnamed
    /// one only when none is named), its edge holding the most distance.
    public var primaryEdgeID: EdgeID?
    /// Mean distance from the placed samples to their edges.
    public var meanDistanceM: Double?
    /// The descent's ordered sections. Empty only when it could not be
    /// evaluated (`invalidDescent`, `noTrailGeometry`).
    public var sections: [RunSection]
    public var failure: TrailMatchFailure?

    public init(
        bundleID: BundleID, matcherVersion: Int = MatcherVersion, matched: [MatchObservation],
        coverage: Double, confidence: Double, primaryEdgeID: EdgeID? = nil,
        meanDistanceM: Double? = nil, sections: [RunSection] = [], failure: TrailMatchFailure? = nil
    ) {
        self.bundleID = bundleID
        self.matcherVersion = matcherVersion
        self.matched = matched
        self.coverage = coverage
        self.confidence = confidence
        self.primaryEdgeID = primaryEdgeID
        self.meanDistanceM = meanDistanceM
        self.sections = sections
        self.failure = failure
    }

    public var isMatched: Bool { !matched.isEmpty }
}
