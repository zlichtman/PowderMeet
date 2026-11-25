import AppCore
import PowderMeetAPI
import SwiftUI

/// Chooses the screen for the session's state, which comes from `AppSession`.
struct RootView: View {
    @Environment(AppModel.self) private var model

    private static var previewOnboarding: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "previewOnboarding")
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            // One backdrop for sign-in and onboarding together, so it carries
            // on from one to the other; a returning user never pays for it.
            if showsBackdrop {
                PreMapBackdrop()
                    .transition(.opacity)
            }

            switch model.state {
            case .starting:
                SplashView()
            case .signedOut:
                if Self.previewOnboarding {
                    // `-previewOnboarding YES` (Debug only): the onboarding
                    // steps without an account, with `-debugOnboardingStep N`.
                    OnboardingView()
                } else if DebugLaunch.previewData {
                    // Screenshots of the panel without an account (Debug only).
                    MainScaffold()
                } else {
                    AuthView()
                        .transition(.opacity)
                }
            case .failed(let error):
                SplashView(
                    showRetry: true,
                    errorMessage: error.userMessage,
                    onRetry: { model.retryStartup() },
                    onSignOut: { model.signOut() }
                )
                .transition(.opacity)
            case .needsOnboarding:
                OnboardingView()
                    .transition(.opacity)
            case .ready:
                MainScaffold()
                    .transition(.opacity)
            }
        }
        .overlayPreferenceValue(MapTopCoverKey.self, alignment: .top) { covered in
            MessagesOverlay(coveredTop: covered)
        }
        // "Open in PowderMeet" from Files, Mail or another app's share sheet,
        // and the links in the sign-up and password reset emails.
        .onOpenURL { url in
            if url.isFileURL {
                model.openActivityFile(url)
            } else if AuthLink.isAuthCallback(url) {
                model.openAuthLink(url)
            }
        }
        // A batch with a failed file opens its report inside Activity.
        .onChange(of: model.activity.showsReport) { _, shows in
            if shows { model.openProfilePage(.activity, route: .importReport) }
        }
        // A reset link signed the user in: the new password comes first,
        // over whatever screen the session is on.
        .fullScreenCover(isPresented: Binding(
            get: { model.account.needsNewPassword }, set: { model.account.needsNewPassword = $0 }
        )) {
            NewPasswordSheet()
        }
        .preferredColorScheme(.dark)
        .background(WindowOverrideStyle(style: isSignedOut ? .dark : .unspecified))
        .animation(.easeInOut(duration: 0.3), value: screen)
    }

    private var showsBackdrop: Bool {
        switch model.state {
        case .signedOut, .needsOnboarding: true
        case .starting, .failed, .ready: false
        }
    }

    private var isSignedOut: Bool {
        if case .signedOut = model.state { true } else { false }
    }

    /// The screen on show, so a profile edit inside `.ready` does not animate.
    private var screen: Int {
        switch model.state {
        case .starting: 0
        case .signedOut: 1
        case .failed: 2
        case .needsOnboarding: 3
        case .ready: 4
        }
    }
}
