//
//  CompactRouteSummary.swift
//  PowderMeet
//
//  Single-line compact bar shown at the top of the Map tab during an active
//  meetup. Replaces the large RouteCard with: meeting point name, both ETAs,
//  a progress bar, and an END button.
//

import SwiftUI
import CoreLocation

struct CompactRouteSummary: View {
    @State private var isConfirmingEnd = false

    let session: ActiveMeetSession
    let graph: MountainGraph?
    /// Optional nav VM — when present, renders the next-maneuver row above
    /// the meeting summary. Phase 8.1.
    var navigationVM: NavigationViewModel?
    /// Signal age for the meetup partner. A stale or cold fix must remain
    /// visible so an old friend ETA is never mistaken for live tracking.
    var friendSignalQuality: FriendSignalQuality?
    /// Latest accepted live/last-known coordinate for the active partner.
    /// Arrival remains fail-closed when no coordinate is available.
    var friendLocation: RealtimeLocationService.FriendLocation?
    let onEnd: () -> Void

    private var meetingName: String {
        if let curated = session.meetingResult.meetingDisplayName,
           !curated.isEmpty {
            return curated
        }
        if let landmark = session.meetingResult.rendezvousPoint?.displayName,
           !landmark.isEmpty {
            return landmark
        }
        // Pre-graph state: render a readable placeholder rather than a raw ID.
        guard let g = graph else { return "Meeting Point" }
        return MountainNaming(g).meetingNodeLabel(session.meetingNodeId)
    }

    private var rendezvousKind: RendezvousPoint.Kind? {
        if let kind = session.meetingResult.rendezvousPoint?.kind { return kind }
        switch graph?.nodes[session.meetingNodeId]?.kind {
        case .liftBase: return .liftBase
        case .midStation: return .midStation
        default: return nil
        }
    }

    private var progress: Double {
        session.routeTracker?.progress ?? 0
    }

    /// `isComplete` is driven exclusively by `update(location:)` now — an
    /// empty path no longer auto-completes on init, so this is safe to
    /// forward directly.
    private var isComplete: Bool {
        session.routeTracker?.isComplete ?? false
    }

