import SwiftUI
import UIKit

// Settings → Appearance's three pages: the app icon, the theme and the
// units. Each is pushed from its row.

/// A theme at a glance: its background holding its accent and status colours.
struct ThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(theme.swatches.enumerated()), id: \.offset) { index, swatch in
                Circle()
                    .fill(Color(swatch))
                    .frame(width: index == 0 ? 12 : 7, height: index == 0 ? 12 : 7)
            }
        }
        .frame(width: 64, height: 28)
        .background(Color(theme.background), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// Units: device, metric or imperial, one row each.
struct UnitsPage: View {
    private var theme: ThemeManager { ThemeManager.shared }

    var body: some View {
        Group {
            GlassSection {
                ForEach(Array(UnitChoice.allCases.enumerated()), id: \.element) { index, choice in
                    if index > 0 { GlassDivider() }
                    Button { theme.selectUnits(choice) } label: {
                        GlassRow(icon: nil, title: choice.label, detail: detail(choice)) {
                            if theme.units == choice {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(HUDTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(theme.units == choice ? .isSelected : [])
                }
            }
        }
        .pageScroll()
    }

    private func detail(_ choice: UnitChoice) -> String {
        switch choice {
        case .device: "As this phone is set: \(UnitChoice.device.isMetric ? "metric" : "imperial")"
        case .metric: "Kilometres, metres, km/h, °C"
        case .imperial: "Miles, feet, mph, °F"
        }
    }
}
