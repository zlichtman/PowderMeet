import SwiftUI

/// Shown over whatever is on screen after a password reset link opened the
/// app: the link has signed the user in, and the new password is set here.
/// It cannot be swiped away: the link is single-use, so leaving would mean
/// asking for another. "Not now" still leaves, so a save that keeps failing
/// (no signal on the mountain) never hides the map; the user is signed in
/// and can reset again from Settings.
struct NewPasswordSheet: View {
    @Environment(AppModel.self) private var model

    @State private var newPassword = ""
    @State private var confirmPassword = ""

    private var longEnough: Bool { newPassword.count >= AppModel.minimumPasswordLength }
    private var matches: Bool { !confirmPassword.isEmpty && newPassword == confirmPassword }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    HStack {
                        Text("Set new password")
                            .textRole(.title)
                            .foregroundColor(HUDTheme.primaryText)
                        Spacer()
                    }
                    .padding(.top, 24)

                    VStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 40))
                            .foregroundColor(HUDTheme.accent)
                        Text("Link verified")
                            .textRole(.section)
                            .foregroundColor(HUDTheme.primaryText)
                        Text("Choose a new password for \(model.account.identity?.email ?? "your account")")
                            .textRole(.label)
                            .foregroundColor(HUDTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, 8)

                    AuthSecureField(
                        label: "New password", text: $newPassword,
                        placeholder: "\(AppModel.minimumPasswordLength)+ characters", contentType: .newPassword
                    )
                    AuthSecureField(
                        label: "Confirm", text: $confirmPassword, placeholder: "Re-enter password", contentType: nil
                    )

                    HStack(spacing: 14) {
                        hint(active: longEnough, label: "\(AppModel.minimumPasswordLength)+ chars")
                        hint(active: matches, label: "Match")
                        Spacer()
                    }
                    .padding(.top, -4)

                    if let failure = model.account.passwordFailure {
                        AuthMessage(text: failure.userMessage)
                    }

                    PrimaryButton(
                        title: "Save password",
                        isLoading: model.account.isSavingPassword,
                        isEnabled: longEnough && matches
                    ) {
                        model.saveNewPassword(newPassword)
                    }
                    SecondaryButton(title: "Not now", isEnabled: !model.account.isSavingPassword) {
                        model.account.needsNewPassword = false
                    }
                    .accessibilityHint("You can set a new password later from Settings")
                }
                .padding(.horizontal, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }

    private func hint(active: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(active ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.5))
            Text(label)
                .textRole(.label)
                .foregroundColor(active ? HUDTheme.primaryText : HUDTheme.secondaryText.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(active ? "met" : "not met")
    }
}
