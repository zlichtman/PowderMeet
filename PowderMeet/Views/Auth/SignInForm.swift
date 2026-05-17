//
//  SignInForm.swift
//  PowderMeet
//

import SwiftUI

struct SignInForm: View {
    @Environment(SupabaseManager.self) private var supabase
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPasswordReset = false
    @State private var isPasswordVisible = false

    var body: some View {
        VStack(spacing: 12) {
            // ── Email ──
            VStack(alignment: .leading, spacing: 4) {
                Text("EMAIL")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                    .tracking(1.5)

                TextField("", text: $email, prompt: Text("YOUR@EMAIL.COM").foregroundColor(HUDTheme.secondaryText.opacity(0.3)))
                    .hudType(.bodyEmph)
                    .foregroundColor(HUDTheme.primaryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(HUDTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
                    )
            }

            // ── Password ──
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("PASSWORD")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                        .tracking(1.5)
                    Spacer()
                    Button { showPasswordReset = true } label: {
                        Text("FORGOT?")
                            .hudType(.caption)
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                            .tracking(0.5)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 0) {
                    // HUDSecureField wraps UITextField directly so the
                    // bullet color is set at the UIKit layer — survives
                    // Apple Password AutoFill, paste, and view-identity
                    // changes that SwiftUI's SecureField mishandles
                    // (most visibly: AutoFill produced black bullets
                    // with only the last glyph in accent red).
                    HUDSecureField(
                        text: $password,
                        placeholder: "••••••••",
                        textColor: HUDTheme.accent,
                        placeholderColor: HUDTheme.accent.opacity(0.4),
                        tintColor: HUDTheme.accent,
                        isSecure: !isPasswordVisible,
                        contentType: .password
                    )
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.7))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                }
                .frame(height: 40)
                .background(HUDTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
                )
            }

            // ── Error ──
            if let errorMessage {
                Text(errorMessage.uppercased())
                    .hudType(.label)
                    .foregroundColor(HUDTheme.accent)
                    .multilineTextAlignment(.center)
            }

            // ── Sign In Button ──
            PrimaryButton(
                title: "SIGN IN",
                isLoading: isLoading,
                isEnabled: !email.isEmpty && !password.isEmpty
            ) {
                Task { await signIn() }
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showPasswordReset) {
            PasswordResetView()
        }
    }

    private func signIn() async {
        isLoading = true
        errorMessage = nil
        do {
            try await supabase.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
