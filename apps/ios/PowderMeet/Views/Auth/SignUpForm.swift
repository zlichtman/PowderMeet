import SwiftUI

/// SIGN UP: email, password and confirmation, with no name field: the
/// name is chosen in onboarding, where it is
/// checked as it is typed. The address must be confirmed from the email
/// before the account can sign in.
struct SignUpForm: View {
    @Environment(AppModel.self) private var model
    @Binding var email: String

    @State private var password = ""
    @State private var confirmPassword = ""

    private var isValid: Bool {
        looksLikeEmail(email) && password.count >= AppModel.minimumPasswordLength && password == confirmPassword
    }

    private var hint: String? {
        if !password.isEmpty && password.count < AppModel.minimumPasswordLength {
            return "Password must be \(AppModel.minimumPasswordLength)+ characters"
        }
        if !confirmPassword.isEmpty && password != confirmPassword { return "Passwords don't match" }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            AuthTextField(
                label: "Email", text: $email, placeholder: "you@example.com",
                contentType: .username, keyboard: .emailAddress
            )

            AuthSecureField(
                label: "Password", text: $password,
                placeholder: "\(AppModel.minimumPasswordLength)+ characters", contentType: .newPassword
            )

            AuthSecureField(
                label: "Confirm", text: $confirmPassword, placeholder: "Re-enter password", contentType: nil
            )

            if let hint {
                Text(hint)
                    .textRole(.label)
                    .foregroundColor(HUDTheme.accentAmber)
            }

            PrimaryButton(
                title: "Create account",
                isLoading: model.auth.isSigningIn,
                isEnabled: isValid
            ) {
                model.signUp(email: email, password: password)
            }
            .padding(.top, 4)
        }
    }
}

/// After sign-up: the link is in the inbox. Resend, or go back to sign in.
struct CheckEmailCard: View {
    @Environment(AppModel.self) private var model
    let email: String
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(HUDTheme.accentGreen)

            Text("Check your email")
                .textRole(.bodyEmph)
                .foregroundColor(HUDTheme.primaryText)

            Text("We sent a link to \(email). Open it on this phone to finish signing up.")
                .textRole(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            SecondaryButton(
                title: model.account.resentTo == email ? "Sent again" : "Resend email",
                isLoading: model.account.isResending,
                isEnabled: model.account.resentTo != email
            ) {
                model.resendConfirmation(to: email)
            }

            Button(action: onSignIn) {
                Text("Confirmed it on another device? Sign in")
                    .textRole(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
