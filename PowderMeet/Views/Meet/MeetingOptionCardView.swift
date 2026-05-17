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
    /// Per-edge traverse times for `pathA`. When provided, the route
    /// section renders one time per consolidated step so the user
    /// can see "LIFT 6: 8 min · FRONTSIDE: 3 min" instead of just
    /// the aggregate. nil for fallback solves that didn't enrich.
    let legTimesA: [Double]?
    /// Per-edge traverse times for `pathB`.
    let legTimesB: [Double]?
    /// 1σ standard deviation of `timeA` (seconds). When non-nil and
    /// >0, the route header surfaces a P10–P90 range ("8-12 min")
    /// instead of a single number — honest uncertainty signal.
    let etaStdSecondsA: Double?
    /// 1σ standard deviation of `timeB`.
    let etaStdSecondsB: Double?
    let graph: MountainGraph?
    let friendName: String?
    /// Honest stamp from the solver — `.live` is the strict pass that
    /// respected every closure / skill gate. Anything else (`.forcedOpen`,
    /// `.neighborSubstitution`) means the solver bypassed a real
    /// constraint to produce *some* route. Surfaced inline as an amber
    /// pill so the user sees the warning **before** they tap Accept,
    /// not just after on `RouteCard`. Defaulted to `.live` so existing
    /// call sites that don't pass it through render unchanged.
    var solveAttempt: SolveAttempt = .live
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
                        .hudType(.caption)
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
                    .hudType(.metric)
                    .foregroundColor(HUDTheme.routeMeeting)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Meeting point name + elevation
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meetingName.uppercased())
                        .hudType(.bodyEmph)
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.8)
                        .lineLimit(2)
                    Text(UnitFormatter.elevationLabel(node.elevation))
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 8))
                    .foregroundColor(HUDTheme.secondaryText)
                Text(reasonCopy)
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Solver fallback warning — surfaces BEFORE accept so the
            // user knows the route may pass through closed terrain or
            // detour around a missing-graph node. RouteCard renders the
            // same warning post-accept; this gives them parity at the
            // moment of choice.
            if solveAttempt != .live {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(fallbackPillText.uppercased())
                        .hudType(.label)
                        .tracking(1.0)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundColor(HUDTheme.accentAmber)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HUDTheme.accentAmber.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(HUDTheme.accentAmber.opacity(0.40), lineWidth: 0.75)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            // Divider
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            // Scrollable route details — prevents clipping on long routes
            ScrollView(.vertical, showsIndicators: false) {
                // Decide ONCE whether to render P10–P90 ranges, then
                // apply the same decision to both skiers. Otherwise
                // one row shows "5m" and the other "4m–7m" — looks
                // like a rendering bug. Threshold is "either side
                // has ≥30s uncertainty", i.e. as soon as the range
                // is meaningful for anyone, show both ranges so the
                // comparison stays apples-to-apples.
                let showRanges = (etaStdSecondsA ?? 0) >= 30 || (etaStdSecondsB ?? 0) >= 30

                VStack(spacing: 0) {
                    // Your route
                    routeSection(
                        label: "YOUR ROUTE",
                        path: pathA,
                        time: timeA,
                        stdSeconds: etaStdSecondsA,
                        showRange: showRanges,
                        legTimes: legTimesA,
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
                        stdSeconds: etaStdSecondsB,
                        showRange: showRanges,
                        legTimes: legTimesB,
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

    private var reasonCopy: String {
        let imbalance = abs(timeA - timeB)
        if imbalance <= 30 {
            let avg = (timeA + timeB) / 2
            if avg < 60 {
                return "BALANCED · LESS THAN 1m EACH"
            }
            let mins = Int((avg / 60).rounded())
            return "BALANCED · ~\(mins)m WAIT EACH"
        }
        if timeA < timeB {
            if imbalance < 60 {
                let secs = Int(imbalance.rounded())
                return "QUICKER FOR YOU · ~\(secs)s LONGER FOR FRIEND"
            }
            let mins = Int((imbalance / 60).rounded())
            return "QUICKER FOR YOU · YOUR FRIEND TRAVELS \(mins)m LONGER"
        }
        if imbalance < 60 {
            let secs = Int(imbalance.rounded())
            return "QUICKER FOR YOUR FRIEND · ~\(secs)s LONGER FOR YOU"
        }
        let mins = Int((imbalance / 60).rounded())
        return "QUICKER FOR YOUR FRIEND · YOU TRAVEL \(mins)m LONGER"
    }

    // MARK: - Fallback pill copy

    private var fallbackPillText: String {
        switch solveAttempt {
        case .live:
            return ""
        case .forcedOpen:
            return "May use closed terrain"
        case .neighborSubstitution:
            return "Routing to nearest open point"
        }
    }

    // MARK: - Route Section

    private func routeSection(
        label: String,
        path: [GraphEdge],
        time: Double,
        stdSeconds: Double?,
        showRange: Bool,
        legTimes: [Double]?,
        color: Color,
        graph: MountainGraph?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: skier label + ETA. When the card decided to show
            // ranges (`showRange == true` — at least one skier has
            // meaningful path variance), render P10–P90 using ±1.28σ.
            // Both rows render in the same format so the comparison
            // stays apples-to-apples; a confident skier still shows
            // a tight range, an uncertain one a wide one.
            HStack {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .hudType(.caption)
                    .foregroundColor(color)
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer()
                if showRange {
                    // Use this skier's own std (may be 0 if confident),
                    // not the card-level threshold std.
                    let std = stdSeconds ?? 0
                    let low = max(0, time - 1.28 * std)
                    let high = time + 1.28 * std
                    Text("\(UnitFormatter.formatTime(low))–\(UnitFormatter.formatTime(high))")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.primaryText)
                        .lineLimit(1)
                } else {
                    Text(UnitFormatter.formatTime(time))
                        .hudType(.label)
                        .foregroundColor(HUDTheme.primaryText)
                }
            }

            // Route steps
            if path.isEmpty {
                Text("ALREADY AT MEETING POINT")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(0.5)
            } else {
                let steps = RouteStepConsolidator.consolidate(path, graph: graph, edgeTimes: legTimes)
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
                                .hudType(.caption)
                                .foregroundColor(HUDTheme.primaryText.opacity(0.8))
                                .tracking(0.3)
                                .lineLimit(1)

                            if let diff = step.difficulty {
                                Image(systemName: diff.icon)
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundColor(HUDTheme.color(for: diff))
                            }

                            Spacer(minLength: 4)

                            // Per-step time. Hidden when consolidator
                            // had no per-edge times to attribute.
                            if let s = step.seconds {
                                Text(UnitFormatter.formatTime(s))
                                    .hudType(.caption)
                                    .foregroundColor(HUDTheme.secondaryText)
                                    .tracking(0.3)
                            }
                        }
                    }
                }
            }
        }
    }

}
