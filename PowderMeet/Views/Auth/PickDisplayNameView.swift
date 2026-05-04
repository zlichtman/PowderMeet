//
//  PickDisplayNameView.swift
//  PowderMeet
//
//  Forced name-set screen. Shown when the signed-in user's profile
//  has an empty `display_name`. The most common path here is Apple
//  Sign-In after the first authorization — Apple only returns the
//  user's name on the very first consent, so a re-sign-in (after
//  account deletion, or if the user revoked + reauthorized in
//  Settings) lands without a name. Email sign-up always carries the
//  name through, so it generally won't hit this view.
//
//  Routed by RootView so it sits ahead of OnboardingView and
//  ContentView — the user can't reach the rest of the app until
//  they pick a name.
//

import SwiftUI
import Supabase
// `AnyJSON.string` lives in the Helpers sub-module. With Swift 6's
// MemberImportVisibility upcoming feature on (set in the project's
// Xcode build settings), the umbrella `import Supabase` no longer
// surfaces enum cases from re-exported sub-modules — needs explicit.
import Helpers

struct PickDisplayNameView: View {
    @Environment(SupabaseManager.self) private var supabase

    @State private var typedName: String = ""
    @State private var conflictMessage: String?
    @State private var isSaving = false
    @FocusState private var nameFieldFocused: Bool

    private var trimmedName: String {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 80)

                    Text("POWDERMEET")
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .foregroundColor(HUDTheme.accent)
                        .tracking(6)

                    Image(systemName: "person.text.rectangle.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(HUDTheme.accent, HUDTheme.accent.opacity(0.3))
                        .padding(.top, 24)
                        .padding(.bottom, 18)

                    VStack(spacing: 8) {
                        Text("PICK A DISPLAY NAME")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(2)
                        Text("THIS IS WHAT FRIENDS SEE WHEN YOU MEET UP")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .tracking(0.8)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("DISPLAY NAME")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                            .tracking(1.5)

                        TextField(
                            "",
                            text: $typedName,
                            prompt: Text("FIRST LAST")
                                .foregroundColor(HUDTheme.accent.opacity(0.4))
                        )
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .textContentType(.name)
                        .focused($nameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(HUDTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
                        )

                        if let msg = conflictMessage {
                            Text(msg)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(HUDTheme.accentRed)
                                .tracking(0.4)
                        }
                    }
                    .padding(.horizontal, 24)

                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView().tint(HUDTheme.spinnerForm).scaleEffect(0.7)
                            }
                            Text(isSaving ? "SAVING…" : "CONTINUE")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .tracking(2)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(isValid ? HUDTheme.accent : HUDTheme.accent.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid || isSaving)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                    Button {
                        Task { try? await supabase.signOut() }
                    } label: {
                        Text("SIGN OUT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(1.5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 28)
                    .padding(.bottom, 60)
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onChange(of: typedName) { _, _ in
            if conflictMessage != nil { conflictMessage = nil }
        }
        .task {
            // Land on the field immediately so the keyboard is already
            // up — fewer taps before the user can start typing.
            try? await Task.sleep(for: .milliseconds(150))
            nameFieldFocused = true
        }
    }

    private func save() async {
        guard isValid, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        // Pre-check uniqueness (case-insensitive) so the user gets
        // an inline error instead of an opaque 23505 from the
        // database's unique index.
        let taken = await supabase.isDisplayNameTakenForSignup(trimmedName)
        if taken {
            conflictMessage = "\"\(trimmedName)\" is already taken — pick another."
            return
        }

        do {
            // Use setDisplayName so the auth user-metadata stays in
            // sync with the profile row — Supabase Dashboard's
            // "Display Name" column reads from auth metadata.
            try await supabase.setDisplayName(trimmedName)
            // RootView re-evaluates as currentUserProfile updates.
        } catch {
            conflictMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
