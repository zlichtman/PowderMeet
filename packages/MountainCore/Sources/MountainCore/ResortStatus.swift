import Foundation

public enum GroupState: String, Codable, Sendable, Hashable {
    case open, closed, hold
    /// No live information for this lift: use its operating hours.
    case scheduled
}

public enum StatusSource: String, Codable, Sendable, Hashable {
    case epic, mtnpowder, liftie, scheduled
}

/// How far a status row can be trusted at a given instant.
public enum StatusFreshness: String, Codable, Sendable, Hashable {
    /// Before `expires_at`.
    case fresh
    /// Up to six hours past `expires_at`: closures are still honoured.
    case stale
    /// Older than that, or no row at all.
    case unavailable

    public static let staleWindow: TimeInterval = 6 * 60 * 60

    public static func of(_ status: ResortStatus?, at now: Date) -> StatusFreshness {
        guard let status else { return .unavailable }
        if now < status.expiresAt { return .fresh }
        if now < status.expiresAt.addingTimeInterval(staleWindow) { return .stale }
        return .unavailable
    }
}

/// Operational status for one resort: a solve input with an expiry. It never
/// changes graph topology (invariant I-18).
public struct ResortStatus: Hashable, Sendable, Codable {
    public var resortID: String
    public var observedAt: Date
    public var expiresAt: Date
    public var source: StatusSource
    public var groups: [GroupID: GroupState]
    public var groomed: [GroupID]
    /// Live queue at a lift, in minutes, as the provider reported it at
    /// `observedAt`. Only lifts that are open or on hold have one; a lift with
    /// none is priced on the modelled queue, as before live waits existed.
    public var waitMinutes: [GroupID: Double]

    public init(
        resortID: String, observedAt: Date, expiresAt: Date, source: StatusSource,
        groups: [GroupID: GroupState], groomed: [GroupID] = [], waitMinutes: [GroupID: Double] = [:]
    ) {
        self.resortID = resortID
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.source = source
        self.groups = groups
        self.groomed = groomed
        self.waitMinutes = waitMinutes
    }

    public func freshness(at now: Date) -> StatusFreshness { .of(self, at: now) }

    private enum CodingKeys: String, CodingKey {
        case source, groups, groomed
        case resortID = "resort_id"
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
        case waitMinutes = "wait_minutes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resortID = try c.decode(String.self, forKey: .resortID)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        source = try c.decode(StatusSource.self, forKey: .source)
        groups = try c.decode([GroupID: GroupState].self, forKey: .groups)
        groomed = try c.decodeIfPresent([GroupID].self, forKey: .groomed) ?? []
        // Rows written before migration 0014, and cached copies of them, have none.
        waitMinutes = try c.decodeIfPresent([GroupID: Double].self, forKey: .waitMinutes) ?? [:]
    }

    /// Decodes a status document with the pack's timestamp format.
    public static func decode(_ json: Data) throws -> ResortStatus {
        try BundleCoding.decoder().decode(ResortStatus.self, from: json)
    }
}
