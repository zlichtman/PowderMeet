//
//  ActiveMeetupCardView.swift
//  PowderMeet
//
//  The active meetup card with progress, VIEW ON MAP, END buttons.
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI
import CoreLocation

struct ActiveMeetupCardView: View {
    @State private var isConfirmingEnd = false

    let session: ActiveMeetSession
    let graph: MountainGraph?
    var friendSignalQuality: FriendSignalQuality?
    var friendLocation: RealtimeLocationService.FriendLocation?
    var onViewOnMap: () -> Void
    var onEndMeetup: () -> Void

    private var meetingName: String {
        if let curated = session.meetingResult.meetingDisplayName,
           !curated.isEmpty {
            return curated
        }
        if let landmark = session.meetingResult.rendezvousPoint?.displayName,
           !landmark.isEmpty {
            return landmark
        }
        guard let graph else { return "Meeting Point" }
        return MountainNaming(graph).meetingNodeLabel(session.meetingNodeId)
    }

    private var rendezvousKind: RendezvousPoint.Kind? {
        if let kind = session.meetingResult.rendezvousPoint?.kind { return kind }
        switch graph?.nodes[session.meetingNodeId]?.kind {
        case .liftBase: return .liftBase
        case .midStation: return .midStation
        default: return nil
        }
    }

