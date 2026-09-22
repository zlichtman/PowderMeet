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
        guard !isCrossResort else { return false }
        if request.datasetVersion != resortManager.currentDataset?.version.identifier {
            return true
        }
        guard let requestSnapshot = request.graphSnapshotDate,
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
                        syncDatasetAndAccept()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncingSnapshot {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.65)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(isSyncingSnapshot ? "VERIFYING MAP" : "ACCEPT")
                            .hudType(.label)
                            .tracking(0.5)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(HUDTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSyncingSnapshot)

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
                    .frame(minHeight: 44)
                    .background(HUDTheme.secondaryText.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(HUDTheme.secondaryText.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSyncingSnapshot)
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
            Button("Verify Map & Accept") { syncDatasetAndAccept() }
        } message: {
            Text("This meet is at \(requestResortName). PowderMeet will switch resorts and verify the exact trail map before accepting.")
        }
        .alert("Different trail map", isPresented: $showSnapshotMismatchConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Verify Their Map") { syncDatasetAndAccept() }
        } message: {
            let theirs = request.graphSnapshotDate ?? "—"
            let mine = resortManager.currentSnapshotDate ?? "—"
            Text("This request used trail map \(theirs); yours is \(mine). The exact sender map must be verified before a safe route can start.")
        }
    }

    /// Resolve the exact immutable sender dataset and fresh operational
    /// sidecar before changing the request to accepted. Handles both a resort
    /// switch and a same-resort version mismatch through the same gate.
    private func syncDatasetAndAccept() {
        guard !isSyncingSnapshot else { return }
        guard let requestedVersion = request.datasetVersion else {
            errorMessage = "This request came from an older app version. Ask your friend to send a new meet."
            return
        }
        guard let entry = ResortEntry.catalog.first(where: { $0.id == request.resortId }) else {
            errorMessage = "This request uses a mountain that is not available in this app version."
            return
        }
        isSyncingSnapshot = true
        Task {
            let alreadyExact = resortManager.currentEntry?.id == request.resortId
                && resortManager.currentDataset?.version.identifier == requestedVersion
            if !alreadyExact {
                await resortManager.loadResort(
                    entry,
                    snapshotOverride: request.graphSnapshotDate,
                    manifestVersionOverride: request.manifestVersion,
                    datasetVersionOverride: requestedVersion
                )
            }

            guard resortManager.currentEntry?.id == request.resortId,
                  let dataset = resortManager.currentDataset,
                  dataset.source == .canonicalServer,
                  dataset.version.identifier == requestedVersion,
                  let graph = resortManager.currentGraph,
                  graph.nodes[request.meetingNodeId] != nil,
                  dataset.rendezvousCatalog.nodeIDs.contains(request.meetingNodeId),
                  resortManager.currentStatus?.isRoutable() == true else {
                isSyncingSnapshot = false
                errorMessage = resortManager.currentStatus?.operatingMode == .offSeason
                    ? "This mountain is off season, so the meet can't start."
                    : "Couldn't verify the sender's live trail map. The request was not accepted."
                return
            }
            do {
                try await meetRequestService.acceptRequest(request.id)
                isSyncingSnapshot = false
                onMeetAccepted?(request)
            } catch {
                isSyncingSnapshot = false
                errorMessage = "Couldn't accept: \(error.localizedDescription)"
            }
        }
    }
}
