//
//  ActiveMeetSession.swift
//  PowderMeet
//
//  Tracks an in-progress meetup after a meet request has been accepted.
//  Stored in ContentView state; drives the map route overlay, compact
//  route summary, and auto-advancing EdgeInfoCard navigation.
//

import Foundation

nonisolated enum ActiveMeetParticipantRole: Equatable, Sendable {
    case sender
    case receiver

    /// The database keeps ETA columns in original request roles while every
    /// activated local session presents the current device as skier A.
    /// Centralizing the translation prevents a receiver from overwriting the
    /// sender's ETA when broadcasting local progress.
    func etaUpdate(localETA: Double) -> (sender: Double?, receiver: Double?) {
        switch self {
        case .sender: return (localETA, nil)
        case .receiver: return (nil, localETA)
        }
    }

    func partnerETA(senderETA: Double?, receiverETA: Double?) -> Double? {
        switch self {
        case .sender: return receiverETA
        case .receiver: return senderETA
        }
    }
}

/// Immutable mountain identity an activated meetup was validated against.
/// Operational status may refresh while the identity stays equal; switching
/// resort or canonical dataset invalidates every stored edge/node reference.
nonisolated struct ActiveMeetDatasetIdentity: Equatable, Sendable {
    let resortID: String
    let datasetVersion: String

    /// A pre-release test meet on a frozen preview map (`PreviewMeetupPolicy`).
    var isPreview: Bool { PreviewMeetupPolicy.isPreviewIdentity(datasetVersion) }

    func matches(dataset: MountainDataset, graph: MountainGraph) -> Bool {
        dataset.source == (isPreview ? .legacySnapshot : .canonicalServer)
            && dataset.resortID == resortID
            && dataset.version.identifier == datasetVersion
            && graph.resortID == resortID
    }
}

nonisolated enum ActiveRouteRecoveryState: Equatable, Sendable {
    case ready
    case recalculating
    case unavailable

    func guidanceStatus(isOffRoute: Bool) -> String? {
        switch self {
        case .recalculating: return "RECALCULATING ROUTE"
        case .unavailable: return "ROUTE UNAVAILABLE — DIRECTIONS PAUSED"
        case .ready: return isOffRoute ? "OFF ROUTE — DIRECTIONS PAUSED" : nil
        }
    }

    func etaStatus(isOffRoute: Bool) -> String? {
        switch self {
        case .recalculating: return "UPDATING"
        case .unavailable: return "UNAVAILABLE"
        case .ready: return isOffRoute ? "OFF ROUTE" : nil
        }
    }
}

struct ActiveMeetSession: Identifiable {
    let id: UUID                        // meet request ID
    let friendProfile: UserProfile
    let localRole: ActiveMeetParticipantRole
    var meetingResult: MeetingResult
    let meetingNodeId: String
    let datasetIdentity: ActiveMeetDatasetIdentity
    let startedAt: Date
    /// Start of the currently displayed route plan. Reset after a reroute so
    /// future-position projections do not fast-forward through the new path
    /// using elapsed time from the original meetup activation.
    var routePlanStartedAt: Date
    /// Local presentation only; never written as a partner's route state.
    var routeRecoveryState: ActiveRouteRecoveryState = .ready

    var guidanceStatus: String? {
        routeRecoveryState.guidanceStatus(isOffRoute: routeTracker?.isOffRoute == true)
    }

    var guidanceETAStatus: String? {
        routeRecoveryState.etaStatus(isOffRoute: routeTracker?.isOffRoute == true)
    }

    /// Tracks the user's progress along their route (pathA).
    /// Nil until the session is fully activated with a graph.
    var routeTracker: RouteProgressTracker?

    /// Independent monotonic progress for the partner's accepted path. It is
    /// presentation/status-validation state only: this device never uses it
    /// to issue navigation decisions on the partner's behalf.
    var friendRouteTracker: RouteProgressTracker?

    /// Convenience: friend's display name
    var friendName: String { friendProfile.displayName }
}

nonisolated enum ActiveMeetupProgressCopy {
    static func subtitle(
        kindLabel: String?,
        localArrived: Bool,
        friendArrived: Bool,
        friendSignalIsLive: Bool,
        friendName: String,
        localETA: String,
        friendETA: String,
        togetherETA: String,
        friendArrivalUnconfirmed: Bool = false
    ) -> String {
        let status: String
        // A retained ETA or earlier arrival must not become a current promise
        // after reception drops. Keep local arrival independent of the partner.
        if !friendSignalIsLive {
            status = localArrived
                ? "YOU'VE ARRIVED · PARTNER UPDATE NEEDED"
                : "MEET TIME AWAITING PARTNER UPDATE"
        } else if friendArrivalUnconfirmed {
            status = localArrived
                ? "YOU'VE ARRIVED · PARTNER ARRIVAL UNCONFIRMED"
                : "PARTNER ARRIVAL UNCONFIRMED"
        } else {
            switch (localArrived, friendArrived) {
            case (true, true):
                status = "BOTH NEAR MEETING POINT"
            case (true, false):
                status = "EST. \(friendName.uppercased()) IN \(friendETA)"
            case (false, true):
                status = "PARTNER NEAR MEETING POINT · YOU IN \(localETA)"
            case (false, false):
                status = "EST. TOGETHER IN \(togetherETA)"
            }
        }
        guard let kindLabel, !kindLabel.isEmpty else { return status }
        return "\(kindLabel) · \(status)"
    }
}
