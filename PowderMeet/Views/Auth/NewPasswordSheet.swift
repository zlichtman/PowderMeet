//
//  NewPasswordSheet.swift
//  PowderMeet
//
//  Presented over RootView whenever `SupabaseManager.pendingPasswordRecovery`
//  is true — i.e. the user just opened the app via the `powdermeet://reset`
//  deep link from a password-reset email. Collects a new password (twice,
//  for confirmation), commits via `auth.update(user: UserAttributes(password:))`
//  on the transient recovery session that `handleDeepLink(_:)` set up,
//  then dismisses. After commit the recovery session promotes to a full
//  authenticated session and the user lands in the app.
//

import SwiftUI
import UIKit

struct NewPasswordSheet: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(\.dismiss) private var dismiss

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Password rules mirror Supabase Auth's defaults so the server
    /// won't reject a value the user thinks they just set successfully.
    /// 6 char minimum is Supabase's out-of-box rule; we surface it
    /// upfront rather than waiting for a server roundtrip to fail.
    private var passwordIsValid: Bool {
        newPassword.count >= 6
    }

    private var passwordsMatch: Bool {
        newPassword == confirmPassword && !confirmPassword.isEmpty
    }

    private var canSubmit: Bool {
        passwordIsValid && passwordsMatch && !isSaving
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                header
                    .padding(.top, 24)

                instructions

                passwordField(label: "NEW PASSWORD", text: $newPassword,
                              contentType: .newPassword)
                passwordField(label: "CONFIRM",       text: $confirmPassword,
                              contentType: .newPassword)

                ruleHints

                if let errorMessage {
                    Text(errorMessage.uppercased())
                        .hudType(.label)
                        .foregroundColor(HUDTheme.accent)
                        .multilineTextAlignment(.center)
                        .tracking(1)
                }

                submitButton

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("SET NEW PASSWORD")
                .hudType(.title)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)
            Spacer()
        }
    }

    private var instructions: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundColor(HUDTheme.accent)
            Text("LINK VERIFIED")
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)
            Text("CHOOSE A NEW PASSWORD TO FINISH SIGNING IN")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Fields

    private func passwordField(
        label: String,
        text: Binding<String>,
        contentType: UITextContentType
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1.5)
            HUDSecureField(
                text: text,
                placeholder: "••••••••",
                textColor: HUDTheme.accent,
                placeholderColor: HUDTheme.accent.opacity(0.4),
                tintColor: HUDTheme.accent,
                isSecure: true,
                contentType: contentType
            )
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(HUDTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(HUDTheme.cardBorder, lineWidth: 1)
            )
        }
    }

    private var ruleHints: some View {
        HStack(spacing: 14) {
            hint(active: passwordIsValid, label: "6+ CHARS")
            hint(active: passwordsMatch, label: "MATCH")
            Spacer()
        }
        .padding(.top, -4)
    }

    private func hint(active: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(active ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.5))
            Text(label)
                .hudType(.label)
                .foregroundColor(active ? HUDTheme.primaryText : HUDTheme.secondaryText.opacity(0.6))
                .tracking(1.2)
        }
    }

    private var submitButton: some View {
        PrimaryButton(
            title: "SAVE PASSWORD",
            isLoading: isSaving,
            isEnabled: canSubmit
        ) {
            Task { await save() }
        }
    }

    // MARK: - Commit

    private func save() async {
        guard canSubmit else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await supabase.updatePassword(newPassword)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
