//
//  CompactRouteSummary.swift
//  PowderMeet
//
//  Single-line compact bar shown at the top of the Map tab during an active
//  meetup. Replaces the large RouteCard with: meeting point name, both ETAs,
//  a progress bar, and an END button.
//

import SwiftUI

struct CompactRouteSummary: View {
    let session: ActiveMeetSession
    let graph: MountainGraph?
    /// Optional nav VM — when present, renders the next-maneuver row above
    /// the meeting summary. Phase 8.1.
    var navigationVM: NavigationViewModel?
    let onEnd: () -> Void

    private var meetingName: String {
        // Pre-graph state: render a readable placeholder rather than a
        // raw node id so the card never looks like it's leaking
        // coordinates. Once the graph is loaded, every consumer of a
        // node label routes through `MountainNaming.nodeLabel(.canonical)`
        // — same string the picker shows for the same node id.
        guard let g = graph else { return "Meeting Point" }
        return MountainNaming(g).nodeLabel(session.meetingNodeId, style: .canonical)
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

    var body: some View {
        VStack(spacing: 0) {
            if let maneuver = navigationVM?.currentManeuver {
                nextManeuverRow(maneuver)
            }
            HStack(spacing: 10) {
                // ── Meeting point icon ──
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isComplete ? HUDTheme.accentGreen : HUDTheme.routeMeeting)

                // ── Meeting point name ──
                Text(meetingName.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)

                Spacer()

                // ── ETAs ──
                HStack(spacing: 8) {
                    etaLabel("YOU", time: session.meetingResult.timeA, color: HUDTheme.routeSkierA)
                    etaLabel(session.friendName.uppercased(), time: session.meetingResult.timeB, color: HUDTheme.routeSkierB)
                }

                // ── End button ──
                Button(action: onEnd) {
                    Text("END")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.accentRed)
                        .tracking(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HUDTheme.accentRed.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // ── Your progress (distance-weighted along path in RouteProgressTracker) ──
            HStack {
                Text("YOUR PROGRESS")
                    .font(.system(size: 6, weight: .bold, design: .monospaced))
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
            if isOffRoute {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.accentAmber)
                    // Banner previously said "REROUTING..." which implied a
                    // recalculate was already running. It isn't — reroutes
                    // only start on an explicit RECALCULATE tap. "OFF ROUTE"
                    // reflects actual state without promising a fix the
                    // system isn't performing.
                    Text("OFF ROUTE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.accentAmber)
                        .tracking(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .transition(.opacity)
            } else if isComplete {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.accentGreen)
                    Text("YOU ARE AT THE MEETING POINT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
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
    }

    // MARK: - Subviews

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
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1.2)
                    Text(maneuver.primaryName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                    if let to = maneuver.transitionTo {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(HUDTheme.secondaryText)
                        Text(to)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(0.5)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(Int(maneuver.remainingMeters))M")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                    if let diff = maneuver.difficulty {
                        Text("·")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                        Text(diff.displayName.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.color(for: diff))
                            .tracking(0.5)
                    }
                }
            }
            Spacer()
        }
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

    private func etaLabel(_ label: String, time: Double, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(UnitFormatter.formatTime(time))")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
        }
    }

    // MARK: - Helpers

    private var progressColor: Color {
        if isOffRoute { return HUDTheme.accentAmber }
        if isComplete { return HUDTheme.accentGreen }
        return HUDTheme.accent
    }

}
