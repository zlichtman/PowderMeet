//
//  ActiveMeetSession.swift
//  PowderMeet
//
//  Tracks an in-progress meetup after a meet request has been accepted.
//  Stored in ContentView state; drives the map route overlay, compact
//  route summary, and auto-advancing EdgeInfoCard navigation.
//

import Foundation

struct ActiveMeetSession: Identifiable {
    let id: UUID                        // meet request ID
    let friendProfile: UserProfile
    var meetingResult: MeetingResult
    let meetingNodeId: String
    let startedAt: Date

    /// Tracks the user's progress along their route (pathA).
    /// Nil until the session is fully activated with a graph.
    var routeTracker: RouteProgressTracker?

    /// Convenience: friend's display name
    var friendName: String { friendProfile.displayName }
}
