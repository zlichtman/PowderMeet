//
//  EdgeInfoCard.swift
//  PowderMeet
//
//  Unified info card for trails and lifts, shown when an edge is tapped on the map.
//  Replaces TrailInfoCard and LiftInfoCard — branches internally based on edge kind.
//

import SwiftUI

struct EdgeInfoCard: View {
    let edge: GraphEdge
    /// All edges in the same trail group (for aggregate stats). Empty = single edge.
    var trailGroup: [GraphEdge] = []
    var conditions: ResortConditions? = nil
    let onDismiss: () -> Void

    private var isLift: Bool { edge.kind == .lift }
    private var displayName: String {
        edge.attributes.trailName ?? (isLift ? "Unknown Lift" : "Unknown Trail")
    }

    /// Aggregate length across all group edges (or single edge if no group)
    private var totalLength: Double {
        trailGroup.isEmpty ? edge.attributes.lengthMeters
            : trailGroup.reduce(0) { $0 + $1.attributes.lengthMeters }
    }
    /// Aggregate vertical drop across all group edges
    private var totalVerticalDrop: Double {
        trailGroup.isEmpty ? edge.attributes.verticalDrop
            : trailGroup.reduce(0) { $0 + $1.attributes.verticalDrop }
    }
    /// Average gradient computed from aggregate length/vert
    private var aggregateGradient: Double {
        totalLength > 0 ? atan(totalVerticalDrop / totalLength) * 180 / .pi : 0
    }

    // Trail-specific
    private var difficulty: RunDifficulty? { edge.attributes.difficulty }
    private var difficultyColor: Color {
        guard let d = difficulty else { return HUDTheme.secondaryText }
        return HUDTheme.color(for: d)
    }
    private var score: TrailConditionScore {
        TrailConditionScore.compute(for: edge, conditions: conditions)
    }

    // Lift-specific
    private var liftTypeLabel: String {
        edge.attributes.liftType?.displayName ?? "Lift"
    }
    private var liftIcon: String {
        switch edge.attributes.liftType {
        case .gondola, .cableCar:               return "tram.fill"
        case .funicular:                        return "tram.fill.tunnel"
        case .chairLift:                        return "cablecar.fill"
        case .dragLift, .tBar, .jBar, .platter: return "arrow.up.to.line"
        case .magicCarpet, .ropeTow:            return "figure.walk"
        default:                               return "cablecar.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Row 1: Header ──
            if isLift {
                liftHeader
            } else {
                trailHeader
            }

            // ── Trail name (only for trails — lifts have name in header) ──
            if !isLift {
                Text(displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1)
                    .lineLimit(1)
            }

            separator

            // ── Stats row ──
            if isLift {
                liftStats
            } else {
                trailStats
            }

            // ── Weather strip ──
            // Live current conditions (temperature / wind / snowfall / code
            // description). Sourced from `ConditionsService.currentConditions`,
            // a separate Open-Meteo `current=` call that returns the most
            // recent model output — more accurate for "right now" than
            // interpolating the current hour out of the hourly forecast.
            // This is the canonical weather display; the timeline scrubber
            // no longer duplicates it (see `TimelineView.conditionsReadout`).
            weatherStrip
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HUDTheme.headerBackground)
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Trail Header

    private var trailHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: difficulty?.icon ?? "questionmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(difficultyColor)

            Text((difficulty?.displayName ?? "Unknown").uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(difficultyColor)
                .tracking(1.5)

            Spacer()

            openClosedBadge
            dismissButton
        }
    }

    // MARK: - Lift Header

