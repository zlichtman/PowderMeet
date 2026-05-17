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

            // Ambient topographic-line texture under the form. Tints
            // from HUDTheme.accent, clamps itself to the screen box,
            // and radial-fades through the center so the lines frame
            // the form instead of crossing it. Self-applies
            // ignoresSafeArea + allowsHitTesting(false).
            MountainLinesTexture()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 56)

                    // ── Logo ──
                    // Icon-first lockup: the two-tone mountain mark sits
                    // ABOVE the wordmark (modern app-splash convention),
                    // wordmark + tagline stack tight beneath it as one
                    // centered brand block. (Previously the mark hung
                    // BELOW the tagline as a stray "divider", which read
                    // as a second, misplaced logo.)
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
                                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                                .tracking(3)
                        }
                    }
                    .padding(.bottom, 30)

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
                            .hudType(.label)
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

            // Credit + version pinned to the screen bottom.
            // `ignoresSafeArea(.keyboard …)` keeps them glued to the
            // device edge instead of riding up with the keyboard — the
            // keyboard simply covers them while typing, which reads
            // correctly. (We tried inline-under-tagline before that;
            // it scrolled out of view on small screens. Bottom is the
            // right home; the ignoresSafeArea is what makes it stay
            // put.) One quiet two-line footer — credit then version,
            // both muted. The old footer repeated "POWDERMEET" here in
            // brand color, which read as a second, misplaced logo
            // competing with the real lockup up top; dropped.
            VStack(spacing: 4) {
                Spacer()
                Text("DEVELOPED BY ZACH LICHTMAN")
                    .hudType(.caption)
                    // Themed + bright: the active HUD accent at full
                    // strength so the credit reads as a deliberate,
                    // on-brand signature, not muted fine print.
                    .foregroundColor(HUDTheme.accent)
                    .tracking(2)
                Text(Self.appVersion)
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.3))
                    .tracking(1.5)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    /// "vX.Y (build)" — same shape the Account page used to render
    /// before the version line moved here. Reads Info.plist once;
    /// static let lets SwiftUI hold a stable string across renders.
    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }()

    // MARK: - Tab Button

    private func tabButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .hudType(.label)
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
