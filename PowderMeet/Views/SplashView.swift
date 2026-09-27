//
//  SplashView.swift
//  PowderMeet
//
//  Brief loading screen while restoring session. After ~5s of un-resolved
//  profile load, or immediately on any reported error, surfaces RETRY and
//  SIGN OUT so the user isn't trapped on the pulsing title.
//

import SwiftUI

struct SplashView: View {
    /// When true, show the retry + sign-out affordance. Driven by RootView's
    /// timeout task and by `SupabaseManager.profileLoadError`.
    var showRetry: Bool = false
    var errorMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    var onSignOut: (() -> Void)? = nil

    @State private var pulse = false

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()
            MountainLinesTexture()

            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(HUDTheme.accent, HUDTheme.accent.opacity(0.28))

                    VStack(spacing: 9) {
                        Text("POWDERMEET")
                            .hudType(.title)
                            .foregroundColor(HUDTheme.accent)
                            .tracking(8)

                        Text("FIND YOUR CREW ON THE MOUNTAIN")
                            .hudType(.caption)
                            .foregroundColor(HUDTheme.textTertiary)
                            .tracking(3)
                    }
                }
                .opacity(pulse ? 1.0 : 0.72)

                VStack(spacing: 9) {
                    ProgressView()
                        .tint(HUDTheme.accent)
                        .scaleEffect(0.8)

                    Text("OPENING YOUR MOUNTAIN")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.textTertiary)
                        .tracking(1.5)
                }
                .padding(.top, 28)

                if showRetry {
                    VStack(spacing: 12) {
                        if let message = errorMessage, !message.isEmpty {
                            Text(message.uppercased())
                                .hudType(.label)
                                .foregroundColor(HUDTheme.accentAmber)
                                .tracking(0.5)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 32)
                        } else {
                            Text("THIS IS TAKING LONGER THAN USUAL")
                                .hudType(.label)
                                .foregroundColor(HUDTheme.textSecondary)
                                .tracking(0.8)
                        }

                        HStack(spacing: 10) {
                            recoveryButton(
                                title: "RETRY",
                                foreground: .white,
                                background: HUDTheme.accent,
                                action: { onRetry?() }
                            )
                            recoveryButton(
                                title: "SIGN OUT",
                                foreground: HUDTheme.textSecondary,
                                background: HUDTheme.cardBackground,
                                showsBorder: true,
                                action: { onSignOut?() }
                            )
                        }
                    }
                    .padding(.top, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func recoveryButton(
        title: String,
        foreground: Color,
        background: Color,
        showsBorder: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                if showsBorder {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                }
                Text(title)
                    .hudType(.section)
                    .tracking(1.5)
                    .foregroundColor(foreground)
                    .padding(.horizontal, 18)
            }
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        HUDTheme.mapBackground.ignoresSafeArea()
        SplashView(showRetry: true, errorMessage: "NETWORK TIMEOUT")
    }
    .preferredColorScheme(.dark)
}
