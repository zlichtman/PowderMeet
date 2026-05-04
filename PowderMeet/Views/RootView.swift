//
//  RootView.swift
//  PowderMeet
//
//  Auth gate — routes to splash, auth, onboarding, or main app.
//

import SwiftUI

struct RootView: View {
    @Environment(SupabaseManager.self) private var supabase
    /// True once we've sat on the "authenticated but profile loading" splash
    /// long enough that the user probably needs an escape hatch. Without
    /// this, a transient profile-fetch failure + no-auth-error classification
    /// meant the user was stuck forever on the pulsing splash.
    @State private var splashRetryVisible = false
    @State private var splashTimeoutTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            if supabase.isLoading {
                SplashView()
            } else if !supabase.isAuthenticated {
                AuthView()
                    .transition(.opacity)
            } else if supabase.currentUserProfile == nil {
                // Authenticated but profile not loaded yet. After ~5s of
                // unresolved splash — or if `profileLoadError` is set — the
                // user gets a RETRY / SIGN OUT pair so a flaky network
                // doesn't trap them on the spinner.
                SplashView(
                    showRetry: splashRetryVisible || supabase.profileLoadError != nil,
                    errorMessage: supabase.profileLoadError,
                    onRetry: {
                        Task {
                            splashRetryVisible = false
                            await supabase.loadProfile()
                            scheduleSplashTimeout()
                        }
                    },
                    onSignOut: {
                        Task { try? await supabase.signOut() }
                    }
                )
                .transition(.opacity)
                .onAppear { scheduleSplashTimeout() }
                .onDisappear {
                    splashTimeoutTask?.cancel()
                    splashTimeoutTask = nil
                    splashRetryVisible = false
                }
            } else if needsDisplayName {
                // Apple Sign-In only returns the user's name on the
                // first authorization. Re-sign-ins (e.g. after we
                // delete the account, or the user revokes & re-grants
                // in Settings) come back with no name claim and an
                // empty display_name on the profile. Force a name
                // pick before they can use the rest of the app —
                // friend cards, meet invites, presence dots all
                // surface this string.
                PickDisplayNameView()
                    .transition(.opacity)
            } else if supabase.currentUserProfile?.onboardingCompleted != true {
                OnboardingView()
                    .transition(.opacity)
            } else {
                ContentView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: supabase.isLoading)
        .animation(.easeInOut(duration: 0.3), value: supabase.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: supabase.currentUserProfile?.onboardingCompleted)
        .animation(.easeInOut(duration: 0.2), value: splashRetryVisible)
        .animation(.easeInOut(duration: 0.2), value: supabase.profileLoadError)
        .animation(.easeInOut(duration: 0.3), value: needsDisplayName)
    }

    private var needsDisplayName: Bool {
        guard let profile = supabase.currentUserProfile else { return false }
        return profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleSplashTimeout() {
        splashTimeoutTask?.cancel()
        splashTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if supabase.currentSession != nil && supabase.currentUserProfile == nil {
                splashRetryVisible = true
            }
        }
    }
}
