//
//  SignUpForm.swift
//  PowderMeet
//

import SwiftUI

struct SignUpForm: View {
    @Environment(SupabaseManager.self) private var supabase
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isPasswordVisible = false
    @State private var isConfirmVisible = false

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !email.isEmpty && password.count >= 6 && password == confirmPassword
    }

    private var validationHint: String? {
        if !password.isEmpty && password.count < 6 { return "PASSWORD MUST BE 6+ CHARACTERS" }
        if !confirmPassword.isEmpty && password != confirmPassword { return "PASSWORDS DON'T MATCH" }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            // ── Display name ──
            hudField(
                label: "NAME",
                text: $displayName,
                placeholder: "FIRST LAST",
                contentType: .name,
                keyboard: .default,
                capitalization: .words
            )

            // ── Email ──
            hudField(label: "EMAIL", text: $email, placeholder: "YOUR@EMAIL.COM", contentType: .emailAddress, keyboard: .emailAddress)

            // ── Password ──
            // First field is `.newPassword` so iOS / Apple Keychain
            // tags it as the canonical credential.
            hudSecureField(
                label: "PASSWORD",
                text: $password,
                placeholder: "6+ CHARACTERS",
                isVisible: $isPasswordVisible,
                contentType: .newPassword
            )

            // ── Confirm ──
            // Confirm field uses `nil` content type so iOS doesn't see
            // TWO `.newPassword` fields and prompt to save the password
            // twice (the duplicate-keychain-entry bug).
            hudSecureField(
                label: "CONFIRM",
                text: $confirmPassword,
                placeholder: "RE-ENTER PASSWORD",
                isVisible: $isConfirmVisible,
                contentType: nil
            )

            // ── Validation hint ──
            if let hint = validationHint {
                Text(hint)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accentAmber)
                    .tracking(0.5)
            }

            // ── Success ──
            if let successMessage {
                Text(successMessage.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accentGreen)
                    .multilineTextAlignment(.center)
            }

            // ── Error ──
            if let errorMessage {
                Text(errorMessage.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accent)
                    .multilineTextAlignment(.center)
            }

            // ── Create Account Button ──
            Button {
                Task { await signUp() }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(HUDTheme.spinnerForm).scaleEffect(0.6)
                    }
                    Text("CREATE ACCOUNT")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .tracking(2)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(HUDTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoading || !isValid)
            .opacity(isValid ? 1.0 : 0.4)
            .padding(.top, 4)
        }
    }

    // MARK: - Reusable styled fields

    private func hudField(label: String, text: Binding<String>, placeholder: String, contentType: UITextContentType? = nil, keyboard: UIKeyboardType = .default, capitalization: TextInputAutocapitalization = .never) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1.5)

            TextField("", text: text, prompt: Text(placeholder).foregroundColor(HUDTheme.accent.opacity(0.4)))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .textContentType(contentType)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(HUDTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
                )
        }
    }

    private func hudSecureField(
        label: String,
        text: Binding<String>,
        placeholder: String,
        isVisible: Binding<Bool>,
        contentType: UITextContentType?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1.5)

            HStack(spacing: 0) {
                // HUDSecureField (UITextField wrapper) — bullet color
                // set at the UIKit layer survives Apple Password AutoFill,
                // paste, and view-identity changes. SwiftUI's SecureField
                // dropped the color in those flows, leaving black dots
                // with the last glyph red.
                HUDSecureField(
                    text: text,
                    placeholder: placeholder,
                    textColor: HUDTheme.accent,
                    placeholderColor: HUDTheme.accent.opacity(0.4),
                    tintColor: HUDTheme.accent,
                    isSecure: !isVisible.wrappedValue,
                    contentType: contentType
                )
                .padding(.leading, 12)
                .frame(maxWidth: .infinity)

                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isVisible.wrappedValue ? "Hide password" : "Show password")
            }
            .frame(height: 40)
            .background(HUDTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
            )
        }
    }

    private func signUp() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        // Pre-check display-name availability so the user gets a
        // clean inline error instead of a vague Postgres 23505
        // surfaced through Supabase Auth. The unique index on
        // profiles.display_name (case-insensitive) is still the
        // source of truth — this just gives faster + clearer UX.
        let nameTaken = await supabase.isDisplayNameTakenForSignup(trimmedName)
        if nameTaken {
            errorMessage = "\"\(trimmedName)\" is already taken — pick another name."
            isLoading = false
            return
        }

        do {
            try await supabase.signUp(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                displayName: trimmedName
            )
            if supabase.currentSession == nil {
                successMessage = "CHECK YOUR EMAIL TO VERIFY, THEN SIGN IN"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
