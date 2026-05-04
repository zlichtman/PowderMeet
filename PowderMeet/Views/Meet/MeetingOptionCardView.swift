//
//  MeetingOptionCardView.swift
//  PowderMeet
//
//  Single meeting point option card with route sections for both skiers.
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI

struct MeetingOptionCardView: View {
    let index: Int
    let label: String
    let node: GraphNode
    let pathA: [GraphEdge]
    let pathB: [GraphEdge]
    let timeA: Double
    let timeB: Double
    let graph: MountainGraph?
    let friendName: String?
    let isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        let meetingName = graph.map { MountainNaming($0).nodeLabel(node.id, style: .canonical) } ?? node.id

        VStack(spacing: 0) {
            // Card header — label + max ETA (always visible, not scrollable)
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: index == 0 ? "star.fill" : "mappin.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(index == 0 ? HUDTheme.accentAmber : HUDTheme.routeMeeting)
                    Text(label)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(index == 0 ? HUDTheme.accentAmber : HUDTheme.routeMeeting)
                        .tracking(1.5)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.accent)
                }
                Text(UnitFormatter.formatTime(max(timeA, timeB)))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.routeMeeting)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Meeting point name + elevation
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meetingName.uppercased())
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.8)
                        .lineLimit(2)
                    Text(UnitFormatter.elevationLabel(node.elevation))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Divider
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            // Scrollable route details — prevents clipping on long routes
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Your route
                    routeSection(
                        label: "YOUR ROUTE",
                        path: pathA,
                        time: timeA,
                        color: HUDTheme.routeSkierA,
                        graph: graph
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    // Friend's route
                    routeSection(
                        label: friendName != nil ? "\(friendName!.uppercased())'S ROUTE" : "FRIEND'S ROUTE",
                        path: pathB,
                        time: timeB,
                        color: HUDTheme.routeSkierB,
                        graph: graph
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(isSelected ? HUDTheme.accent.opacity(0.06) : HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? HUDTheme.accent.opacity(0.5) :
                        (index == 0 ? HUDTheme.accentAmber : HUDTheme.routeMeeting).opacity(0.2),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    // MARK: - Route Section

    private func routeSection(
        label: String,
        path: [GraphEdge],
        time: Double,
        color: Color,
        graph: MountainGraph?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: skier label + ETA
            HStack {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer()
                Text(UnitFormatter.formatTime(time))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
            }

            // Route steps
            if path.isEmpty {
                Text("ALREADY AT MEETING POINT")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(0.5)
            } else {
                let steps = RouteStepConsolidator.consolidate(path, graph: graph)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        HStack(spacing: 6) {
                            VStack(spacing: 0) {
                                if idx > 0 {
                                    Rectangle().fill(color.opacity(0.3)).frame(width: 1, height: 4)
                                }
                                Circle()
                                    .fill(idx == steps.count - 1 ? color : color.opacity(0.5))
                                    .frame(width: 5, height: 5)
                                if idx < steps.count - 1 {
                                    Rectangle().fill(color.opacity(0.3)).frame(width: 1, height: 4)
                                }
                            }

                            Image(systemName: step.icon)
                                .font(.system(size: 7))
                                .foregroundColor(step.iconColor)
                                .frame(width: 12)

                            Text(step.name.uppercased())
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(HUDTheme.primaryText.opacity(0.8))
                                .tracking(0.3)
                                .lineLimit(1)

                            if let diff = step.difficulty {
                                Image(systemName: diff.icon)
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundColor(HUDTheme.color(for: diff))
                            }
                        }
                    }
                }
            }
        }
    }

}
