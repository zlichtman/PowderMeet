//
//  RouteCard.swift
//  PowderMeet
//
//  HUD-themed card showing route summary when a meeting point is active.
//  Two columns (YOU / FRIEND) with time, distance, vertical, difficulty dots.
//  Meeting point row: elevation, ETA difference.
//

import SwiftUI

struct RouteCard: View {
    let result: MeetingResult
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                Text("ROUTE SUMMARY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1.5)
                Spacer()
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(HUDTheme.secondaryText)
                        .padding(6)
                        .background(HUDTheme.cardBorder.opacity(0.3))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss route")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Fallback-route preview pill ──
            // Stamped by the solver when the strict pass failed and a
            // relaxed-constraint attempt picked up the route. The
            // user needs to know they're looking at a preview that
            // may include closed terrain or a substituted start
            // node, not a fully-trusted route.
            if result.solveAttempt != .live {
                fallbackPreviewPill(for: result.solveAttempt)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            // ── Two-column route info ──
            HStack(spacing: 0) {
                routeColumn(
                    label: "YOU",
                    color: HUDTheme.routeSkierA,
                    path: result.pathA,
                    time: result.timeA
                )

                // Center divider
                Rectangle()
                    .fill(HUDTheme.cardBorder)
                    .frame(width: 0.5)
                    .padding(.vertical, 4)

                routeColumn(
                    label: "FRIEND",
                    color: HUDTheme.routeSkierB,
                    path: result.pathB,
                    time: result.timeB
                )
            }
            .padding(.horizontal, 12)

            // ── Meeting point row ──
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.42, green: 0.88, blue: 0.72))

                VStack(alignment: .leading, spacing: 2) {
                    Text("MEETING POINT")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                    Text(UnitFormatter.elevationLabel(result.meetingNode.elevation))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.5)
                }

                Spacer()

                // ETA difference
                let diff = abs(result.timeA - result.timeB)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("WAIT TIME")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                    Text(UnitFormatter.formatTime(diff))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(diff < 60 ? HUDTheme.accentGreen : HUDTheme.accentAmber)
                        .tracking(0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HUDTheme.accent.opacity(0.05))
        }
        .background(HUDTheme.cardBackground.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.8)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Fallback preview pill

    /// Amber pill explaining a relaxed-constraint solve. Mirrors the
    /// pill styling used by the source-tag pill in the runs log so
    /// the visual language is consistent across surfaces.
    @ViewBuilder
    private func fallbackPreviewPill(for attempt: SolveAttempt) -> some View {
        let copy: String = {
            switch attempt {
            case .live:                  return ""
            case .forcedOpen:            return "PREVIEW · MAY INCLUDE CLOSED TRAILS"
            case .neighborSubstitution:  return "PREVIEW · NEAREST CONNECTED NODE"
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(HUDTheme.accentAmber)
            Text(copy)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundColor(HUDTheme.accentAmber)
                .tracking(0.6)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HUDTheme.accentAmber.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(HUDTheme.accentAmber.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Route Column

    private func routeColumn(label: String, color: Color, path: [GraphEdge], time: Double) -> some View {
        let distance = path.reduce(0.0) { $0 + $1.attributes.lengthMeters }
        let vertical = path.reduce(0.0) { $0 + $1.attributes.verticalDrop }
        let difficulties = Set(path.compactMap { $0.attributes.difficulty })

        return VStack(spacing: 8) {
            // Label
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .tracking(1)
            }

            // Time
            statRow(icon: "clock", value: UnitFormatter.formatTime(time), accent: color)

            // Distance
            statRow(icon: "arrow.left.and.right", value: formatDistance(distance), accent: color)

            // Vertical
            statRow(icon: "arrow.down", value: UnitFormatter.verticalDrop(abs(vertical)), accent: color)

            // Legs
            statRow(icon: "point.topleft.down.to.point.bottomright.curvepath", value: "\(path.count) LEGS", accent: color)

            // Difficulty dots
            HStack(spacing: 3) {
                ForEach(RunDifficulty.allCases, id: \.rawValue) { diff in
                    if difficulties.contains(diff) {
                        Circle()
                            .fill(Color(UIColor(hex: HUDTheme.mapboxHex(for: diff))))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func statRow(icon: String, value: String, accent: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(accent.opacity(0.6))
                .frame(width: 12)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.3)
        }
    }

    // MARK: - Formatting

    private func formatDistance(_ meters: Double) -> String {
        UnitFormatter.distance(meters)
    }
}
