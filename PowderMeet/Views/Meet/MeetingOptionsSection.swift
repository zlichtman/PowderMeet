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

    /// Deduplicate alternates that share the same canonical-with-word-order-
    /// agnostic label as either the top match or an earlier alternate.
    /// OSM occasionally splits a single trail into "Olympic Lower Green"
    /// + "Lower Olympic Green" — both end up labeled identically by
    /// MountainNaming once you ignore word order, so showing both as
    /// separate meeting options is just visual noise. Picks the first
    /// (best-scoring) one and drops later duplicates.
    private func dedupedAlternates(for result: MeetingResult) -> [AlternateMeeting] {
        guard let graph else { return result.alternates }
        let naming = MountainNaming(graph)
        let bestKey = Self.dedupKey(for: naming.nodeLabel(result.meetingNode.id, style: .canonical))
        var seen: Set<String> = [bestKey]
        var out: [AlternateMeeting] = []
        out.reserveCapacity(result.alternates.count)
        for alt in result.alternates {
            let key = Self.dedupKey(for: naming.nodeLabel(alt.node.id, style: .canonical))
            if seen.insert(key).inserted {
                out.append(alt)
            }
        }
        return out
    }

    /// Dedup key: lowercased, alphanumerics-only, words sorted. Treats
    /// "Olympic Lower Green" and "Lower Olympic Green" as the same name.
    /// Display still uses the original — only dedup uses this key.
    private static func dedupKey(for label: String) -> String {
        let folded = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let collapsed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let words = String(collapsed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
        return words.joined(separator: " ")
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
                .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(1.5)
            Text(message.uppercased())
                .font(.system(size: 8, weight: .medium, design: .monospaced))
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
                    graph: graph,
                    friendName: friendName,
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
                        graph: graph,
                        friendName: friendName,
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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
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
