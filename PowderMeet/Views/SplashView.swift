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
        VStack(spacing: 16) {
            Text("POWDERMEET")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundColor(HUDTheme.accent)
                .tracking(4)
                .opacity(pulse ? 1.0 : 0.6)

            ProgressView()
                .tint(HUDTheme.accent)
                .scaleEffect(0.8)

            if showRetry {
                VStack(spacing: 10) {
                    if let message = errorMessage, !message.isEmpty {
                        Text(message.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.accentAmber)
                            .tracking(0.5)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 32)
                    } else {
                        Text("THIS IS TAKING LONGER THAN USUAL")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(0.8)
                    }

                    HStack(spacing: 10) {
                        Button { onRetry?() } label: {
                            Text("RETRY")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(HUDTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button { onSignOut?() } label: {
                            Text("SIGN OUT")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundColor(HUDTheme.secondaryText)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(HUDTheme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

#Preview {
    ZStack {
        HUDTheme.mapBackground.ignoresSafeArea()
        SplashView(showRetry: true, errorMessage: "NETWORK TIMEOUT")
    }
    .preferredColorScheme(.dark)
}
