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
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                    .tracking(1.5)

                TextField("", text: $email, prompt: Text("YOUR@EMAIL.COM").foregroundColor(HUDTheme.secondaryText.opacity(0.3)))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
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
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                        .tracking(1.5)
                    Spacer()
                    Button { showPasswordReset = true } label: {
                        Text("FORGOT?")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accent)
                    .multilineTextAlignment(.center)
            }

            // ── Sign In Button ──
            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(HUDTheme.spinnerForm).scaleEffect(0.6)
                    }
                    Text("SIGN IN")
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
            .disabled(isLoading || email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.4 : 1.0)
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
