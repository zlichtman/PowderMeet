//
//  MeetingOptionsSection.swift
//  PowderMeet
//
//  Paging cards for solver results — best meeting point + alternates,
//  with the "SHOW ROUTE ON MAP" handoff to the parent. Renders a
//  loading state while the solver is in flight, an error card when
//  the solve returned no path, and the paging `TabView` once the
//  result is available.
//
//  Extracted from `MeetView` to keep section bodies cheap. Owns the
//  visible card-page index internally (a swipe shouldn't propagate
//  through `MeetView` and re-render the friends list);
//  `selectedOptionIndex` stays as a `@Binding` because the parent's
//  send-request and show-route paths both consult it.
//

import SwiftUI

nonisolated enum MeetingOptionPagePolicy {
    static func clamped(_ page: Int, cardCount: Int) -> Int {
        guard cardCount > 0, page >= 0, page < cardCount else { return 0 }
        return page
    }
}

nonisolated enum MeetOptionsVisibilityPolicy {
    static func shouldShow(
        hasResult: Bool,
        isSolving: Bool,
        hasError: Bool
    ) -> Bool {
        hasResult || isSolving || hasError
    }
}

struct MeetingOptionsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Paging is presentation-only state. Keeping it inside this focused child
    /// prevents every drag frame from invalidating the much larger MeetView.
    @State private var currentCardPage = 0
    @State private var measuredCardHeights: [Int: CGFloat] = [:]
    let result: MeetingResult?
    let isSolving: Bool
    let errorMessage: String?
    let solveRecovery: MeetSolveRecovery?
    let graph: MountainGraph?
    let friendName: String?
    let myEquipmentName: String?
    let friendEquipmentName: String?
    let selectedOptionIndex: Int?
    let onSelectOption: (Int) -> Void
    let onPageChanged: (Int) -> Void
    let onShowRoute: () -> Void
    let onReviewTerrainLimits: (() -> Void)?

    private var totalCardCount: Int {
        guard let result else { return 0 }
        return 1 + dedupedAlternates(for: result).count
    }

    private var meetingCardHeight: CGFloat {
        MeetingCardSizing.height(measurements: measuredCardHeights, cardCount: totalCardCount)
    }

    /// Deduplicate alternates by `node.id` only. The previous version
    /// folded names ("Olympic Lower Green" + "Lower Olympic Green" →
    /// same key) and dropped one — but those are physically distinct
    /// graph nodes at different coordinates, and now that the map
    /// live-tracks the paged option (`MeetView.previewSelectedRouteOn
    /// Map`), the user can see the geographic separation directly.
    /// Collapsing them by name was hiding genuine variety. Keep only
    /// the cheap id-based dedup against the primary so the solver
    /// can't return the same `node.id` as both primary and alternate.
    private func dedupedAlternates(for result: MeetingResult) -> [AlternateMeeting] {
        let primaryId = result.meetingNode.id
        var seenIds: Set<String> = [primaryId]
        var out: [AlternateMeeting] = []
        out.reserveCapacity(result.alternates.count)
        for alt in result.alternates {
            if seenIds.insert(alt.node.id).inserted {
                out.append(alt)
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 12) {
            if result != nil,
               myEquipmentName != nil || friendEquipmentName != nil {
                equipmentContext
            }
            optionsContainer
            // SHOW ROUTE ON MAP — visible only once the user has
            // selected an option AND we're not still solving.
            if selectedOptionIndex != nil && !isSolving {
                showRouteButton
            }
        }
        .onAppear {
            if result != nil { onPageChanged(currentCardPage) }
        }
        .onChange(of: currentCardPage) { _, newPage in
            if result != nil { onPageChanged(newPage) }
        }
        .onChange(of: result) { _, _ in
            measuredCardHeights = measuredCardHeights.filter { $0.key < totalCardCount }
            guard result != nil else { return }
            let validPage = MeetingOptionPagePolicy.clamped(
                currentCardPage,
                cardCount: totalCardCount
            )
            if validPage != currentCardPage {
                currentCardPage = validPage
            } else {
                // Same number of choices can still represent a fresh solve;
                // keep the user's visible page but repaint its new geometry.
                onPageChanged(currentCardPage)
            }
        }
        .onChange(of: dynamicTypeSize) { _, _ in measuredCardHeights = [:] }
    }

    private var equipmentContext: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "skis.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("ETA PACE MODEL")
                    .hudType(.caption)
                    .tracking(1.1)
            }
            .foregroundColor(HUDTheme.accentCyan)

            if let myEquipmentName {
                equipmentRow(label: "YOU", equipmentName: myEquipmentName)
            }
            if let friendEquipmentName {
                equipmentRow(
                    label: friendName?.uppercased() ?? "FRIEND",
                    equipmentName: friendEquipmentName
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(HUDTheme.accentCyan.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.accentCyan.opacity(0.20), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func equipmentRow(label: String, equipmentName: String) -> some View {
        HStack(spacing: 5) {
            Text("\(label) ·")
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(0.6)
            Text(equipmentName.uppercased())
                .hudType(.label)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    @ViewBuilder
    private var optionsContainer: some View {
        if isSolving {
            solvingPlaceholder
        } else if let errorMsg = errorMessage {
            errorCard(message: errorMsg)
        } else if let result {
            resultCards(result: result)
        }
    }

    private var solvingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(HUDTheme.spinnerInteractive)
                .scaleEffect(0.8)
            Text("CALCULATING ROUTES")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundColor(HUDTheme.accentAmber)
            Text("NO ROUTE FOUND")
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(1.5)
            Text(message.uppercased())
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            if solveRecovery == .reviewTerrainLimits,
               let onReviewTerrainLimits {
                Button(action: onReviewTerrainLimits) {
                    HStack(spacing: 7) {
                        Image(systemName: "slider.horizontal.3")
                        Text("REVIEW TERRAIN LIMITS")
                            .hudType(.label)
                            .tracking(1)
                    }
                    .foregroundColor(HUDTheme.accentAmber)
                    .frame(maxWidth: .infinity)
                    .minimumInteractiveTarget()
                    .background(HUDTheme.accentAmber.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(HUDTheme.accentAmber.opacity(0.32), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .accessibilityHint("Opens your profile terrain comfort settings")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .frame(minHeight: 140)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HUDTheme.accentAmber.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func resultCards(result: MeetingResult) -> some View {
        let primaryMetrics = MeetingOptionTradeoff.Metrics(
            pathA: result.pathA,
            pathB: result.pathB,
            timeA: result.timeA,
            timeB: result.timeB,
            stdA: result.etaStdSecondsA,
            stdB: result.etaStdSecondsB
        )
        let alternates = dedupedAlternates(for: result)
        let alternateMetrics = alternates.map {
            MeetingOptionTradeoff.Metrics(
                pathA: $0.pathA,
                pathB: $0.pathB,
                timeA: $0.timeA,
                timeB: $0.timeB,
                stdA: $0.etaStdSecondsA,
                stdB: $0.etaStdSecondsB
            )
        }
        return VStack(spacing: 8) {
            // Horizontally-paged cards (swipe left/right — no conflict
            // with the parent ScrollView).
            TabView(selection: $currentCardPage) {
                // The primary label names the strongest visible advantage
                // from the reliability objective: group arrival, wait
                // fairness, and ETA uncertainty, followed by verified
                // stopping-point confidence and quality.
                MeetingOptionCardView(
                    index: 0,
                    label: MeetingOptionTradeoff.primaryLabel(
                        primary: primaryMetrics,
                        alternates: alternateMetrics
                    ),
                    node: result.meetingNode,
                    pathA: result.pathA,
                    pathB: result.pathB,
                    timeA: result.timeA,
                    timeB: result.timeB,
                    legTimesA: result.legTimesA,
                    legTimesB: result.legTimesB,
                    routeReasonA: result.routeReasonA,
                    routeReasonB: result.routeReasonB,
                    etaStdSecondsA: result.etaStdSecondsA,
                    etaStdSecondsB: result.etaStdSecondsB,
                    meetingDisplayName: result.meetingDisplayName,
                    rendezvousPoint: result.rendezvousPoint,
                    rendezvousReason: result.rendezvousReason,
                    sharedContinuation: result.sharedContinuation,
                    graph: graph,
                    friendName: friendName,
                    solveAttempt: result.solveAttempt,
                    isSelected: selectedOptionIndex == 0,
                    onSelect: { onSelectOption(0) }
                )
                .measuredMeetingPage(index: 0)
                .tag(0)

                ForEach(Array(alternates.enumerated()), id: \.offset) { idx, alt in
                    let alternateMetrics = MeetingOptionTradeoff.Metrics(
                        pathA: alt.pathA,
                        pathB: alt.pathB,
                        timeA: alt.timeA,
                        timeB: alt.timeB,
                        stdA: alt.etaStdSecondsA,
                        stdB: alt.etaStdSecondsB
                    )
                    MeetingOptionCardView(
                        index: idx + 1,
                        label: MeetingOptionTradeoff.label(
                            primary: primaryMetrics,
                            alternate: alternateMetrics,
                            ordinal: idx + 2
                        ),
                        node: alt.node,
                        pathA: alt.pathA,
                        pathB: alt.pathB,
                        timeA: alt.timeA,
                        timeB: alt.timeB,
                        // Per-leg times populated by MeetView's
                        // post-solve annotator (same path the primary
                        // result uses); nil only for the brief window
                        // before annotation finishes.
                        legTimesA: alt.legTimesA,
                        legTimesB: alt.legTimesB,
                        routeReasonA: alt.routeReasonA,
                        routeReasonB: alt.routeReasonB,
                        etaStdSecondsA: alt.etaStdSecondsA,
                        etaStdSecondsB: alt.etaStdSecondsB,
                        meetingDisplayName: alt.meetingDisplayName,
                        rendezvousPoint: alt.rendezvousPoint,
                        rendezvousReason: nil,
                        sharedContinuation: alt.sharedContinuation,
                        graph: graph,
                        friendName: friendName,
                        // Alternates inherit the primary result's
                        // attempt stamp — the solver runs the same
                        // pass for every candidate node, so any
                        // bypass that produced the primary result
                        // also produced these.
                        solveAttempt: result.solveAttempt,
                        isSelected: selectedOptionIndex == idx + 1,
                        onSelect: { onSelectOption(idx + 1) }
                    )
                    .measuredMeetingPage(index: idx + 1)
                    .tag(idx + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: meetingCardHeight)
            .onPreferenceChange(MeetingCardHeightPreference.self) { heights in
                // Keep the tallest measured page while swiping so the outer
                // vertical scroll position does not jump between options.
                for (index, height) in heights where height.isFinite && height > 0 {
                    if measuredCardHeights[index] != height { measuredCardHeights[index] = height }
                }
            }

            // Page indicator dots
            if totalCardCount > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<totalCardCount, id: \.self) { idx in
                        Circle()
                            .fill(idx == currentCardPage ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.3))
                            .frame(width: idx == currentCardPage ? 7 : 5,
                                   height: idx == currentCardPage ? 7 : 5)
                            .animation(.easeInOut(duration: 0.2), value: currentCardPage)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var showRouteButton: some View {
        Button(action: onShowRoute) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("SHOW ROUTE ON MAP")
                    .hudType(.section)
                    .tracking(1.5)
            }
            .foregroundColor(HUDTheme.accentCyan)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(HUDTheme.accentCyan.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HUDTheme.accentCyan.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
