import DescentKit
import Foundation
import MountainCore
import PowderMeetAPI

/// One run as the detail screen shows it: its path over the resort map in
/// the order it was skied (named runs, unnamed runs, connections and
/// stretches off the map, with times), and the track to draw. The path is
/// the matcher's `RunSection`s: `descent_upsert` does not store them, so they
/// are derived here from the stored track and the bundle the run was matched
/// against. A track that cannot be matched again falls back to the stored
/// matched edges.
public struct RunDetail: Sendable, Hashable {
    /// `RunSection.Kind`, so the app need not import DescentKit.
    public enum Kind: Sendable, Hashable {
        case run, connection, offMap

        init(_ kind: RunSection.Kind) {
            switch kind {
            case .run: self = .run
            case .connection: self = .connection
            case .offMap: self = .offMap
            }
        }
    }

    public struct Section: Sendable, Hashable, Identifiable {
        public var id: Int
        public var kind: Kind
        /// The trail's name; nil for a stretch the map does not name (a cat
        /// track, a connector) and off the map.
        public var name: String?
        public var difficulty: Difficulty?
        public var edgeCount: Int
        public var lengthM: Double
        public var enterAt: Date
        public var exitAt: Date

        public var durationS: Double { exitAt.timeIntervalSince(enterAt) }
    }

    public enum Unavailable: Sendable, Hashable {
        /// The run was never placed on a map (no bundle for the resort).
        case notMatched
        /// The map it was placed on is no longer on this phone.
        case mapNotOnPhone
    }

    public var sections: [Section]
    public var unavailable: Unavailable?
    /// The recorded track, for the small map; empty when it could not be read.
    public var track: [Coordinate]

    public static func build(_ detail: DescentDetail, bundle: ResortBundle?) -> RunDetail {
        var points: [TrackPoint] = []
        if let data = detail.track {
            do {
                points = try DescentTrackCodec.decode(data)
            } catch {
                points = []
            }
        }
        let track = points.map(\.coordinate)
        guard let match = detail.match, !match.matched.isEmpty else {
            return RunDetail(sections: [], unavailable: .notMatched, track: track)
        }
        guard let bundle else {
            return RunDetail(sections: [], unavailable: .mapNotOnPhone, track: track)
        }
        let derived = sections(of: points, in: bundle)
        return RunDetail(
            sections: derived.isEmpty ? storedSections(match, in: bundle) : derived,
            unavailable: nil, track: track)
    }

    /// The matcher's sections for the stored track, as the log matched it.
    static func sections(of points: [TrackPoint], in bundle: ResortBundle) -> [Section] {
        let timed = points.filter { $0.timestamp != nil }
        guard timed.count >= 2, let start = timed.first?.timestamp, let end = timed.last?.timestamp else {
            return []
        }
        // The matcher reads the points only; the source names nothing here.
        let descent = Descent(source: .gpx, startedAt: start, endedAt: end, points: timed)
        return TrailMatcher.match(descent: descent, in: bundle).sections.enumerated().map { index, section in
            Section(
                id: index, kind: Kind(section.kind), name: section.name, difficulty: section.difficulty,
                edgeCount: section.edgeIDs.count, lengthM: section.distanceM,
                enterAt: section.enterAt, exitAt: section.exitAt)
        }
    }

    /// Consecutive stored edges of the same trail as one section, for a track
    /// that no longer matches (or has no points).
    static func storedSections(_ match: DescentUpload.Match, in bundle: ResortBundle) -> [Section] {
        var edges: [EdgeID: Edge] = [:]
        for edge in bundle.graph.edges { edges[edge.id] = edge }

        var sections: [Section] = []
        for observation in match.matched.sorted(by: { $0.enterAt < $1.enterAt }) {
            let edge = edges[EdgeID(observation.edgeID)]
            let group = edge?.group.flatMap { bundle.group($0) }
            let name = edge?.name ?? group?.name
            let difficulty = edge?.difficulty ?? group?.difficulty
                ?? observation.difficulty.flatMap(Difficulty.init(rawValue:))
            let kind: Kind = edge?.kind == .connection ? .connection : .run
            if var last = sections.last, last.name == name, last.difficulty == difficulty, last.kind == kind {
                last.edgeCount += 1
                last.lengthM += observation.lengthM
                last.exitAt = max(last.exitAt, observation.exitAt)
                sections[sections.count - 1] = last
            } else {
                sections.append(Section(
                    id: sections.count, kind: kind, name: name, difficulty: difficulty, edgeCount: 1,
                    lengthM: observation.lengthM, enterAt: observation.enterAt, exitAt: observation.exitAt
                ))
            }
        }
        return sections
    }
}

extension ActivityLibrary {
    /// The detail of one stored run, with its map from the phone's cache (a
    /// run's resort was opened or imported on this phone to be matched).
    /// Matching the track again happens here, off the main actor.
    public func detail(of runID: UUID) async throws(PowderMeetError) -> RunDetail? {
        let detail: DescentDetail?
        do {
            detail = try await dependencies.backend.descentDetail(descentID: runID)
        } catch {
            dependencies.log.error(.activity, "run detail load failed: \(error)")
            throw PowderMeetError(error)
        }
        guard let detail else { return nil }
        let bundle = detail.match.flatMap { BundleID(rawValue: $0.bundleID) }.flatMap { dependencies.bundles.bundle($0) }
        return RunDetail.build(detail, bundle: bundle)
    }
}
