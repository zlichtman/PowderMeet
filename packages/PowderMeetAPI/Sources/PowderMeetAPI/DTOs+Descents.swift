import Foundation
import MountainCore

// MARK: Devices and descents

public enum PushEnvironment: String, Codable, Sendable, Hashable {
    case development, production
}

/// The notification set (`specs/11-SETUP-RELEASE.md` section 5): the `kind` of a
/// `push_outbox` row and of the push itself. Each one can be muted per user
/// (`notification_prefs`, 0018).
public enum PushKind: String, Codable, Sendable, Hashable, CaseIterable {
    case meetProposed = "meet.proposed"
    case meetAccepted = "meet.accepted"
    case meetDeclined = "meet.declined"
    case meetPartnerArrived = "meet.partner_arrived"
    case meetEnded = "meet.ended"
    case meetExpired = "meet.expired"
    case friendRequested = "friend.requested"
    case friendAccepted = "friend.accepted"
}

public enum DescentSource: String, Codable, Sendable, Hashable {
    case live, slopes, gpx, tcx, fit, healthkit
}

/// What the importing phone worked out about a descent, stored beside it as
/// `descents.stats` so the history can be drawn without the track
/// (`specs/02-DOMAIN.md` section 8). Everything is optional: a value the phone
/// could not measure is absent, never zero.
public struct DescentStatsRow: Hashable, Sendable, Codable {
    /// Trustworthy skiing on runs of one difficulty: the evidence pace
    /// calibration reads (`specs/08-ACTIVITY.md` section 4).
    public struct Pace: Hashable, Sendable, Codable {
        public var movingS: Double
        public var lengthM: Double

        public init(movingS: Double, lengthM: Double) {
            self.movingS = movingS
            self.lengthM = lengthM
        }

        private enum CodingKeys: String, CodingKey {
            case movingS = "moving_s"
            case lengthM = "length_m"
        }
    }

    public var verticalM: Double?
    public var distanceM: Double?
    public var topSpeedMS: Double?
    public var avgSpeedMS: Double?
    /// The run the descent was mostly on, named from the resort bundle.
    public var trailName: String?
    /// A `Difficulty` raw value.
    public var difficulty: String?
    /// False when the name is only the nearest run, not a match.
    public var matched: Bool?
    /// The resort as the file or the catalog names it.
    public var resortName: String?
    /// The ski day at the resort, `yyyy-MM-dd`.
    public var localDay: String?
    /// The app or device that recorded it ("Slopes", "Garmin").
    public var sourceApp: String?
    /// Keyed by `Difficulty` raw value.
    public var pace: [String: Pace]?
    /// The `MatcherVersion` that named and paced the run; nil when no map
    /// was used, or before version 3, which is what marks a run for
    /// re-matching.
    public var matcherVersion: Int?

    public init(
        verticalM: Double? = nil, distanceM: Double? = nil, topSpeedMS: Double? = nil,
        avgSpeedMS: Double? = nil, trailName: String? = nil, difficulty: String? = nil,
        matched: Bool? = nil, resortName: String? = nil, localDay: String? = nil,
        sourceApp: String? = nil, pace: [String: Pace]? = nil, matcherVersion: Int? = nil
    ) {
        self.verticalM = verticalM
        self.distanceM = distanceM
        self.topSpeedMS = topSpeedMS
        self.avgSpeedMS = avgSpeedMS
        self.trailName = trailName
        self.difficulty = difficulty
        self.matched = matched
        self.resortName = resortName
        self.localDay = localDay
        self.sourceApp = sourceApp
        self.pace = pace
        self.matcherVersion = matcherVersion
    }

    private enum CodingKeys: String, CodingKey {
        case difficulty, matched, pace
        case matcherVersion = "matcher_version"
        case verticalM = "vertical_m"
        case distanceM = "distance_m"
        case topSpeedMS = "top_speed_ms"
        case avgSpeedMS = "avg_speed_ms"
        case trailName = "trail_name"
        case resortName = "resort_name"
        case localDay = "local_day"
        case sourceApp = "source_app"
    }
}

/// The `p_descent` argument of `descent_upsert`.
public struct DescentUpload: Hashable, Sendable, Codable {
    /// One element of `match.matched`, with the keys `descent_upsert` reads.
    public struct MatchedEdge: Hashable, Sendable, Codable {
        public var edgeID: String
        public var enterAt: Date
        public var exitAt: Date
        public var movingS: Double
        public var lengthM: Double
        /// The edge's difficulty in the bundle it was matched to, so the
        /// server's pace model can compare like with like (migration 0015).
        public var difficulty: String?

