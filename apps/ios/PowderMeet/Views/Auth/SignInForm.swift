import SwiftUI

/// LOGIN: email and password, FORGOT? for a reset link. The
/// request and its failure live in `AppModel`.
struct SignInForm: View {
    @Environment(AppModel.self) private var model
    @Binding var email: String

    @State private var password = ""
    @State private var showPasswordReset = false

    var body: some View {
        VStack(spacing: 12) {
            AuthTextField(
                label: "Email", text: $email, placeholder: "you@example.com",
                contentType: .username, keyboard: .emailAddress
            )

            AuthSecureField(
                label: "Password", text: $password, placeholder: "Enter password", contentType: .password
            ) {
                Button { showPasswordReset = true } label: {
                    Text("Forgot?")
                        .textRole(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            PrimaryButton(
                title: "Sign in",
                isLoading: model.auth.isSigningIn,
                isEnabled: looksLikeEmail(email) && !password.isEmpty
            ) {
                model.signIn(email: email, password: password)
            }
            .padding(.top, 4)

            // Signing in before the address is confirmed says so, and offers
            // the email again.
            if let unconfirmed = model.account.unconfirmedEmail {
                Button { model.resendConfirmation(to: unconfirmed) } label: {
                    Text(model.account.resentTo == unconfirmed ? "Sent · Check your email" : "Send the confirmation email again")
                        .textRole(.label)
                        .foregroundColor(HUDTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.account.isResending || model.account.resentTo == unconfirmed)
            }
        }
        .sheet(isPresented: $showPasswordReset) {
            NavigationStack {
                PasswordResetView(initialEmail: email)
                    .pushedPage("Reset password")
            }
            .modifier(AuthSheet())
        }
    }
}
