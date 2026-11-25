import Foundation

// The friend card, add codes and reports (migrations 0016 and 0017).

/// A skier's lifetime totals, as a friend's snapshot entry carries them. The
/// server sums the `descents.stats` the importing phones stored, the same way
/// `ActivityHistory` totals the user's own runs, so the four numbers on a
/// friend's card mean what they mean on one's own.
public struct LifetimeStats: Hashable, Sendable, Codable {
    public var runs: Int
    public var days: Int
    public var distanceM: Double
    public var verticalM: Double
    /// Nil until a run measured one.
    public var topSpeedMS: Double?
    /// Distance over moving time on the runs that have both; nil without one.
    public var avgSpeedMS: Double?

    public init(
        runs: Int = 0, days: Int = 0, distanceM: Double = 0, verticalM: Double = 0,
        topSpeedMS: Double? = nil, avgSpeedMS: Double? = nil
    ) {
        self.runs = runs
        self.days = days
        self.distanceM = distanceM
        self.verticalM = verticalM
        self.topSpeedMS = topSpeedMS
        self.avgSpeedMS = avgSpeedMS
    }

    /// The server's sum over descent rows (`lifetime_stats` in 0016), for the
    /// fake backend and for checking that the two agree.
    public init(_ rows: [DescentSummary]) {
        var totals = LifetimeStats()
        var days: Set<String> = []
        var movingDistance = 0.0
        var movingSeconds = 0.0
        let utc = DateFormatter()
        utc.calendar = Calendar(identifier: .gregorian)
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        utc.dateFormat = "yyyy-MM-dd"
        for row in rows {
            let stats = row.stats ?? DescentStatsRow()
            totals.runs += 1
            days.insert("\(stats.resortName ?? "")|\(stats.localDay ?? utc.string(from: row.startedAt))")
            totals.distanceM += stats.distanceM ?? 0
            totals.verticalM += stats.verticalM ?? 0
            if let top = stats.topSpeedMS { totals.topSpeedMS = max(totals.topSpeedMS ?? top, top) }
            let duration = row.endedAt.timeIntervalSince(row.startedAt)
            if let distance = stats.distanceM, distance > 0, duration > 0 {
                movingDistance += distance
                movingSeconds += stats.avgSpeedMS.flatMap { $0 > 0 ? distance / $0 : nil } ?? duration
            }
        }
        totals.days = days.count
        if movingSeconds > 0 { totals.avgSpeedMS = movingDistance / movingSeconds }
        self = totals
    }

    private enum CodingKeys: String, CodingKey {
        case runs, days
        case distanceM = "distance_m"
        case verticalM = "vertical_m"
        case topSpeedMS = "top_speed_ms"
        case avgSpeedMS = "avg_speed_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 0
        distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM) ?? 0
        verticalM = try c.decodeIfPresent(Double.self, forKey: .verticalM) ?? 0
        topSpeedMS = try c.decodeIfPresent(Double.self, forKey: .topSpeedMS)
        avgSpeedMS = try c.decodeIfPresent(Double.self, forKey: .avgSpeedMS)
    }
}

/// A friend's last position inside the presence TTL: which resort, and when.
/// Never coordinates; those stay in `presence` behind its policy.
public struct LastSeen: Hashable, Sendable, Codable {
    /// Nil when the phone reported no resort.
    public var resortID: String?
    /// The sender's capture time.
    public var at: Date

    public init(resortID: String?, at: Date) {
        self.resortID = resortID
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case resortID = "resort_id"
    }
}

// MARK: Search by name

/// How someone found by name relates to the caller (`search_users.relation`).
/// The caller is never in the results, so there is no "self".
public enum SearchRelation: String, Hashable, Sendable, Codable {
    case friend
    case requestSent = "request_sent"
    case requestReceived = "request_received"
    case none
}

/// One row of `search_users` (0019): who, their photo path, and the relation.
/// Nothing else about a person comes back from search.
public struct UserSearchResult: Hashable, Sendable, Codable, Identifiable {
    public var userID: UUID
    public var displayName: String
    public var avatarURL: String?
    public var relation: SearchRelation

    public var id: UUID { userID }

    public init(userID: UUID, displayName: String, avatarURL: String? = nil, relation: SearchRelation) {
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.relation = relation
    }

    private enum CodingKeys: String, CodingKey {
        case relation
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

/// The rules `search_users` applies to a query, so the phone can skip a call
/// that would return nothing.
public enum UserSearch {
    /// The most rows one search returns.
    public static let limit = 20

    /// The query as the server compares it: normalised like a display name,
    /// lower-cased. Nil when it is under 2 or over 24 characters, which no
    /// name can match.
    public static func query(_ raw: String) -> String? {
        let query = DisplayName.normalize(raw).lowercased()
        let count = DisplayName.length(query)
        guard count >= DisplayName.minLength, count <= DisplayName.maxLength else { return nil }
        return query
    }
}

// MARK: Reports

/// Why a user is reported (`user_reports.reason`).
public enum ReportReason: String, Hashable, Sendable, Codable, CaseIterable {
    case inappropriatePhoto = "inappropriate_photo"
    case inappropriateName = "inappropriate_name"
    case harassment
    case spam
    case impersonation
    case other
}

/// Where in the app the report was made (`user_reports.context`).
public enum ReportContext: String, Hashable, Sendable, Codable {
    case friend, request, contact, code
}

/// The longest note a report may carry.
public let reportNoteLimit = 500

// MARK: Avatars

public enum AvatarPath {
    /// The side of the square JPEG the app uploads.
    public static let pixelSize = 512

    /// `<lowercased user id>/<new name>.jpg`: a new object for every upload, so
    /// a cached image is never stale (the path names the bytes). Postgres and
    /// the storage policy compare against the lower-case uuid.
    public static func new(for user: UUID) -> String {
        "\(user.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
    }

    /// The caller's folder in the `avatars` bucket.
    public static func folder(of user: UUID) -> String { user.uuidString.lowercased() }

    /// What `profile_update` accepts for `avatar_url`: a file directly under the
    /// user's own folder, 1 to 80 characters of letters, digits, `.`, `_`, `-`.
    public static func isValid(_ path: String, for user: UUID) -> Bool {
        let prefix = folder(of: user) + "/"
        guard path.hasPrefix(prefix) else { return false }
        return isFileName(path.dropFirst(prefix.count))
    }

    /// True for any path `profile_update` could have stored: a lower-case
    /// user id, a slash and a file name, and nothing that leaves a folder.
    public static func isWellFormed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let user = UUID(uuidString: String(parts[0])),
              String(parts[0]) == folder(of: user) else { return false }
        return isFileName(parts[1]) && parts[1] != "." && parts[1] != ".."
    }

    private static func isFileName(_ file: Substring) -> Bool {
        (1...80).contains(file.count) && file.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}
