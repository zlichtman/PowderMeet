//
//  ActiveMeetupCardView.swift
//  PowderMeet
//
//  The active meetup card with progress, VIEW ON MAP, END buttons.
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI

struct ActiveMeetupCardView: View {
    let session: ActiveMeetSession
    let graph: MountainGraph?
    var onViewOnMap: () -> Void
    var onEndMeetup: () -> Void

    var body: some View {
        let meetingName = graph.map { MountainNaming($0).nodeLabel(session.meetingNodeId, style: .canonical) } ?? session.meetingNodeId
        let path = session.meetingResult.pathA

        VStack(spacing: 0) {
            // Header: meeting point + friend name + ETAs
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(HUDTheme.routeMeeting)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meetingName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.5)
                        .lineLimit(1)

                    Text("MEETING \(session.friendName.uppercased())")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                }

                Spacer()

                // ETAs
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 3) {
                        Circle().fill(HUDTheme.routeSkierA).frame(width: 5, height: 5)
                        Text("YOU \(formatETA(session.meetingResult.timeA))")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.routeSkierA)
                    }
                    HStack(spacing: 3) {
                        Circle().fill(HUDTheme.routeSkierB).frame(width: 5, height: 5)
                        Text("\(session.friendName.prefix(8).uppercased()) \(formatETA(session.meetingResult.timeB))")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.routeSkierB)
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
            if !path.isEmpty {
                let steps = RouteStepConsolidator.consolidate(path, graph: graph)
                let currentStepIdx = RouteStepConsolidator.consolidatedIndex(for: path, rawEdgeIndex: session.routeTracker?.currentEdgeIndex, graph: graph)

                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        let isCurrentStep = idx == currentStepIdx

                        HStack(spacing: 8) {
                            // Step number
                            Text("\(idx + 1)")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(isCurrentStep ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.4))
                                .frame(width: 14)

                            // Edge type icon
                            Image(systemName: step.icon)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(step.iconColor)

                            Text(step.name.uppercased())
                                .font(.system(size: 9, weight: isCurrentStep ? .bold : .medium, design: .monospaced))
                                .foregroundColor(isCurrentStep ? HUDTheme.primaryText : HUDTheme.secondaryText)
                                .tracking(0.5)
                                .lineLimit(1)

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

                        if idx < steps.count - 1 {
                            Rectangle()
                                .fill(HUDTheme.cardBorder.opacity(0.3))
                                .frame(height: 0.5)
                                .padding(.leading, 36)
                                .padding(.trailing, 14)
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
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                    }
                    .foregroundColor(HUDTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(HUDTheme.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    onEndMeetup()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("END")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                    }
                    .foregroundColor(HUDTheme.accentRed)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(HUDTheme.accentRed.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
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
    }

    // MARK: - Route Step Consolidation

    // MARK: - Helpers

    private func formatETA(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins)M \(secs)S" : "\(secs)S"
    }

}
