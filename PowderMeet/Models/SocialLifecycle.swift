//
//  SocialLifecycle.swift
//  PowderMeet
//
//  Pure typed states/events shared by friendship, meet-request and live
//  transport services. Database wire values remain unchanged.
//

import Foundation

nonisolated enum FriendshipStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case declined
    case expired
}

nonisolated enum MeetRequestStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case declined
    case expired

    var isTerminal: Bool {
        switch self {
        case .pending, .accepted: return false
        case .declined, .expired: return true
        }
    }
}

nonisolated enum MeetRequestTransition: Equatable, Sendable {
    case accept
    case decline
    case expire
}

nonisolated enum MeetRequestStateMachine {
    static func next(
        from state: MeetRequestStatus,
        on event: MeetRequestTransition
    ) -> MeetRequestStatus? {
        switch (state, event) {
        case (.pending, .accept): return .accepted
        case (.pending, .decline): return .declined
        case (.pending, .expire), (.accepted, .expire): return .expired
        default: return nil
        }
    }
}

nonisolated enum ActiveMeetPollAction: Equatable, Sendable {
    case updateETA
    case endMeet
    case ignore
}

nonisolated enum ActiveMeetPollClassifier {
    /// Realtime is the fast path; this classification powers the independent
    /// polling safety net for an already-accepted meetup.
    static func action(
        status: MeetRequestStatus,
        expiresAt: Date?,
        now: Date
    ) -> ActiveMeetPollAction {
        switch status {
        case .accepted: return .updateETA
        case .expired, .declined: return .endMeet
        case .pending:
            if let expiresAt, expiresAt <= now { return .endMeet }
            return .ignore
        }
    }
}

nonisolated enum RealtimeSubscriptionState: Equatable, Sendable {
    case stopped
    case connecting(channelName: String)
    case listening(channelName: String)
    case stopping(channelName: String?)

    var channelName: String? {
        switch self {
        case .stopped: return nil
        case .connecting(let name), .listening(let name): return name
        case .stopping(let name): return name
        }
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    func canBegin(channelName: String, forceReconnect: Bool = false) -> Bool {
        switch self {
        case .stopped:
            return true
        case .connecting:
            return false
        case .listening(let current):
            return forceReconnect || current != channelName
        case .stopping:
            return false
        }
    }
}

nonisolated enum LiveTransportState: Equatable, Sendable {
    case stopped
    case connecting(resortID: String)
    case live(resortID: String)
    case stopping(resortID: String?)

    var resortID: String? {
        switch self {
        case .stopped: return nil
        case .connecting(let id), .live(let id): return id
        case .stopping(let id): return id
        }
    }

    func canStart(resortID: String) -> Bool {
        switch self {
        case .stopped:
            return true
        case .live(let current):
            return current != resortID
        case .connecting, .stopping:
            return false
        }
    }
}
