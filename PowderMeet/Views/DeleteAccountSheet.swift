//
//  DeleteAccountSheet.swift
//  PowderMeet
//
//  Typed-confirmation sheet for account deletion.
//

import SwiftUI

struct DeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Returns `true` on success. The sheet only dismisses when the caller
    /// confirms the delete landed; on failure we stay open so the error alert
    /// in the parent view is visible instead of flashing behind a dismissal.
    let onConfirm: () async -> Bool

    @State private var typed: String = ""
    @State private var isDeleting = false

    private var canDelete: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer().frame(height: 40)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(HUDTheme.accentRed)

                Text("DELETE ACCOUNT?")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1.5)

                Text("This permanently deletes your account, profile, friends, and history. This cannot be undone.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    Text("TYPE \"DELETE\" TO CONFIRM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                        .tracking(1.2)

                    TextField("", text: $typed,
                              prompt: Text("DELETE").foregroundColor(HUDTheme.secondaryText.opacity(0.3)))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(HUDTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(canDelete ? HUDTheme.accentRed : HUDTheme.cardBorder, lineWidth: 1)
                        )
                        .frame(maxWidth: 240)
                }
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task {
                            isDeleting = true
                            let success = await onConfirm()
                            isDeleting = false
                            if success { dismiss() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView().tint(HUDTheme.spinnerForm).scaleEffect(0.7)
                            }
                            Text(isDeleting ? "DELETING…" : "DELETE FOREVER")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canDelete ? HUDTheme.accentRed : HUDTheme.accentRed.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDelete || isDeleting)

                    Button { dismiss() } label: {
                        Text("CANCEL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.accent)
                            .tracking(1.5)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
    }
}