    var body: some View {
        let path = session.meetingResult.pathA

        VStack(spacing: 0) {
            // Header: meeting point + friend name + ETAs
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: rendezvousKind?.systemImageName ?? "mappin.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.routeMeeting)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(meetingName.uppercased())
                            .hudType(.section)
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(0.5)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(activeMeetingSubtitle)
                            .hudType(.caption)
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(1)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        localETALabel.fixedSize(horizontal: true, vertical: false)
                        friendETALabel.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        localETALabel
                        friendETALabel
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            // Route steps (consolidated — collapses consecutive same-name edges)
            if !path.isEmpty && session.guidanceStatus == nil {
                let steps = RouteStepConsolidator.consolidate(path, graph: graph)
                let currentStepIdx = RouteStepConsolidator.consolidatedIndex(for: path, rawEdgeIndex: session.routeTracker?.currentEdgeIndex, graph: graph)
                let visibleStart = min(max(0, currentStepIdx ?? 0), max(0, steps.count - 1))
                let visibleEnd = min(steps.count, visibleStart + 3)
                let visibleSteps = Array(steps.enumerated())[visibleStart..<visibleEnd]
                let currentStep: RouteStep? = {
                    guard let idx = currentStepIdx, idx >= 0, idx < steps.count else { return nil }
                    return steps[idx]
                }()

                if let currentStep, currentStep.isLiftStep {
                    HStack(spacing: 8) {
                        Image(systemName: "cablecar.fill")
                            .font(.system(size: 14))
                            .foregroundColor(HUDTheme.accentAmber)

                        Text(liftRidingText(for: currentStep))
                            .hudType(.section)
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(0.5)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleSteps, id: \.offset) { idx, step in
                            let isCurrentStep = idx == currentStepIdx

                            HStack(spacing: 8) {
                                // Step number
                                Text("\(idx + 1)")
                                    .hudType(.caption)
                                    .foregroundColor(isCurrentStep ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.4))
                                    .frame(width: 14)

                                // Edge type icon
                                Image(systemName: step.icon)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(step.iconColor)

                                Text(step.name.uppercased())
                                    .hudType(isCurrentStep ? .bodyEmph : .body)
                                    .foregroundColor(isCurrentStep ? HUDTheme.primaryText : HUDTheme.secondaryText)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer()

                                if let diff = step.difficulty {
                                    Image(systemName: diff.icon)
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundColor(HUDTheme.color(for: diff))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isCurrentStep ? HUDTheme.accent.opacity(0.06) : Color.clear)

                            if idx < visibleEnd - 1 {
                                Rectangle()
                                    .fill(HUDTheme.cardBorder.opacity(0.3))
                                    .frame(height: 0.5)
                                    .padding(.leading, 36)
                                    .padding(.trailing, 14)
                            }
                        }

                        if visibleEnd < steps.count {
                            HStack(spacing: 6) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(steps.count - visibleEnd) MORE STEPS · VIEW MAP")
                                    .hudType(.label)
                                    .tracking(0.5)
                                Spacer()
                            }
                            .foregroundColor(HUDTheme.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }

            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            // Bottom: View on Map + End buttons
            HStack(spacing: 12) {
                Button {
                    onViewOnMap()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 9))
                        Text("VIEW ON MAP")
                            .hudType(.label)
                            .tracking(0.5)
                    }
                    .foregroundColor(HUDTheme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(HUDTheme.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    isConfirmingEnd = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("END")
                            .hudType(.label)
                            .tracking(0.5)
                    }
                    .foregroundColor(HUDTheme.accentRed)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(HUDTheme.accentRed.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End meetup")
                .accessibilityHint("Asks for confirmation before ending the shared meetup")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
        .confirmationDialog(
            "END POWDERMEET?",
            isPresented: $isConfirmingEnd,
            titleVisibility: .visible
        ) {
            Button("End Meetup", role: .destructive) {
                onEndMeetup()
            }
            Button("Keep Navigating", role: .cancel) {}
        } message: {
            Text("This ends the shared route for you and \(session.friendName).")
        }
    }

    // MARK: - Route Step Consolidation

    // MARK: - Helpers

    private var localETALabel: some View {
        participantETA(
            name: "YOU",
            value: session.guidanceETAStatus ?? (localHasArrived ? "ARRIVED" : formatETA(session.meetingResult.timeA)),
            color: HUDTheme.routeSkierA
        )
    }

    private var friendETALabel: some View {
        participantETA(
            name: session.friendName.uppercased(),
            value: MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: session.meetingResult.timeB,
                hasArrived: friendHasArrived) ?? formatETA(session.meetingResult.timeB),
            color: HUDTheme.routeSkierB,
            signal: friendSignalCopy,
            estimateContext: ActiveETASignalPresentation(isRemote: true, quality: friendSignalQuality).estimateContext
        )
    }

    private func participantETA(name: String, value: String, color: Color, signal: String? = nil, estimateContext: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText)
            if let estimateContext {
                Text(estimateContext)
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
            }
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(value).hudType(.label).foregroundColor(color)
            }
            if let signal {
                Text(signal).hudType(.caption).foregroundColor(friendSignalColor)
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func formatETA(_ seconds: Double) -> String {
        UnitFormatter.formatTime(seconds).uppercased()
    }

    private var activeMeetingSubtitle: String {
        if let status = session.guidanceStatus { return status }
        let latestArrival = max(
            session.meetingResult.timeA,
            session.meetingResult.timeB
        )
        return ActiveMeetupProgressCopy.subtitle(
            kindLabel: rendezvousKind?.userFacingLabel,
            localArrived: localHasArrived,
            friendArrived: friendHasArrived,
            friendSignalIsLive: friendSignalPresentation.isLive,
            friendName: session.friendName,
            localETA: formatETA(session.meetingResult.timeA),
            friendETA: formatETA(session.meetingResult.timeB),
            togetherETA: formatETA(latestArrival),
            friendArrivalUnconfirmed: MeetArrivalStatusClassifier.needsPartnerArrivalConfirmation(
                etaSeconds: session.meetingResult.timeB, hasArrived: friendHasArrived)
        )
    }

    private var localHasArrived: Bool {
        session.routeTracker?.isComplete == true
    }

    private var friendHasArrived: Bool {
        MeetArrivalStatusClassifier.partnerHasArrived(
            etaSeconds: session.meetingResult.timeB,
            signalQuality: friendSignalQuality,
            distanceToMeetingMeters: friendDistanceToMeetingMeters,
            capturedAt: friendLocation?.capturedAt,
            accuracyMeters: friendLocation?.accuracyMeters,
            locationResortID: friendLocation?.resortId,
            meetingResortID: session.datasetIdentity.resortID
        )
    }

    private var friendDistanceToMeetingMeters: CLLocationDistance? {
        let meetingCoordinate = session.meetingResult.meetingNode.coordinate
        guard let friendLocation, friendLocation.userId == session.friendProfile.id else { return nil }
        return CLLocation(
            latitude: friendLocation.latitude,
            longitude: friendLocation.longitude
        ).distance(from: CLLocation(
            latitude: meetingCoordinate.latitude,
            longitude: meetingCoordinate.longitude
        ))
    }

    private var friendSignalCopy: String? {
        friendSignalPresentation.statusText
    }

    private var friendSignalColor: Color {
        switch friendSignalPresentation.tone {
        case .live: return HUDTheme.accentGreen
        case .stale: return HUDTheme.accentAmber
        case .unavailable: return HUDTheme.secondaryText
        }
    }

    private var friendSignalPresentation: FriendSignalPresentation {
        FriendSignalPresentation(quality: friendSignalQuality)
    }

    private func liftRidingText(for step: RouteStep) -> String {
        let name = step.name.uppercased()
        guard let total = step.seconds else {
            return "RIDING \(name)"
        }
        let totalInt = Int(total.rounded())
        if totalInt < 60 {
            return "RIDING \(name) · ~\(totalInt)S"
        }
        let mins = (totalInt + 30) / 60
        return "RIDING \(name) · ~\(mins)M"
    }

}
