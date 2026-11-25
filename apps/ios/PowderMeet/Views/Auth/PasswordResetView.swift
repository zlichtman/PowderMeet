import SwiftUI

/// Forgot?: sends the reset email. Its link opens the app, which then asks
/// for a new password (`NewPasswordSheet`).
/// One glass card; the title and grabber come from where it is shown: a sheet
/// over sign-in (`AuthSheet`) or a page pushed in Settings → Account.
struct PasswordResetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    /// In the floating panel: back to Account. Nil in sign-in's sheet, which
    /// closes itself.
    private let onClose: (() -> Void)?

    init(initialEmail: String = "", onClose: (() -> Void)? = nil) {
        _email = State(initialValue: initialEmail.trimmingCharacters(in: .whitespacesAndNewlines))
        self.onClose = onClose
    }

    /// Signed in (Settings), the link goes to the account's own address, never
    /// one typed here; over sign-in, to the address typed.
    private var recipient: String {
        onClose == nil ? email : model.account.identity?.email ?? ""
    }

    var body: some View {
        VStack(spacing: 16) {
            if let sentTo = model.account.resetSentTo {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(HUDTheme.accentGreen)
                        .accessibilityHidden(true)
                    Text("Reset link sent to \(sentTo)")
                        .textRole(.bodyEmph)
                        .foregroundColor(HUDTheme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .glassCard()
            } else {
                VStack(spacing: 12) {
                    if onClose == nil {
                        AuthTextField(
                            label: "Email", text: $email, placeholder: "you@example.com",
                            contentType: .username, keyboard: .emailAddress
                        )
                    } else {
                        Text(recipient.isEmpty ? "Loading your account's email" : "The link goes to \(recipient)")
                            .textRole(.body)
                            .foregroundColor(HUDTheme.primaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    if let failure = model.account.resetFailure {
                        AuthMessage(text: failure.userMessage)
                    }
                    PrimaryButton(
                        title: "Send reset link",
                        isLoading: model.account.isSendingReset,
                        isEnabled: looksLikeEmail(recipient)
                    ) {
                        model.sendPasswordReset(to: recipient)
                    }
                }
                .glassCard()
            }
            if onClose == nil { Spacer(minLength: 0) }
        }
        // In the panel the page has its margins already.
        .padding(.horizontal, onClose == nil ? GlassLayout.pageInset : 0)
        .padding(.top, onClose == nil ? 8 : 0)
        .onAppear {
            model.clearPasswordReset()
            model.resetSheetOpened()
        }
        .onDisappear { model.resetSheetClosed() }
        // The link came back while this sheet was still up.
        .onChange(of: model.account.closeResetSheet) { _, close in
            guard close else { return }
            if let onClose { onClose() } else { dismiss() }
        }
    }
}
