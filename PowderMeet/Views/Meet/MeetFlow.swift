//
//  MeetFlow.swift
//  PowderMeet
//
//  @Observable owner of the cross-section state MeetView used to keep
//  as ~9 @State vars. Centralizing here lets `solveMeeting`,
//  `handleFriendTap`, and the various .onChange watchers mutate one
//  observable instance instead of fanning out across separate @State
//  bindings — the same simplification ContentCoordinator applied to
//  ContentView's lifecycle state.
//
//  Pure local UI (drawer expand, tab pick, solve debouncer) stays on
//  @State in MeetView — this class is for the state that's actually
//  shared with subviews or read across the heavy logic.
//

import Foundation
import Observation

@Observable
@MainActor
final class MeetFlow {
    /// Currently selected friend in the picker drawer / sender flow.
    /// `nil` = no friend tapped (idle state with the "TAP A FRIEND BELOW"
    /// hint). Driven by `handleFriendTap` and reset by active-meetup
    /// transitions + the friend-position watcher.
    var selectedFriendId: UUID?

    /// Index into `[meetingNode] + alternates` of the card the user
    /// chose. `nil` means no choice yet — the action button stays
    /// disabled until they pick one.
    var selectedOptionIndex: Int?

    /// Page index for the meeting-options TabView. Subviews bind to it
    /// via `$flow.currentCardPage`.
    var currentCardPage: Int = 0

    /// True after the POWDERMEET button fires successfully and we're
    /// waiting for the friend to accept. Resets when a new solve runs
    /// or when active-meetup state changes.
    var requestSent = false

    /// Pre-fetched UserProfiles for each pending friend request,
    /// keyed by requesterId. Loaded eagerly so the request rows render
    /// names/avatars without waiting for a per-row fetch.
    var pendingProfiles: [UUID: UserProfile] = [:]

    /// Shown by the meeting options card when the solver returns nil.
    /// `nil` = no error to display.
    var solveErrorMessage: String?

    /// Full solver output with all alternates — preserved across
    /// "SHOW ROUTE ON MAP" taps. The map's `meetingResult` binding is
    /// only updated when the user explicitly taps SHOW ROUTE; this
    /// keeps the cards independent of map state.
    var fullMeetingResult: MeetingResult?

    /// Coarse fingerprint of the user's last-solved location (~11 m
    /// bucket). The `fixGeneration` watcher uses it to suppress
    /// re-solves when the user hasn't actually moved between bucket
    /// changes.
    var lastSolvedMyKey: String?

    /// Drives the meeting-options spinner state.
    var isSolving = false
}
