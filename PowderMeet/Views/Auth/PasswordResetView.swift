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
                        .hudType(.title)
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
                            .hudType(.bodyEmph)
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(1.5)

                        Text("CHECK YOUR EMAIL FOR A PASSWORD RESET LINK")
                            .hudType(.label)
                            .foregroundColor(HUDTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .tracking(0.5)
                    }
                    .padding(.top, 40)
                } else {
                    // ── Email field ──
                    VStack(alignment: .leading, spacing: 6) {
                        Text("EMAIL")
                            .hudType(.label)
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(1.5)

                        TextField("", text: $email, prompt: Text("YOUR@EMAIL.COM").foregroundColor(HUDTheme.secondaryText.opacity(0.4)))
                            .hudType(.bodyEmph)
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
                            .hudType(.label)
                            .foregroundColor(HUDTheme.accent)
                    }

                    PrimaryButton(
                        title: "SEND RESET LINK",
                        isLoading: isLoading,
                        isEnabled: !email.isEmpty
                    ) {
                        Task { await sendReset() }
                    }
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
