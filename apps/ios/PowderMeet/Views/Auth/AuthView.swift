import AppCore
import AuthenticationServices
import Foundation
import MapboxAdapter
import MountainCore
import SwiftUI

/// The signed-out screen, in the theme's colours: a top section in the
/// theme's background holding the mark, the word mark and the tagline, whose
/// lower edge follows the card's rounded top as far out as the card's side
/// margin, so the liquid (`PreMapBackdrop`) shows as one even band round the
/// card and below it; one dark glass card with Log in / Sign up and the email
/// form; Continue with Apple.
struct AuthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The raw nonce of the Apple request in flight. A retap must not replace
    /// it, or the first completion would send a nonce the token was not made for.
    @State private var pendingNonce: String?
    @State private var isSignUp = false
    /// Shared by both forms, so switching keeps what was typed.
    @State private var email = ""
    /// The sign-in in flight came from the Apple button (its place shows
    /// "SIGNING IN"); an email sign-in shows its spinner in its own button.
    @State private var usedApple = false
    /// The form card's frame on screen, which the top section's edge follows.
    @State private var cardFrame: CGRect = .zero

    init() {}

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                CardShoulder(card: cardFrame.offsetBy(dx: -origin.x, dy: -origin.y), cornerRadius: GlassLayout.cardRadius)
                    .fill(HUDTheme.mapBackground)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 64)

                    BrandLockup()
                        .padding(.bottom, 44)

                    if let pending = model.account.awaitingConfirmation {
                        formCard {
                            CheckEmailCard(email: pending) {
                                email = pending
                                model.leaveConfirmation()
                                withAnimation(.easeInOut(duration: 0.25)) { isSignUp = false }
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
                        failureMessage
                    } else {
                        formCard {
                            switcher
                                .padding(.bottom, 16)
                            if isSignUp {
                                SignUpForm(email: $email)
                                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .trailing).combined(with: .opacity))
                            } else {
                                SignInForm(email: $email)
                                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
                        failureMessage
                        Group {
                            if model.auth.isSigningIn && usedApple {
                                signingIn
                            } else {
                                appleButton
                            }
                        }
                        .padding(.top, 16)
                    }

                    Spacer().frame(height: 36)
                }
                .padding(.horizontal, GlassLayout.pageInset)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: model.auth.isSigningIn) { _, signingIn in
            if !signingIn { usedApple = false }
        }
    }

    @ViewBuilder private var failureMessage: some View {
        if let message = model.auth.failure?.userMessage {
            AuthMessage(text: message)
                .padding(.top, 12)
        }
    }

    // MARK: Switcher and card

    /// The system's segmented control: native glass, nothing drawn here.
    private var switcher: some View {
        Picker("Account", selection: Binding(get: { isSignUp }, set: { select(signUp: $0) })) {
            Text("Log in").tag(false)
            Text("Sign up").tag(true)
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .disabled(model.auth.isSigningIn)
    }

    private func select(signUp: Bool) {
        guard signUp != isSignUp, !model.auth.isSigningIn else { return }
        model.auth = AuthProgress()
        model.account.unconfirmedEmail = nil
        withAnimation(.easeInOut(duration: 0.25)) { isSignUp = signUp }
    }

    /// The form's glass over the theme's background rather than over the
    /// liquid alone, so it reads as the theme's dark, not grey.
    private func formCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .glassCard()
            .background(
                HUDTheme.mapBackground.opacity(0.55),
                in: RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous))
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
            let raw = pendingNonce ?? AppleNonce.make()
            pendingNonce = raw
            request.nonce = MountainCore.SHA256.hex(Data(raw.utf8))
        } onCompletion: { result in
            let raw = pendingNonce
            pendingNonce = nil
            complete(result, rawNonce: raw)
        }
        .disabled(pendingNonce != nil || model.auth.isSigningIn)
        .signInWithAppleButtonStyle(.white)
        .frame(height: GlassLayout.barHeight)
        .clipShape(Capsule())
    }

    /// Holds the button's place while the session signs in.
    private var signingIn: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(HUDTheme.spinnerForm)
                .scaleEffect(0.7)
            Text("Signing in")
                .textRole(.bodyEmph)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: GlassLayout.barHeight)
        .glassEffect(HUDGlass.surface, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func complete(_ result: Result<ASAuthorization, any Error>, rawNonce: String?) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let rawNonce
            else {
                model.appleSignInFailed()
                return
            }
            usedApple = true
            model.signInWithApple(
                idToken: idToken, nonce: rawNonce, fullName: AppleNonce.name(credential.fullName)
            )
        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
            break
        case .failure:
            model.appleSignInFailed()
        }
    }
}

/// The brand lockup: the PowderMeet mark set into the page in the theme's
/// accent (full in front, softer behind, no tile), the word mark in the
/// primary text colour and the tagline in the secondary one.
private struct BrandLockup: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 64, weight: .semibold))
                // As on the app icon: the front peak white, the one behind in
                // the theme's colour.
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, HUDTheme.accent)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                // The wordmark, tinted like the title it replaces.
                Image("PowderMeetWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .foregroundStyle(HUDTheme.primaryText)
                    .accessibilityLabel("PowderMeet")
                Text("Find your crew on the mountain")
                    .textRole(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(HUDTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The top section: everything above the form card's top edge and its two
/// rounded corners, moved out by the card's own side margin. Its sides are
/// then the screen's edges and its corners are concentric with the card's,
/// so the liquid between it and the card is one even band that carries on
/// down the card's sides, with no step where the curve meets the edge.
private nonisolated struct CardShoulder: Shape {
    /// The card, in this shape's coordinates; zero before the first layout.
    var card: CGRect
    /// The card's corner radius (`GlassLayout.cardRadius`).
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard card.width > 0 else { return Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.45)) }
        // The band is as wide as the margin beside the card.
        let gap = max(0, card.minX - rect.minX)
        let bottom = card.minY - gap
        let radius = min(cornerRadius + gap, rect.width / 2, max(0, bottom - rect.minY))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom), radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

private nonisolated enum AppleNonce {
    /// 32 random bytes as hex. `UInt8.random` draws from the system's
    /// cryptographically secure generator.
    static func make() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Apple sends the name only on the first authorization; nil otherwise.
    static func name(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatted = PersonNameComponentsFormatter
            .localizedString(from: components, style: .default)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : formatted
    }
}
