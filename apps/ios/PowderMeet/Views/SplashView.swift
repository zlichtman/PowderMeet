import SwiftUI

/// While the session starts: the plain dark background of the
/// launch screen, in the map's tone, and nothing else. A returning user goes
/// straight on to the map from the cached profile (`LaunchCache`), so this is
/// on screen for a moment at most; only if the start takes longer does a
/// small, calm spinner appear. With `showRetry` (a failed start) it offers
/// Retry and Sign out on a glass card, so a failure never strands the user.
struct SplashView: View {
    var showRetry: Bool = false
    var errorMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    var onSignOut: (() -> Void)? = nil

    /// The spinner waits, so a quick start shows nothing at all.
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            if showRetry {
                VStack(spacing: 14) {
                    Text(errorMessage?.isEmpty == false ? errorMessage! : "This is taking longer than usual")
                        .textRole(.body)
                        .foregroundStyle(HUDTheme.primaryText)
                        .multilineTextAlignment(.center)
                    HStack(spacing: GlassLayout.gap) {
                        PrimaryButton(title: "Retry") { onRetry?() }
                        SecondaryButton(title: "Sign out") { onSignOut?() }
                    }
                }
                .glassCard()
                .padding(.horizontal, 24)
                .transition(.opacity)
            } else if showsSpinner {
                ProgressView()
                    .controlSize(.regular)
                    .tint(HUDTheme.secondaryText)
                    .transition(.opacity)
                    .accessibilityLabel("Opening PowderMeet")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsSpinner)
        .task {
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            showsSpinner = true
        }
    }
}
