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

struct MeetingOptionsSection: View {
    let result: MeetingResult?
    let isSolving: Bool
    let errorMessage: String?
    let graph: MountainGraph?
    let friendName: String?
    let selectedOptionIndex: Int?
    @Binding var currentCardPage: Int
    let onSelectOption: (Int) -> Void
    let onShowRoute: () -> Void

    private var totalCardCount: Int {
        guard let result else { return 0 }
        return 1 + dedupedAlternates(for: result).count
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
            optionsContainer
            // SHOW ROUTE ON MAP — visible only once the user has
            // selected an option AND we're not still solving.
            if selectedOptionIndex != nil && !isSolving {
                showRouteButton
            }
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
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HUDTheme.accentAmber.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func resultCards(result: MeetingResult) -> some View {
        VStack(spacing: 8) {
            // Horizontally-paged cards (swipe left/right — no conflict
            // with the parent ScrollView).
            TabView(selection: $currentCardPage) {
                // "TOP MATCH" rather than "BEST MEETING POINT" —
                // the solver returns a composite-score winner (max
                // arrival + wait penalty + hub bonus + elevation
                // band + landmark bonus), not a single-objective
                // optimum. "Top match" is honest about the ranking
                // semantics.
                MeetingOptionCardView(
                    index: 0,
                    label: "TOP MATCH",
                    node: result.meetingNode,
                    pathA: result.pathA,
                    pathB: result.pathB,
                    timeA: result.timeA,
                    timeB: result.timeB,
                    legTimesA: result.legTimesA,
                    legTimesB: result.legTimesB,
                    etaStdSecondsA: result.etaStdSecondsA,
                    etaStdSecondsB: result.etaStdSecondsB,
                    graph: graph,
                    friendName: friendName,
                    solveAttempt: result.solveAttempt,
                    isSelected: selectedOptionIndex == 0,
                    onSelect: { onSelectOption(0) }
                )
                .tag(0)

                ForEach(Array(dedupedAlternates(for: result).enumerated()), id: \.offset) { idx, alt in
                    MeetingOptionCardView(
                        index: idx + 1,
                        label: "OPTION \(idx + 2)",
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
                        etaStdSecondsA: nil,
                        etaStdSecondsB: nil,
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
                    .tag(idx + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 400)

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
            .padding(.vertical, 12)
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
