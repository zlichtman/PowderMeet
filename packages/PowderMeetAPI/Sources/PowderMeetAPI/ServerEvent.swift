import Foundation
import MountainCore

/// What the server tells a phone over Realtime. Events are hints: a session that
/// sees an inconsistent sequence re-reads through an RPC.
public enum ServerEvent: Hashable, Sendable {
    case meetProposed(Meet)
    case meetUpdated(Meet)
    case meetProgress(MeetProgress)
    case presence(Presence)
    case friendRequested(FriendEvent)
    case friendAccepted(FriendEvent)
    case friendRemoved(FriendEvent)
    case resortStatus(ResortStatus)
    /// Not sent by the server: the subscription rejoined after a drop, or skipped
    /// a frame this build could not read, so events may have been missed and
    /// state should be re-read.
    case reconnected
    /// A type this build does not know (additive protocol changes).
    case unknown(type: String)

    /// The event name used as both the broadcast event and the envelope `type`.
    public var type: String {
        switch self {
        case .meetProposed: "meet.proposed"
        case .meetUpdated: "meet.updated"
        case .meetProgress: "meet.progress"
        case .presence: "presence"
        case .friendRequested: "friend.requested"
        case .friendAccepted: "friend.accepted"
        case .friendRemoved: "friend.removed"
        case .resortStatus: "resort.status"
        case .reconnected: "reconnected"
        case .unknown(let type): type
        }
    }
}

/// `{ "v": 1, "type": "<type>", "at": "<server time>", "data": { ... } }`, as built
/// by `public.emit` in `0004_functions.sql`.
public struct ServerEventEnvelope: Hashable, Sendable {
    public static let supportedVersion = 1

    public var v: Int
    /// Server time.
    public var at: Date
    public var event: ServerEvent

    public init(v: Int = ServerEventEnvelope.supportedVersion, at: Date, event: ServerEvent) {
        self.v = v
        self.at = at
        self.event = event
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
    }

    private enum CodingKeys: String, CodingKey { case v, type, at, data }

    public static func decode(_ json: Data) throws -> ServerEventEnvelope {
        try WireCoding.decoder().decode(ServerEventEnvelope.self, from: json)
    }

    public func encoded() throws -> Data { try WireCoding.encoder().encode(self) }
}

extension ServerEventEnvelope: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == Self.supportedVersion else { throw DecodeError.unsupportedVersion(v) }
        at = try c.decode(Date.self, forKey: .at)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "meet.proposed": event = .meetProposed(try c.decode(Meet.self, forKey: .data))
        case "meet.updated": event = .meetUpdated(try c.decode(Meet.self, forKey: .data))
        case "meet.progress": event = .meetProgress(try c.decode(MeetProgress.self, forKey: .data))
        case "presence": event = .presence(try c.decode(Presence.self, forKey: .data))
        case "friend.requested": event = .friendRequested(try c.decode(FriendEvent.self, forKey: .data))
        case "friend.accepted": event = .friendAccepted(try c.decode(FriendEvent.self, forKey: .data))
        case "friend.removed": event = .friendRemoved(try c.decode(FriendEvent.self, forKey: .data))
        case "resort.status": event = .resortStatus(try c.decode(ResortStatus.self, forKey: .data))
        default: event = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(event.type, forKey: .type)
        try c.encode(at, forKey: .at)
        switch event {
        case .meetProposed(let meet), .meetUpdated(let meet): try c.encode(meet, forKey: .data)
        case .meetProgress(let progress): try c.encode(progress, forKey: .data)
        case .presence(let presence): try c.encode(presence, forKey: .data)
        case .friendRequested(let friend), .friendAccepted(let friend), .friendRemoved(let friend):
            try c.encode(friend, forKey: .data)
        case .resortStatus(let status): try c.encode(status, forKey: .data)
        case .reconnected, .unknown: try c.encode([String: String](), forKey: .data)
        }
    }
}
