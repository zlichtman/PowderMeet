//
//  IncomingMeetRequestCard.swift
//  PowderMeet
//
//  Single incoming meet request card (ACCEPT/DECLINE).
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI

struct IncomingMeetRequestCard: View {
    @Environment(FriendService.self) private var friendService
    @Environment(ResortDataManager.self) private var resortManager
    @Environment(MeetRequestService.self) private var meetRequestService

    let request: MeetRequest
    var onMeetAccepted: ((MeetRequest) -> Void)?

    @State private var errorMessage: String?
    @State private var showCrossResortConfirm = false
    @State private var showSnapshotMismatchConfirm = false
    @State private var isSyncingSnapshot = false

    /// True when the request is at a different resort than the user's
    /// currently-loaded one. Accepting means we'll switch resorts —
    /// reload graph, swap presence channels, point the camera at a
    /// new mountain. Worth a confirm so the user knows what's about
    /// to happen.
    private var isCrossResort: Bool {
        guard let current = resortManager.currentEntry else { return false }
        return current.id != request.resortId
    }

    /// True when the request was solved against a different graph
    /// snapshot than the one the receiver currently has loaded.
    /// Topology can drift between snapshots (different app version's
    /// pinned date, stale cache predating a builder bump, fall-through
    /// to a different Overpass mirror) — the meeting_node_id from the
    /// sender's solve may resolve to a different node, or fail to
    /// resolve at all. Same-resort only — cross-resort path already
    /// has its own confirm + reload, layering both reads as noise.
    private var isSnapshotMismatch: Bool {
        guard !isCrossResort,
              let requestSnapshot = request.graphSnapshotDate,
              let currentSnapshot = resortManager.currentSnapshotDate else { return false }
        return requestSnapshot != currentSnapshot
    }

    /// Display name of the request's resort (for the confirm alert
    /// copy). Falls back to the raw id when the resort isn't in
    /// the catalog.
    private var requestResortName: String {
        ResortEntry.catalog.first(where: { $0.id == request.resortId })?.name
            ?? request.resortId
    }

    var body: some View {
        let graph = resortManager.currentGraph
        // Prefer the sender-stamped label (already canonical via
        // `MountainNaming.meetingNodeLabel`); fall back to local
        // resolution only if the request is missing one. Use
        // `meetingNodeLabelOrNil` so a node id the receiver's graph
        // doesn't know about falls through to "Meeting Point" instead
        // of leaking the raw node-key string.
        let meetingName = request.meetingNodeDisplayName
            ?? graph.flatMap { MountainNaming($0).meetingNodeLabelOrNil(request.meetingNodeId) }
            ?? "Meeting Point"
        let senderName = friendService.friends.first { $0.id == request.senderId }?.displayName ?? "Friend"

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.system(size: 14))
                    .foregroundColor(HUDTheme.accentAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(senderName.uppercased()) WANTS TO MEET")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                    Text("AT \(meetingName.uppercased()) \u{00B7} \(UnitFormatter.elevation(request.meetingNodeElevation))")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Snapshot mismatch warning — small inline badge above the
            // action buttons. Cross-resort path subsumes this (resort
            // switch will reload at the receiver's pinned date anyway),
            // so only render when we're on the same resort.
            if isSnapshotMismatch {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.accentAmber)
                    Text("DIFFERENT TRAIL MAP \u{00B7} \(request.graphSnapshotDate ?? "—") VS \(resortManager.currentSnapshotDate ?? "—")")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.accentAmber)
                        .tracking(0.6)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                Button {
                    if isCrossResort {
                        showCrossResortConfirm = true
                    } else if isSnapshotMismatch {
                        showSnapshotMismatchConfirm = true
                    } else {
                        performAccept()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("ACCEPT")
                            .hudType(.label)
                            .tracking(0.5)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(HUDTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        do {
                            try await meetRequestService.declineRequest(request.id)
                        } catch {
                            errorMessage = "Couldn't decline: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("DECLINE")
                            .hudType(.label)
                            .tracking(0.5)
                    }
                    .foregroundColor(HUDTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(HUDTheme.secondaryText.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(HUDTheme.secondaryText.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.accentAmber.opacity(0.3), lineWidth: 1)
        )
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Different resort", isPresented: $showCrossResortConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Accept & Switch") { performAccept() }
        } message: {
            Text("This meet is at \(requestResortName). Accepting will switch your map and presence to that resort.")
        }
        .alert("Different trail map", isPresented: $showSnapshotMismatchConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Use Their Map") { syncSnapshotAndAccept() }
            Button("Accept Anyway") { performAccept() }
        } message: {
            let theirs = request.graphSnapshotDate ?? "—"
            let mine = resortManager.currentSnapshotDate ?? "—"
            Text("This request was set up on trail map \(theirs); yours is \(mine). 'Use Their Map' reloads your view at their snapshot so the meeting point resolves identically. 'Accept Anyway' keeps yours — the meeting point and routes may shift slightly.")
        }
    }

    /// Reload the receiver's resort at the sender's snapshot date so
    /// both devices solve against the same topology, then accept.
    /// Same-resort only — `isSnapshotMismatch` already guarantees the
    /// resort id matches and the dates differ. The reload bypasses the
    /// in-memory + disk caches when the override differs from
    /// `currentSnapshotDate` (see `ResortDataManager.loadResort`),
    /// so the network round-trip is forced.
    private func syncSnapshotAndAccept() {
        guard let entry = resortManager.currentEntry,
              let theirs = request.graphSnapshotDate,
              !isSyncingSnapshot else { return }
        isSyncingSnapshot = true
        Task {
            await resortManager.loadResort(entry, snapshotOverride: theirs)
            isSyncingSnapshot = false
            // Bail if the load failed — `errorMessage` on the manager
            // already surfaces the failure to the map view; better to
            // stop the accept than complete it against a fall-through
            // graph the user wasn't expecting.
            guard resortManager.currentSnapshotDate == theirs else {
                errorMessage = "Couldn't load sender's trail map — accept skipped."
                return
            }
            performAccept()
        }
    }

    private func performAccept() {
        Task {
            do {
                try await meetRequestService.acceptRequest(request.id)
                onMeetAccepted?(request)
            } catch {
                errorMessage = "Couldn't accept: \(error.localizedDescription)"
            }
        }
    }
}
