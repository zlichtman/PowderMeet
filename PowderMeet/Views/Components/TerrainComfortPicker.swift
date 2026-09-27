import SwiftUI

/// Explicit user-owned terrain limits. Imported activity may calibrate pace,
/// but it must not silently override a skier saying “do not route me there.”
nonisolated enum TerrainComfortKind: String, CaseIterable, Identifiable, Sendable {
    case moguls
    case ungroomed
    case glades

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moguls: return "MOGULS"
        case .ungroomed: return "UNGROOMED"
        case .glades: return "GLADES"
        }
    }

    var icon: String {
        switch self {
        case .moguls: return "waveform.path"
        case .ungroomed: return "snowflake"
        case .glades: return "tree.fill"
        }
    }

    /// Persisted columns shared by the current server and older clients.
    var profileColumn: String {
        switch self {
        case .moguls: return "condition_moguls"
        case .ungroomed: return "condition_ungroomed"
        case .glades: return "condition_gladed"
        }
    }
}

nonisolated enum TerrainComfortChoice: Double, CaseIterable, Identifiable, Sendable {
    case avoid = 0
    case okay = 0.6
    case confident = 1

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .avoid: return "AVOID"
        case .okay: return "OK"
        case .confident: return "GOOD"
        }
    }

    static func nearest(to value: Double) -> TerrainComfortChoice {
        allCases.min {
            abs($0.rawValue - value) < abs($1.rawValue - value)
        } ?? .okay
    }
}

struct TerrainComfortPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let values: [TerrainComfortKind: Double]
    let onSelect: (TerrainComfortKind, TerrainComfortChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        headerTitle
                        headerLimitCopy
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        headerTitle
                        Spacer(minLength: 8)
                        headerLimitCopy
                    }
                }
            }

            ForEach(TerrainComfortKind.allCases) { kind in
                terrainRow(kind)
            }
        }
        .padding(10)
        .background(HUDTheme.cardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    private var headerTitle: some View {
        Text("TERRAIN LIMITS")
            .hudType(.caption)
            .foregroundColor(HUDTheme.secondaryText)
            .tracking(1.4)
    }

    private var headerLimitCopy: some View {
        Text("AVOID = NEVER ROUTE")
            .hudType(.caption)
            .foregroundColor(HUDTheme.accentAmber.opacity(0.85))
            .tracking(0.4)
    }

    @ViewBuilder
    private func terrainRow(_ kind: TerrainComfortKind) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                terrainLabel(kind, fixedWidth: false)
                choices(for: kind)
            }
            .frame(minHeight: 88)
        } else {
            HStack(spacing: 8) {
                terrainLabel(kind, fixedWidth: true)
                choices(for: kind)
            }
            .frame(minHeight: 44)
        }
    }

    private func terrainLabel(
        _ kind: TerrainComfortKind,
        fixedWidth: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HUDTheme.routeMeeting)
                .frame(width: 18)
            Text(kind.label)
                .hudType(.caption)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.7)
                .lineLimit(1)
        }
        .frame(width: fixedWidth ? 102 : nil, alignment: .leading)
    }

    private func choices(for kind: TerrainComfortKind) -> some View {
        let selected = TerrainComfortChoice.nearest(to: values[kind] ?? 0.6)
        return HStack(spacing: 3) {
            ForEach(TerrainComfortChoice.allCases) { choice in
                Button {
                    onSelect(kind, choice)
                } label: {
                    Text(choice.label)
                        .hudType(.caption)
                        .foregroundColor(
                            selected == choice ? .white : HUDTheme.secondaryText
                        )
                        .tracking(0.35)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected == choice ? HUDTheme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .minimumInteractiveTarget()
                .accessibilityLabel("\(kind.label), \(choice.label)")
                .accessibilityAddTraits(selected == choice ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}
