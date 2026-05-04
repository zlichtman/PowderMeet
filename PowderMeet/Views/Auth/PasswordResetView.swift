//
//  PasswordResetView.swift
//  PowderMeet
//

import SwiftUI

struct PasswordResetView: View {
    @Environment(SupabaseManager.self) private var supabase
    @State private var email = ""
    @State private var isLoading = false
    @State private var sent = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                // ── Header ──
                HStack {
                    Text("RESET PASSWORD")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(2)
                    Spacer()
                    HUDDoneButton()
                }
                .padding(.top, 24)

                if sent {
                    // ── Success ──
                    VStack(spacing: 12) {
                        Image(systemName: "envelope.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(HUDTheme.accentGreen)

                        Text("RESET LINK SENT")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(1.5)

                        Text("CHECK YOUR EMAIL FOR A PASSWORD RESET LINK")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .tracking(0.5)
                    }
                    .padding(.top, 40)
                } else {
                    // ── Email field ──
                    VStack(alignment: .leading, spacing: 6) {
                        Text("EMAIL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(1.5)

                        TextField("", text: $email, prompt: Text("YOUR@EMAIL.COM").foregroundColor(HUDTheme.secondaryText.opacity(0.4)))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.primaryText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(HUDTheme.inputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(HUDTheme.cardBorder, lineWidth: 1)
                            )
                    }

                    if let errorMessage {
                        Text(errorMessage.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.accent)
                    }

                    Button {
                        Task { await sendReset() }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView().tint(HUDTheme.spinnerForm).scaleEffect(0.7)
                            }
                            Text("SEND RESET LINK")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .tracking(2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(HUDTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || email.isEmpty)
                    .opacity(email.isEmpty ? 0.5 : 1.0)
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .presentationDetents([.medium])
    }

    private func sendReset() async {
        isLoading = true
        errorMessage = nil
        do {
            try await supabase.resetPassword(email: email.trimmingCharacters(in: .whitespaces))
            sent = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
