import SwiftUI
import UIKit

/// Meet-request pushes are why the app is worth carrying, so the one button
/// (`OnboardingView`) asks for them first and becomes Continue once iOS has
/// an answer.
struct OnboardingNotificationsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var status: NotificationPermission { model.notificationPermission }

    var body: some View {
        VStack(spacing: 24) {
            Text("Stay in the loop")
                .textRole(.title)
                .foregroundColor(HUDTheme.primaryText)
                .padding(.top, 32)

            VStack(spacing: 14) {
                explainerRow(
                    icon: "bell.fill",
                    title: "Meet requests",
                    body: "Friends can ping you to meet up — even when your phone's in your pocket."
                )
                explainerRow(
                    icon: "person.2.fill",
                    title: "Friend requests",
                    body: "Get notified the second someone wants to ski with you."
                )
                explainerRow(
                    icon: "mappin.and.ellipse",
                    title: "Friend arrived",
                    body: "Know when your friend gets to the meeting point."
                )
            }
            .padding(.horizontal, 32)

            Spacer()

            if status == .allowed {
                Label("Notifications on", systemImage: "checkmark.circle.fill")
                    .textRole(.section)
                    .foregroundStyle(HUDTheme.accentGreen)
                    .padding(.bottom, 12)
            }

            if status == .denied {
                // Denied is not a dead end: they can go on, but see what they skip.
                SecondaryButton(title: "Open Settings", fillsWidth: false) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .accessibilityHint("Notifications are off. You can turn them on in Settings.")
                .padding(.bottom, 8)
            }
        }
        .onboardingStepScroll()
    }

    private func explainerRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundColor(HUDTheme.accent)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .textRole(.label)
                    .foregroundColor(HUDTheme.primaryText)
                Text(body)
                    .textRole(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
    }
}