    private var liftHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(HUDTheme.accentAmber.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: liftIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(HUDTheme.accentAmber)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1)
                    .lineLimit(1)
                Text(liftTypeLabel.uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accentAmber)
                    .tracking(1.5)
            }

            Spacer()

            openClosedBadge
            dismissButton
        }
    }

    // MARK: - Shared Components

    private var openClosedBadge: some View {
        Text(edge.attributes.isOpen ? "OPEN" : "CLOSED")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(edge.attributes.isOpen ? HUDTheme.accentGreen : HUDTheme.accentRed)
            .tracking(1)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(HUDTheme.secondaryText)
                .frame(width: 20, height: 20)
                .background(HUDTheme.inputBackground)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        Rectangle()
            .fill(HUDTheme.cardBorder)
            .frame(height: 0.5)
    }

    // MARK: - Trail Stats

    private var trailStats: some View {
        HStack(spacing: 14) {
            statLabel("LENGTH", value: formatLength(totalLength))
            statLabel("VERT",   value: formatVert(totalVerticalDrop))
            statLabel("GRADE",  value: String(format: "%.0f°", aggregateGradient))

            Spacer()

            batteryIndicator("GRM", level: score.groomingLevel, color: HUDTheme.accentGreen)
            batteryIndicator("MOG", level: score.mogulLevel,    color: HUDTheme.accentAmber)
            batteryIndicator("GLD", level: score.glideScore,    color: HUDTheme.accentCyan)
        }
    }

    // MARK: - Lift Stats

    private var liftStats: some View {
        HStack(spacing: 14) {
            if let ride = edge.attributes.rideTimeSeconds {
                statLabel("RIDE", value: formatRideTime(ride))
            }

            statLabel("LENGTH", value: formatLength(edge.attributes.lengthMeters))
            statLabel("VERT",   value: formatVert(edge.attributes.verticalDrop))

            if let cap = edge.attributes.liftCapacity {
                statLabel("CAP/HR", value: "\(cap)")
            }

            Spacer()
        }
    }

    // MARK: - Weather Strip

    @ViewBuilder
    private var weatherStrip: some View {
        if let c = conditions {
            separator

            HStack(spacing: 10) {
                Label {
                    Text(c.temperatureDisplay)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(temperatureColor(c.temperatureC))
                } icon: {
                    Image(systemName: "thermometer")
                        .font(.system(size: 8))
                        .foregroundColor(temperatureColor(c.temperatureC))
                }

                Label {
                    Text(c.windDisplay)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                } icon: {
                    Image(systemName: "wind")
                        .font(.system(size: 8))
                        .foregroundColor(HUDTheme.secondaryText)
                }

                if let snowStr = c.snowfallDisplay {
                    Label {
                        Text(snowStr)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.accentCyan)
                    } icon: {
                        Image(systemName: "snowflake")
                            .font(.system(size: 8))
                            .foregroundColor(HUDTheme.accentCyan)
                    }
                }

                Spacer()

                Text(c.weatherDescription)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)
            }
        }
    }

    private func temperatureColor(_ t: Double) -> Color {
        if t > 0   { return HUDTheme.accentRed }
        if t > -5  { return HUDTheme.accentAmber }
        return HUDTheme.accentCyan
    }

    // MARK: - Helpers

    private func statLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
        }
    }

    private func batteryIndicator(_ label: String, level: Double, color: Color) -> some View {
        let filled = Int((level * 4).rounded())
        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(filled > 0 ? color : HUDTheme.secondaryText.opacity(0.3))
                .tracking(0.5)

            HStack(spacing: 1.5) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < filled ? color : HUDTheme.inputBackground)
                        .frame(width: 8, height: 5)
                }
            }
        }
    }

    private func formatLength(_ meters: Double) -> String {
        UnitFormatter.distance(meters)
    }

    private func formatVert(_ meters: Double) -> String {
        // DEM/coarse graph can yield ~0m on short flats or stale cached graphs — don’t imply a real measurement.
        if meters < 5 { return "—" }
        return UnitFormatter.verticalDrop(meters)
    }

    private func formatRideTime(_ seconds: Double) -> String {
        let mins = Int(seconds / 60)
        return mins > 0 ? "\(mins)MIN" : "<1MIN"
    }
}
