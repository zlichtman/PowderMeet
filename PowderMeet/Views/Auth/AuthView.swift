//
//  AuthView.swift
//  PowderMeet
//
//  Container that toggles between sign-in and sign-up.
//  Includes Sign in with Apple on both flows.
//

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @Environment(SupabaseManager.self) private var supabase
    @State private var isSignUp = false
    /// The nonce for the Apple Sign-In request currently in flight.
    /// Overwriting this during an active request used to let a retap's
    /// nonce be consumed by the first request's completion, which made
    /// Supabase reject the token. Gated by `isAppleRequestInFlight`.
    @State private var currentNonce: String?
    @State private var isAppleRequestInFlight = false
    @State private var appleError: String?

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 80)

                    // ── Logo ──
                    VStack(spacing: 6) {
                        Text("POWDERMEET")
                            .font(.system(size: 32, weight: .black, design: .monospaced))
                            .foregroundColor(HUDTheme.accent)
                            .tracking(6)

                        Text("FIND YOUR CREW ON THE MOUNTAIN")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                            .tracking(2.5)
                    }
                    .padding(.bottom, 18)

                    // Same two-tone mountain mark as the resort picker, used
                    // here as a visual divider between the brand block and
                    // the sign-in / sign-up controls.
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(HUDTheme.accent, HUDTheme.accent.opacity(0.3))
                        .padding(.bottom, 22)

                    // ── SIGN IN / SIGN UP Switcher ──
                    HStack(spacing: 0) {
                        tabButton(title: "LOGIN", isActive: !isSignUp) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isSignUp = false
                                appleError = nil
                            }
                        }
                        tabButton(title: "SIGN UP", isActive: isSignUp) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isSignUp = true
                                appleError = nil
                            }
                        }
                    }
                    .background(HUDTheme.inputBackground.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(HUDTheme.cardBorder.opacity(0.3), lineWidth: 0.5)
                    )
                    .padding(.bottom, 16)

                    // ── Form Card ──
                    VStack(spacing: 0) {
                        if isSignUp {
                            SignUpForm()
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else {
                            SignInForm()
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .padding(20)
                    .background(HUDTheme.inputBackground.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(HUDTheme.cardBorder.opacity(0.5), lineWidth: 0.5)
                    )

                    // ── Apple Sign In Error ──
                    if let appleError {
                        Text(appleError.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.accent)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }

                    // ── Sign in with Apple ──
                    SignInWithAppleButton(.continue) { request in
                        // Guard against nonce-race on rapid retaps: if a
                        // request is already in flight, refuse the new one
                        // rather than overwriting `currentNonce` (which
                        // would make the first completion use the wrong
                        // nonce and fail Supabase verification).
                        guard !isAppleRequestInFlight else {
                            request.nonce = sha256(currentNonce ?? "")
                            return
                        }
                        isAppleRequestInFlight = true
                        let nonce = randomNonceString()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = sha256(nonce)
                    } onCompletion: { result in
                        Task {
                            await handleAppleResult(result)
                            isAppleRequestInFlight = false
                            currentNonce = nil
                        }
                    }
                    .disabled(isAppleRequestInFlight)
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 16)

                    Spacer().frame(height: 60)
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            // Credit pinned to the screen bottom. `ignoresSafeArea(.keyboard …)`
            // keeps it glued to the device edge instead of riding up with the
            // keyboard — the keyboard simply covers it while typing, which
            // reads correctly. (We tried inline-under-tagline before that;
            // it scrolled out of view on small screens. Bottom is the right
            // home; the ignoresSafeArea is what makes it stay put.)
            VStack {
                Spacer()
                Text("DEVELOPED BY ZACH LICHTMAN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.accent)
                    .tracking(2)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Tab Button

    private func tabButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? .white : HUDTheme.secondaryText.opacity(0.4))
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(isActive ? HUDTheme.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apple Sign In Handler

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        appleError = nil
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData   = credential.identityToken,
                let idToken     = String(data: tokenData, encoding: .utf8),
                let nonce       = currentNonce
            else {
                appleError = "Apple Sign In failed — please try again."
                return
            }
            do {
                try await supabase.signInWithApple(
                    idToken: idToken,
                    nonce: nonce,
                    fullName: credential.fullName
                )
            } catch {
                appleError = error.localizedDescription
            }

        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
            break

        case .failure(let error):
            appleError = error.localizedDescription
        }
    }
}

#Preview {
    AuthView()
        .preferredColorScheme(.dark)
        .environment(SupabaseManager.shared)
}
