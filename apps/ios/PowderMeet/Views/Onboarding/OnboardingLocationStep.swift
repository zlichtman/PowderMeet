import SwiftUI
import UIKit

/// Location permission. The card says why; the system prompt comes only from
/// the step's own button ("Allow location", in `OnboardingView`). The permission stream updates the state after the prompt or a
/// round trip to Settings. This asks for "While Using" only: "Always" is asked
/// later, when a meet starts or live recording is turned on, and the second
/// paragraph says so now so that prompt is not a surprise.
struct OnboardingLocationStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var granted: Bool { model.locationPermission == .allowed }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    granted ? HUDTheme.accentGreen : HUDTheme.accent,
                    granted ? HUDTheme.accentGreen.opacity(0.3) : HUDTheme.accent.opacity(0.3)
                )

            Text("Location access")
                .textRole(.title)
                .foregroundColor(HUDTheme.primaryText)

            switch model.locationPermission {
            case .allowed:
                Label("Location enabled", systemImage: "checkmark.circle.fill")
                    .textRole(.section)
                    .foregroundColor(HUDTheme.accentGreen)
                    .padding(.top, 8)
            case .denied:
                // Not a dead end: they can go on, or turn it on from here.
                VStack(spacing: 12) {
                    Text("Location is off. You can turn it on in Settings.")
                        .textRole(.body)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    SecondaryButton(title: "Open Settings", fillsWidth: false) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                .padding(.horizontal, 28)
            case .notDetermined:
                Text("Shows you on the mountain and finds the meeting point that suits you both. Friends see you only while you're at a resort.")
                    .textRole(.body)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()
            Spacer()
        }
        .onboardingStepScroll()
    }
}