    private var isOffRoute: Bool {
        session.routeTracker?.isOffRoute ?? false
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

    var body: some View {
        VStack(spacing: 0) {
            if session.guidanceStatus == nil, let maneuver = navigationVM?.currentManeuver {
                nextManeuverRow(maneuver)
            }
            meetingHeader
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // ── Your progress (distance-weighted along path in RouteProgressTracker) ──
            HStack {
                Text("YOUR PROGRESS")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.55))
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(HUDTheme.cardBorder.opacity(0.45))

                    Rectangle()
                        .fill(progressColor)
                        .frame(width: geo.size.width * progress)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 4)

            // ── Status line (only when off-route or complete) ──
            if let guidanceStatus = session.guidanceStatus {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.accentAmber)
                    // The transient banner reports the in-flight automatic
                    // same-meeting reroute; this persistent line describes
                    // the current tracker state without pretending recovery
                    // has already succeeded.
                    Text(guidanceStatus)
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.accentAmber)
                        .tracking(1)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .transition(.opacity)
            } else if isComplete || friendHasArrived {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.accentGreen)
                    Text(arrivalStatusCopy)
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.accentGreen)
                        .tracking(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .background(HUDTheme.headerBackground)
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
        .animation(.easeInOut(duration: 0.2), value: isOffRoute)
        .animation(.easeInOut(duration: 0.2), value: isComplete)
        .animation(.easeInOut(duration: 0.2), value: friendHasArrived)
        .confirmationDialog(
            "END POWDERMEET?",
            isPresented: $isConfirmingEnd,
            titleVisibility: .visible
        ) {
            Button("End Meetup", role: .destructive) {
                onEnd()
            }
            Button("Keep Navigating", role: .cancel) {}
        } message: {
            Text("This ends the shared route for you and \(session.friendName).")
        }
    }

    // MARK: - Subviews

    /// Keep the default header compact, but stop compressing the destination
    /// or either skier's ETA when Dynamic Type reaches accessibility sizes.
    /// A chairlift HUD can grow vertically; losing the landmark cannot be the
    /// tradeoff for readable text.
    @ViewBuilder
    private var meetingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            meetingIdentity
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 10) {
                adaptiveEtaPair
                    .frame(maxWidth: .infinity, alignment: .leading)
                endButton.fixedSize()
            }
        }
    }

    private var meetingIdentity: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rendezvousKind?.systemImageName ?? "mappin.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(isComplete ? HUDTheme.accentGreen : HUDTheme.routeMeeting)
                .accessibilityHidden(true)
            Text(meetingName.uppercased())
                .hudType(.label)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.5)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meet at \(meetingName)")
    }

    private var etaPair: some View {
        HStack(spacing: 12) {
            etaLabel(
                "YOU",
                time: session.meetingResult.timeA,
                color: HUDTheme.routeSkierA,
                hasArrived: isComplete,
                guidanceETAStatus: session.guidanceETAStatus
            )
            etaLabel(
                session.friendName.uppercased(),
                time: session.meetingResult.timeB,
                color: HUDTheme.routeSkierB,
                signalQuality: friendSignalQuality,
                isRemote: true,
                hasArrived: friendHasArrived
            )
        }
    }

    private var adaptiveEtaPair: some View {
        ViewThatFits(in: .horizontal) {
            etaPair.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 6) {
                etaLabel(
                    "YOU",
                    time: session.meetingResult.timeA,
                    color: HUDTheme.routeSkierA,
                    hasArrived: isComplete,
                    guidanceETAStatus: session.guidanceETAStatus
                )
                etaLabel(
                    session.friendName.uppercased(),
                    time: session.meetingResult.timeB,
                    color: HUDTheme.routeSkierB,
                    signalQuality: friendSignalQuality,
                    isRemote: true,
                    hasArrived: friendHasArrived
                )
            }
        }
    }

    private var endButton: some View {
        Button {
            isConfirmingEnd = true
        } label: {
            Text("END")
                .hudType(.caption)
                .foregroundColor(HUDTheme.accentRed)
                .tracking(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(HUDTheme.accentRed.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                // Preserve the compact visual pill while giving the
                // destructive action a glove-friendly hit target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End meetup")
        .accessibilityHint("Asks for confirmation before ending the shared meetup")
    }

    /// Next-maneuver row (Phase 8.1). Shows the upcoming trail/lift with a
    /// directional icon, distance to the next transition, and the trail
    /// difficulty color chip.
    @ViewBuilder
    private func nextManeuverRow(_ maneuver: NavigationViewModel.Maneuver) -> some View {
        HStack(spacing: 10) {
            Image(systemName: maneuver.iconSymbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(maneuver.difficulty.map { HUDTheme.color(for: $0) } ?? HUDTheme.accent)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .stroke((maneuver.difficulty.map { HUDTheme.color(for: $0) } ?? HUDTheme.accent).opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(maneuver.verb)
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1.2)
                    Text(maneuver.primaryName)
                        .hudType(.section)
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.5)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if let to = maneuver.transitionTo, to != maneuver.primaryName {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(HUDTheme.secondaryText)
                        Text(to)
                            .hudType(.label)
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(0.5)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(Int(maneuver.remainingMeters))M")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                    if let diff = maneuver.difficulty {
                        Text("·")
                            .hudType(.label)
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                        Text(diff.displayName.uppercased())
                            .hudType(.label)
                            .foregroundColor(HUDTheme.color(for: diff))
                            .tracking(0.5)
                    }
                }
                if let nextDifficulty = maneuver.transitionDifficulty,
                   nextDifficulty != maneuver.difficulty {
                    Text("NEXT · \(nextDifficulty.displayName.uppercased())")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.color(for: nextDifficulty))
                        .tracking(0.5)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HUDTheme.headerBackground.opacity(0.95))
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func etaLabel(
        _ label: String,
        time: Double,
        color: Color,
        signalQuality: FriendSignalQuality? = nil,
        isRemote: Bool = false,
        hasArrived: Bool = false,
        guidanceETAStatus: String? = nil
    ) -> some View {
        let signalPresentation = ActiveETASignalPresentation(
            isRemote: isRemote,
            quality: signalQuality
        )
        return VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            if let context = signalPresentation.estimateContext {
                Text(context)
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(guidanceETAStatus ?? (isRemote
                    ? MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: time, hasArrived: hasArrived) ?? UnitFormatter.formatTime(time)
                    : hasArrived ? "ARRIVED" : UnitFormatter.formatTime(time)))
                    .hudType(.caption)
                    .foregroundColor(color.opacity(
                        signalPresentation.isLive ? 1 : 0.65
                    ))
                    .lineLimit(nil)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let signalCopy = signalPresentation.statusText {
                Text(signalCopy)
                    .hudType(.caption)
                    .foregroundColor(signalColor(for: signalQuality))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var arrivalStatusCopy: String {
        if isComplete && friendHasArrived {
            return "YOU'RE BOTH NEAR THE MEETING POINT"
        }
        if friendHasArrived {
            return "\(session.friendName.uppercased()) IS NEAR THE MEETING POINT"
        }
        return "YOU ARE AT THE MEETING POINT"
    }

    private func signalCopy(for quality: FriendSignalQuality?) -> String? {
        FriendSignalPresentation(quality: quality).statusText
    }

    private func signalColor(for quality: FriendSignalQuality?) -> Color {
        switch FriendSignalPresentation(quality: quality).tone {
        case .live: return HUDTheme.accentGreen
        case .stale: return HUDTheme.accentAmber
        case .unavailable: return HUDTheme.secondaryText
        }
    }

    // MARK: - Helpers

    private var progressColor: Color {
        if session.guidanceStatus != nil { return HUDTheme.accentAmber }
        if isComplete { return HUDTheme.accentGreen }
        return HUDTheme.accent
    }

}
