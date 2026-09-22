//
//  MeetingOptionCardView.swift
//  PowderMeet
//
//  Single meeting point option card with route sections for both skiers.
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI

/// Compact, factual route profile. It intentionally reports marked terrain,
/// physical lift boardings, and distance instead of inventing a subjective
/// risk score; all hard safety/ability decisions remain solver gates.
nonisolated struct MeetingRouteFacts: Equatable, Sendable {
    let hardestTerrain: RunDifficulty?
    let includesTerrainPark: Bool
    let hasUnratedRuns: Bool
    let liftBoardings: Int
    let distanceMeters: Double
    let traverseMeters: Double

    init(path: [GraphEdge]) {
        func terrainRank(_ difficulty: RunDifficulty) -> Int {
            switch difficulty {
            case .green: return 0
            case .blue: return 1
            case .black, .terrainPark: return 2
            case .doubleBlack: return 3
            }
        }
        let runs = path.filter { $0.kind == .run }
        let difficulties = runs.compactMap(\.attributes.difficulty)
        hasUnratedRuns = difficulties.count != runs.count
        includesTerrainPark = difficulties.contains(.terrainPark)
        hardestTerrain = difficulties.filter { $0 != .terrainPark }.max {
            terrainRank($0) < terrainRank($1)
        }
        liftBoardings = path.filter {
            $0.kind == .lift && $0.attributes.chargesLiftWait != false
        }.count
        distanceMeters = path.reduce(0) { $0 + $1.attributes.lengthMeters }
        traverseMeters = path
            .filter { $0.kind == .traverse }
            .reduce(0) { $0 + $1.attributes.lengthMeters }
    }

    var summary: String? {
        var parts: [String] = []
        if let hardestTerrain {
            let scope = hasUnratedRuns ? "MARKED" : "MAX"
            parts.append("\(hardestTerrain.displayName.uppercased()) \(scope)")
        }
        if hasUnratedRuns {
            parts.append("UNRATED SECTIONS")
        }
        if includesTerrainPark {
            parts.append("PARK FEATURES")
        }
        if liftBoardings > 0 {
            parts.append("\(liftBoardings) \(liftBoardings == 1 ? "LIFT" : "LIFTS")")
        }
        if traverseMeters >= 50 {
            parts.append("\(UnitFormatter.distance(traverseMeters)) CONNECTOR")
        }
        if distanceMeters > 0 {
            parts.append(UnitFormatter.distance(distanceMeters))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct MeetingOptionCardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    /// the aggregate. nil only for decoded legacy results or the brief
    /// pre-annotation window.
    let legTimesA: [Double]?
    /// Per-edge traverse times for `pathB`.
    let legTimesB: [Double]?
    let routeReasonA: String?
    let routeReasonB: String?
    /// 1σ standard deviation of `timeA` (seconds). When non-nil and
    /// >0, the route header surfaces a P10–P90 range ("8-12 min")
    /// instead of a single number — honest uncertainty signal.
    let etaStdSecondsA: Double?
    /// 1σ standard deviation of `timeB`.
    let etaStdSecondsB: Double?
    let meetingDisplayName: String?
    let rendezvousPoint: RendezvousPoint?
    let rendezvousReason: String?
    let sharedContinuation: SharedContinuation?
    let graph: MountainGraph?
    let friendName: String?
    /// Honest stamp from the solver — `.live` is the only current navigable
    /// result. Older unsafe values remain decode-only and render as previews,
    /// so a result written by an earlier build can never masquerade as safe.
    var solveAttempt: SolveAttempt = .live
    let isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        let meetingName = meetingDisplayName
            ?? rendezvousPoint?.displayName
            ?? graph.map { MountainNaming($0).meetingNodeLabel(node.id) }
            ?? node.id

        Button(action: onSelect) {
            VStack(spacing: 0) {
                // Card header — recommendation rank and the time when both
                // skiers should be together. Label the number explicitly;
                // an unlabeled max ETA looked like one skier's route time.
                let headerLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                headerLayout {
                    HStack(spacing: 6) {
                        Image(systemName: index == 0 ? "star.fill" : "mappin.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(index == 0 ? HUDTheme.accentAmber : HUDTheme.routeMeeting)
                        Text(label)
                            .hudType(.caption)
                            .foregroundColor(index == 0 ? HUDTheme.accentAmber : HUDTheme.routeMeeting)
                            .tracking(1.5)
                        if isSelected {
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(HUDTheme.accent)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
                        Text("EST. TOGETHER IN")
                            .hudType(.caption)
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(0.8)
                        Text(arrivalTiming.togetherText)
                            .hudType(.metric)
                            .foregroundColor(HUDTheme.routeMeeting)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                // Destination is the primary decision, so give its landmark
                // icon and name more visual weight than the route metadata.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: rendezvousIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(HUDTheme.routeMeeting)
                        .frame(width: 34, height: 34)
                        .background(HUDTheme.routeMeeting.opacity(0.12))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(meetingName.uppercased())
                            .hudType(.bodyEmph)
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(rendezvousLabel) · \(UnitFormatter.elevationLabel(node.elevation))")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.routeMeeting)
                    Text(reasonCopy)
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.primaryText.opacity(0.78))
                        .tracking(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                if let rendezvousReason, !rendezvousReason.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "wind")
                            .font(.system(size: 8, weight: .semibold))
                        Text(rendezvousReason)
                            .hudType(.caption)
                            .tracking(0.45)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(HUDTheme.accentAmber)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                }

                if let sharedContinuation {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: continuationIcon(sharedContinuation.kind))
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sharedContinuation.cardCopy)
                                .hudType(.caption)
                                .tracking(0.45)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.82)
                            Text(sharedContinuationDetail(sharedContinuation))
                                .hudType(.caption)
                                .foregroundColor(HUDTheme.accentGreen.opacity(0.72))
                                .tracking(0.35)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.82)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(HUDTheme.accentGreen)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                }

                Group {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 8))
                        Text(arrivalTiming.detailText)
                            .hudType(.caption)
                            .tracking(0.5)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(HUDTheme.routeMeeting)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                // Legacy preview warning — surfaces before selection. Current
                // solvers do not produce these attempts, but decode compatibility
                // must remain honest for rows written by older builds.
                if solveAttempt != .live {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(fallbackPillText.uppercased())
                            .hudType(.label)
                            .tracking(1.0)
                            .fixedSize(horizontal: false, vertical: true)
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

                // Keep one vertical scroll owner: MeetView's outer ScrollView.
                // Nested scrolling made a one-handed card feel stuck on the lift.
                // Each route is summarized below and the map owns full detail.
                VStack(spacing: 0) {
                    // Decide ONCE whether to render P10–P90 ranges, then
                    // apply the same decision to both skiers.
                    let showRanges = MeetingRouteTimePresentation.shouldShowRanges(stdA: etaStdSecondsA, stdB: etaStdSecondsB)

                    VStack(spacing: 0) {
                        routeSection(
                            label: "YOUR ROUTE",
                            path: pathA,
                            time: timeA,
                            stdSeconds: etaStdSecondsA,
                            showRange: showRanges,
                            legTimes: legTimesA,
                            routeReason: routeReasonA,
                            color: HUDTheme.routeSkierA,
                            graph: graph
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                        routeSection(
                            label: friendName != nil ? "\(friendName!.uppercased())'S ROUTE" : "FRIEND'S ROUTE",
                            path: pathB,
                            time: timeB,
                            stdSeconds: etaStdSecondsB,
                            showRange: showRanges,
                            legTimes: legTimesB,
                            routeReason: routeReasonB,
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? HUDTheme.accent.opacity(0.6) :
                            (index == 0 ? HUDTheme.accentAmber : HUDTheme.routeMeeting).opacity(0.22),
                        lineWidth: isSelected ? 1.5 : 0.75
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cardAccessibilityLabel(meetingName: meetingName))
        .accessibilityValue(cardAccessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected
            ? "Use Show route on map to review this option."
            : "Selects this meeting option.")
    }

    private var reasonCopy: String {
        arrivalTiming.comparisonText
    }

    private var arrivalTiming: MeetingArrivalPresentation {
        MeetingArrivalPresentation(timeA: timeA, timeB: timeB, stdA: etaStdSecondsA, stdB: etaStdSecondsB)
    }

    private var rendezvousKind: RendezvousPoint.Kind? {
        if let kind = rendezvousPoint?.kind { return kind }
        switch node.kind {
        case .liftBase: return .liftBase
        case .midStation: return .midStation
        default: return nil
        }
    }

    private var rendezvousLabel: String {
        rendezvousKind?.userFacingLabel ?? "DESIGNATED MEETING POINT"
    }

    private var rendezvousIcon: String {
        rendezvousKind?.systemImageName ?? "mappin.circle.fill"
    }

    private func continuationIcon(_ kind: SharedContinuation.Kind) -> String {
        switch kind {
        case .ski: return "figure.skiing.downhill"
        case .ride: return "cablecar.fill"
        case .traverse: return "arrow.right"
        }
    }

    private func sharedContinuationDetail(_ continuation: SharedContinuation) -> String {
        let distance = UnitFormatter.distance(continuation.sharedRunLengthMeters).uppercased()
        let vertical = UnitFormatter.verticalDrop(continuation.sharedVerticalDropMeters).uppercased()
        if continuation.downhillAccessSeconds >= 60 {
            let minutes = max(1, Int((continuation.downhillAccessSeconds / 60).rounded()))
            return "\(minutes)M TO RUN · \(distance) · \(vertical) VERT"
        }
        if continuation.sharedRunOptionCount > 1 {
            return "\(continuation.sharedRunOptionCount) RUN OPTIONS · \(distance) · \(vertical) VERT"
        }
        if SharedLapUtility.isStrongFit(continuation.jointTerrainFit) {
            return "GOOD FIT · \(distance) · \(vertical) VERT"
        }
        return "\(distance) SHARED · \(vertical) VERT"
    }

    func cardAccessibilityLabel(meetingName: String) -> String {
        var parts: [String] = []
        if solveAttempt != .live { parts.append("Preview. \(fallbackPillText).") }
        parts.append("\(label). Meet at \(meetingName).")
        parts.append(arrivalTiming.togetherAccessibilityText)
        return parts.joined(separator: " ")
    }

    var cardAccessibilityValue: String {
        let showRanges = MeetingRouteTimePresentation.shouldShowRanges(stdA: etaStdSecondsA, stdB: etaStdSecondsB)
        func sentence(_ text: String) -> String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return [".", "!", "?"].contains(where: text.hasSuffix) ? text : text + "."
        }
        func route(_ name: String, path: [GraphEdge], time: Double, deviation: Double?, reason: String?) -> String {
            var parts = ["\(name).", MeetingRouteTimePresentation(
                time: time, standardDeviation: deviation, showRange: showRanges
            ).accessibilityText]
            if path.isEmpty { parts.append("Already at the meeting point.") }
            if let facts = MeetingRouteFacts(path: path).summary { parts.append(facts + ".") }
            if let reason, !reason.isEmpty { parts.append(reason) }
            return parts.map(sentence).joined(separator: " ")
        }
        var parts = [
            arrivalTiming.comparisonAccessibilityText,
            arrivalTiming.detailAccessibilityText,
            route("Your route", path: pathA, time: timeA, deviation: etaStdSecondsA, reason: routeReasonA),
            route(friendName.map { "\($0)'s route" } ?? "Friend's route", path: pathB,
                  time: timeB, deviation: etaStdSecondsB, reason: routeReasonB)
        ]
        if let rendezvousReason, !rendezvousReason.isEmpty { parts.append(rendezvousReason) }
        if let sharedContinuation {
            parts.append(sharedContinuation.cardCopy)
            parts.append(sharedContinuationDetail(sharedContinuation))
        }
        return parts.map(sentence).joined(separator: " ")
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
        case .forcedOpenNeighborSubstitution:
            return "May use closed terrain from a nearby point"
        case .nonCanonicalDataset:
            return "Mountain data is not verified"
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
        routeReason: String?,
        color: Color,
        graph: MountainGraph?
    ) -> some View {
        let timing = MeetingRouteTimePresentation(time: time, standardDeviation: stdSeconds, showRange: showRange)
        return VStack(alignment: .leading, spacing: 6) {
            // Header: skier label + ETA. When the card decided to show
            // ranges (`showRange == true` — at least one skier has
            // meaningful path variance), render P10–P90 using ±1.28σ.
            // Both rows render in the same format so the comparison
            // stays apples-to-apples; a confident skier still shows
            // a tight range, an uncertain one a wide one.
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            headerLayout {
                HStack {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label)
                        .hudType(.caption)
                        .foregroundColor(color)
                        .tracking(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(timing.displayText)
                    .hudType(.label)
                    .foregroundColor(HUDTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if timing.rangeUnavailable {
                Text("TIMING RANGE UNAVAILABLE")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let routeReason, !routeReason.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(color)
                        .padding(.top, 2)
                    Text(routeReason.uppercased())
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.25)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if let facts = MeetingRouteFacts(path: path).summary {
                HStack(spacing: 5) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(color.opacity(0.85))
                    Text(facts)
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.45)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityLabel("Route profile, \(facts)")
            }

            // Route steps
            if path.isEmpty {
                Text("ALREADY AT MEETING POINT")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(0.5)
            } else {
                let steps = RouteStepConsolidator.consolidate(path, graph: graph, edgeTimes: legTimes)
                let visibleSteps = Array(steps.prefix(4))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(visibleSteps.enumerated()), id: \.offset) { idx, step in
                        HStack(spacing: 6) {
                            VStack(spacing: 0) {
                                if idx > 0 {
                                    Rectangle().fill(color.opacity(0.3)).frame(width: 1, height: 4)
                                }
                                Circle()
                                    .fill(idx == visibleSteps.count - 1 ? color : color.opacity(0.5))
                                    .frame(width: 5, height: 5)
                                if idx < visibleSteps.count - 1 {
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
                                .fixedSize(horizontal: false, vertical: true)

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
                    if steps.count > visibleSteps.count {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 7, weight: .bold))
                                .frame(width: 17)
                            Text("+\(steps.count - visibleSteps.count) MORE · VIEW ON MAP")
                                .hudType(.caption)
                                .foregroundColor(color.opacity(0.8))
                                .tracking(0.4)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

}
