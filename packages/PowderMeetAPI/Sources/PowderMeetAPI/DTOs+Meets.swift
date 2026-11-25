import Foundation
import MountainCore

// MARK: Meets

public enum MeetStatus: String, Codable, Sendable, Hashable {
    case proposed, active, completed, declined, cancelled, expired, invalidated

    public var isTerminal: Bool { self != .proposed && self != .active }
}

public enum MeetEndReason: String, Codable, Sendable, Hashable {
    case arrived
    case declinedByUser = "declined_by_user"
    case declinedCannotRoute = "declined_cannot_route"
    case userCancelled = "user_cancelled"
    case timeout
    case rendezvousRemoved = "rendezvous_removed"
    case statusBlocksRoute = "status_blocks_route"
    case partnerLeft = "partner_left"
    case superseded
}

/// The reasons a client may pass to `meet_respond(accept = false)`.
public enum MeetDeclineReason: String, Codable, Sendable, Hashable {
    case declinedByUser = "declined_by_user"
    case declinedCannotRoute = "declined_cannot_route"
}

/// The reasons a client may pass to `meet_end`.
public enum MeetEndRequest: String, Codable, Sendable, Hashable {
    case arrived
    case userCancelled = "user_cancelled"
    case statusBlocksRoute = "status_blocks_route"
    case partnerLeft = "partner_left"
}

public struct Meet: Hashable, Sendable, Codable, Identifiable {
    public var meetID: UUID
    public var resortID: String
    /// Advisory: the bundle the proposer solved on.
    public var bundleID: String?
    public var rendezvousID: RendezvousID
    public var proposerID: UUID
    public var inviteeID: UUID
    public var status: MeetStatus
    public var endReason: MeetEndReason?
    public var proposerEtaS: Int?
    public var proposerEtaSdS: Int?
    public var inviteeEtaS: Int?
    public var inviteeEtaSdS: Int?
    public var createdAt: Date
    public var respondedAt: Date?
    public var endedAt: Date?
    public var expiresAt: Date
    public var supersededBy: UUID?
    /// The participant whose request ended the meet; nil while it is open, when the
    /// server ended it, and on a server that predates the column (specs/03 section 2).
    public var endedBy: UUID?

    public var id: UUID { meetID }

    public init(
        meetID: UUID, resortID: String, bundleID: String? = nil, rendezvousID: RendezvousID,
        proposerID: UUID, inviteeID: UUID, status: MeetStatus = .proposed,
        endReason: MeetEndReason? = nil, proposerEtaS: Int? = nil, proposerEtaSdS: Int? = nil,
        inviteeEtaS: Int? = nil, inviteeEtaSdS: Int? = nil, createdAt: Date,
        respondedAt: Date? = nil, endedAt: Date? = nil, expiresAt: Date, supersededBy: UUID? = nil,
        endedBy: UUID? = nil
    ) {
        self.meetID = meetID
        self.resortID = resortID
        self.bundleID = bundleID
        self.rendezvousID = rendezvousID
        self.proposerID = proposerID
        self.inviteeID = inviteeID
        self.status = status
        self.endReason = endReason
        self.proposerEtaS = proposerEtaS
        self.proposerEtaSdS = proposerEtaSdS
        self.inviteeEtaS = inviteeEtaS
        self.inviteeEtaSdS = inviteeEtaSdS
        self.createdAt = createdAt
        self.respondedAt = respondedAt
        self.endedAt = endedAt
        self.expiresAt = expiresAt
        self.supersededBy = supersededBy
        self.endedBy = endedBy
    }

    public func partner(of user: UUID) -> UUID { proposerID == user ? inviteeID : proposerID }

    public func involves(_ user: UUID) -> Bool { proposerID == user || inviteeID == user }

