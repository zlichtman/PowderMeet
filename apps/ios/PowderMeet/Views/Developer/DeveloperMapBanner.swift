import SwiftUI

/// Over the map, at the top, the one place developer testing's state is said:
/// what the next tap places while it waits for one, "teleported" while this
/// phone ignores its GPS in live mode, and the pretend weather while the solver
/// reads it, each with the way out. Draws nothing otherwise, and nothing at all
/// in a build without developer testing.
struct DeveloperMapBanner: View {
    @Environment(DeveloperModel.self) private var developer: DeveloperModel?

    var body: some View {
        // Not on the preview stage: it is for screenshots and the demo.
        if let developer, developer.isAvailable, !DebugLaunch.previewData, let lines = lines(developer) {
            HStack(spacing: 10) {
                Image(systemName: developer.placing != nil ? "hand.tap" : developer.isTeleported ? "location.slash" : "cloud.sun")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HUDTheme.accentAmber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lines.title)
                        .textRole(.label)
                        .foregroundColor(HUDTheme.primaryText)
                    if let detail = lines.detail {
                        Text(detail)
                            .textRole(.caption)
                            .foregroundColor(HUDTheme.accentAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    if developer.placing != nil {
                        developer.cancelPlacing()
                    } else if developer.isTeleported {
                        developer.returnToGPS()
                    } else {
                        developer.setPretendWeather(.real)
                    }
                } label: {
                    Text(action(developer))
                        .textRole(.label)
                        .foregroundColor(HUDTheme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        }
    }

    private func lines(_ developer: DeveloperModel) -> (title: String, detail: String?)? {
        let weather = developer.pretendWeather == .real ? nil : "Pretend weather: \(developer.pretendWeather.label)"
        switch developer.placing {
        case .me: return ("Tap the map to teleport", developer.note)
        case .dev(let id): return ("Tap the map to place \(DeveloperModel.name(of: id))", developer.note)
        case nil:
            if developer.isTeleported { return ("Teleported · GPS ignored", weather) }
            return weather.map { ($0, nil) }
        }
    }

    private func action(_ developer: DeveloperModel) -> String {
        if developer.placing != nil { return "Cancel" }
        return developer.isTeleported ? "Back to GPS" : "Real Weather"
    }
}
