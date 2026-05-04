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

    /// True when the request is at a different resort than the user's
    /// currently-loaded one. Accepting means we'll switch resorts —
    /// reload graph, swap presence channels, point the camera at a
    /// new mountain. Worth a confirm so the user knows what's about
    /// to happen.
    private var isCrossResort: Bool {
        guard let current = resortManager.currentEntry else { return false }
        return current.id != request.resortId
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
        // resolution only if the request is missing one.
        let meetingName = request.meetingNodeDisplayName
            ?? graph.map { MountainNaming($0).nodeLabel(request.meetingNodeId, style: .canonical) }
            ?? "Meeting Point"
        let senderName = friendService.friends.first { $0.id == request.senderId }?.displayName ?? "Friend"

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.system(size: 14))
                    .foregroundColor(HUDTheme.accentAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(senderName.uppercased()) WANTS TO MEET")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                    Text("AT \(meetingName.uppercased()) \u{00B7} \(UnitFormatter.elevation(request.meetingNodeElevation))")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Button {
                    if isCrossResort {
                        showCrossResortConfirm = true
                    } else {
                        performAccept()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("ACCEPT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
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
        .alert("ERROR", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("DIFFERENT RESORT", isPresented: $showCrossResortConfirm) {
            Button("CANCEL", role: .cancel) {}
            Button("ACCEPT & SWITCH") { performAccept() }
        } message: {
            Text("This meet is at \(requestResortName) — accepting will switch your map and presence to that resort.")
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