    private enum CodingKeys: String, CodingKey {
        case status
        case meetID = "meet_id"
        case resortID = "resort_id"
        case bundleID = "bundle_id"
        case rendezvousID = "rendezvous_id"
        case proposerID = "proposer_id"
        case inviteeID = "invitee_id"
        case endReason = "end_reason"
        case proposerEtaS = "proposer_eta_s"
        case proposerEtaSdS = "proposer_eta_sd_s"
        case inviteeEtaS = "invitee_eta_s"
        case inviteeEtaSdS = "invitee_eta_sd_s"
        case createdAt = "created_at"
        case respondedAt = "responded_at"
        case endedAt = "ended_at"
        case expiresAt = "expires_at"
        case supersededBy = "superseded_by"
        case endedBy = "ended_by"
    }
}

public enum MeetProgressState: String, Codable, Sendable, Hashable {
    case navigating, rerouting, arrived, lost
}

/// One participant's progress. `updatedAt` is absent from the realtime payload.
public struct MeetProgress: Hashable, Sendable, Codable {
    public var meetID: UUID
    public var userID: UUID
    public var etaS: Int?
    public var etaSdS: Int?
    public var remainingM: Int?
    public var state: MeetProgressState
    public var fixAt: Date
    public var updatedAt: Date?

    public init(
        meetID: UUID, userID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?,
        state: MeetProgressState, fixAt: Date, updatedAt: Date? = nil
    ) {
        self.meetID = meetID
        self.userID = userID
        self.etaS = etaS
        self.etaSdS = etaSdS
        self.remainingM = remainingM
        self.state = state
        self.fixAt = fixAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case meetID = "meet_id"
        case userID = "user_id"
        case etaS = "eta_s"
        case etaSdS = "eta_sd_s"
        case remainingM = "remaining_m"
        case fixAt = "fix_at"
        case updatedAt = "updated_at"
    }
}

// MARK: Presence

/// A friend's position. `receivedAt` and `appBuild` are absent from the realtime
/// payload; the row carries no display name (join it from the social snapshot).
public struct Presence: Hashable, Sendable, Codable {
    public var userID: UUID
    public var resortID: String?
    public var lon: Double
    public var lat: Double
    public var accuracyM: Double?
    public var speedMS: Double?
    public var headingDeg: Double?
    /// The sender's clock.
    public var capturedAt: Date
    /// The server's clock.
    public var receivedAt: Date?
    public var appBuild: String?

    public init(
        userID: UUID, resortID: String?, lon: Double, lat: Double, accuracyM: Double? = nil,
        speedMS: Double? = nil, headingDeg: Double? = nil, capturedAt: Date,
        receivedAt: Date? = nil, appBuild: String? = nil
    ) {
        self.userID = userID
        self.resortID = resortID
        self.lon = lon
        self.lat = lat
        self.accuracyM = accuracyM
        self.speedMS = speedMS
        self.headingDeg = headingDeg
        self.capturedAt = capturedAt
        self.receivedAt = receivedAt
        self.appBuild = appBuild
    }

    public var coordinate: Coordinate { Coordinate(lon: lon, lat: lat) }

    public var fix: Fix {
        Fix(coordinate: coordinate, accuracyM: accuracyM ?? 0, capturedAt: capturedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case lon, lat
        case userID = "user_id"
        case resortID = "resort_id"
        case accuracyM = "accuracy_m"
        case speedMS = "speed_ms"
        case headingDeg = "heading_deg"
        case capturedAt = "captured_at"
        case receivedAt = "received_at"
        case appBuild = "app_build"
    }
}

/// The arguments of `presence_update`.
public struct PresenceUpdate: Hashable, Sendable {
    public var resortID: String?
    public var lon: Double
    public var lat: Double
    public var accuracyM: Double?
    public var speedMS: Double?
    public var headingDeg: Double?
    public var capturedAt: Date

    public init(
        resortID: String?, lon: Double, lat: Double, accuracyM: Double? = nil,
        speedMS: Double? = nil, headingDeg: Double? = nil, capturedAt: Date
    ) {
        self.resortID = resortID
        self.lon = lon
        self.lat = lat
        self.accuracyM = accuracyM
        self.speedMS = speedMS
        self.headingDeg = headingDeg
        self.capturedAt = capturedAt
    }
}