        public init(
            edgeID: String, enterAt: Date, exitAt: Date, movingS: Double, lengthM: Double,
            difficulty: String? = nil
        ) {
            self.edgeID = edgeID
            self.enterAt = enterAt
            self.exitAt = exitAt
            self.movingS = movingS
            self.lengthM = lengthM
            self.difficulty = difficulty
        }

        private enum CodingKeys: String, CodingKey {
            case edgeID = "edge_id"
            case enterAt = "enter_at"
            case exitAt = "exit_at"
            case movingS = "moving_s"
            case lengthM = "length_m"
            case difficulty
        }
    }

    public struct Match: Hashable, Sendable, Codable {
        public var bundleID: String
        public var matcherVersion: Int
        public var matched: [MatchedEdge]
        public var coverage: Double?
        public var confidence: Double?

        public init(
            bundleID: String, matcherVersion: Int, matched: [MatchedEdge],
            coverage: Double? = nil, confidence: Double? = nil
        ) {
            self.bundleID = bundleID
            self.matcherVersion = matcherVersion
            self.matched = matched
            self.coverage = coverage
            self.confidence = confidence
        }

        private enum CodingKeys: String, CodingKey {
            case matched, coverage, confidence
            case bundleID = "bundle_id"
            case matcherVersion = "matcher_version"
        }
    }

    public var source: DescentSource
    public var startedAt: Date
    public var endedAt: Date
    /// 64 lowercase hex characters.
    public var contentHash: String
    /// The gzipped track; sent as base64.
    public var track: Data
    public var resortID: String?
    public var device: String?
    public var appBuild: String?
    public var match: Match?
    public var stats: DescentStatsRow?

    public init(
        source: DescentSource, startedAt: Date, endedAt: Date, contentHash: String, track: Data,
        resortID: String? = nil, device: String? = nil, appBuild: String? = nil, match: Match? = nil,
        stats: DescentStatsRow? = nil
    ) {
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.contentHash = contentHash
        self.track = track
        self.resortID = resortID
        self.device = device
        self.appBuild = appBuild
        self.match = match
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case source, track, device, match, stats
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case contentHash = "content_hash"
        case resortID = "resort_id"
        case appBuild = "app_build"
    }
}

public struct DescentUpsertResult: Hashable, Sendable, Codable {
    public var descentID: UUID
    public var created: Bool

    public init(descentID: UUID, created: Bool) {
        self.descentID = descentID
        self.created = created
    }

    private enum CodingKeys: String, CodingKey {
        case created
        case descentID = "descent_id"
    }
}

/// A `descents` row without its track.
/// What the run detail screen reads about one descent: the stored track
/// (`DescentTrackCodec` gzip) and the most recent match, as `descent_upsert`
/// stored them. Owner only, by RLS.
public struct DescentDetail: Hashable, Sendable {
    public var descentID: UUID
    public var track: Data?
    public var match: DescentUpload.Match?

    public init(descentID: UUID, track: Data?, match: DescentUpload.Match?) {
        self.descentID = descentID
        self.track = track
        self.match = match
    }
}

/// A stored descent with its track bytes as `descent_upsert` took them, for
/// the `.powdermeet` backup.
public struct DescentRecord: Hashable, Sendable {
    public var summary: DescentSummary
    /// `DescentTrackCodec` bytes.
    public var track: Data

    public init(summary: DescentSummary, track: Data) {
        self.summary = summary
        self.track = track
    }
}

public struct DescentSummary: Hashable, Sendable, Codable, Identifiable {
    public var descentID: UUID
    public var source: DescentSource
    public var startedAt: Date
    public var endedAt: Date
    public var contentHash: String
    public var resortID: String?
    public var device: String?
    public var stats: DescentStatsRow?

    public var id: UUID { descentID }

    public static let columns = "descent_id,source,started_at,ended_at,content_hash,resort_id,device,stats"

    public init(
        descentID: UUID, source: DescentSource, startedAt: Date, endedAt: Date,
        contentHash: String, resortID: String? = nil, device: String? = nil,
        stats: DescentStatsRow? = nil
    ) {
        self.descentID = descentID
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.contentHash = contentHash
        self.resortID = resortID
        self.device = device
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case source, device, stats
        case descentID = "descent_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case contentHash = "content_hash"
        case resortID = "resort_id"
    }
}
