//
//  OnboardingView.swift
//  PowderMeet
//
//  Three-step onboarding container: combined profile/skill/import →
//  contacts → location. Display name is collected at sign-up; SKIP is
//  not offered — every step records an explicit decision.
//

import SwiftUI
import Supabase

struct OnboardingView: View {
    @Environment(SupabaseManager.self) private var supabase

    @State private var step = 0
    @State private var avatarData: Data?
    @State private var skillLevel = "intermediate"
    @State private var isSaving = false
    @State private var saveError: String?

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // ── Progress dots ──
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? HUDTheme.accent : HUDTheme.cardBorder)
                        .frame(width: i == step ? 24 : 8, height: 4)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            // ── Step content ──
            ZStack {
                switch step {
                case 0:
                    OnboardingProfileStep(avatarData: $avatarData, skillLevel: $skillLevel)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case 1:
                    OnboardingContactsStep()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case 2:
                    OnboardingLocationStep()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                default:
                    EmptyView()
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: step)

            // ── Continue / Get Started button ──
            // No SKIP affordance — every step records an explicit
            // decision before the user can advance.
            Button {
                if step < totalSteps - 1 {
                    step += 1
                } else {
                    Task { await completeOnboarding() }
                }
            } label: {
                HStack {
                    if isSaving {
                        ProgressView().tint(HUDTheme.spinnerForm).scaleEffect(0.7)
                    }
                    Text(step < totalSteps - 1 ? "CONTINUE" : "GET STARTED")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .tracking(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(continueEnabled ? HUDTheme.accent : HUDTheme.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!continueEnabled || isSaving)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .alert("SAVE FAILED", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "An unknown error occurred. Please try again.")
        }
    }

    private var continueEnabled: Bool {
        // Display name is collected at sign-up (or supplied by Apple Sign-In),
        // so step 0 (avatar) doesn't gate CONTINUE. The avatar is optional —
        // skipping the photo only avoids the upload step in completeOnboarding.
        return true
    }

    private func completeOnboarding() async {
        isSaving = true

        // Ensure the profile row exists — retry up to 3 times
        print("[Onboarding] Step 1: ensureProfileExists...")
        var profileReady = false
        for attempt in 1...3 {
            profileReady = await supabase.ensureProfileExists()
            if profileReady { break }
            print("[Onboarding] ensureProfileExists attempt \(attempt) failed, retrying...")
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !profileReady {
            print("[Onboarding] Could not create profile after 3 attempts")
            saveError = "Failed to create your profile. Please check your connection and try again."
            isSaving = false
            return
        }
        print("[Onboarding] Step 1 done")

        // Upload avatar if set. We deliberately DON'T mark onboarding
        // complete if the user picked an avatar and the upload fails —
        // otherwise a backgrounded mid-upload (lost network on a chairlift,
        // app suspended) leaves them with onboarding_completed=true and
        // no avatar, with no UI path to retry. Surfacing an error here
        // keeps them on the onboarding sheet so a Continue retap retries
        // just the upload.
        var avatarUrlString: String?
        if let avatarData {
            print("[Onboarding] Step 2: uploading avatar (\(avatarData.count) bytes)...")
            // One quick retry — onboarding fires immediately after signUp,
            // and the Storage call sometimes races the session-token install
            // by 1-2s on the first request. A second attempt with a brief
            // pause clears that path without surfacing a transient error.
            var lastError: Error?
            for attempt in 0..<2 {
                do {
                    avatarUrlString = try await supabase.uploadAvatar(imageData: avatarData)
                    print("[Onboarding] Step 2 done: \(avatarUrlString ?? "nil")")
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    print("[Onboarding] Avatar upload attempt \(attempt + 1) failed: \(error)")
                    if attempt == 0 {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            if let err = lastError {
                // Surface the actual error so we can diagnose instead of
                // hiding behind a generic 'check your connection'. RLS
                // failures, mime mismatches, sandbox issues all read
                // differently and the user (or whoever's debugging) can
                // tell which is which.
                let detail = err.localizedDescription
                saveError = "Couldn't upload your photo: \(detail). Tap GET STARTED to retry, or skip the photo."
                isSaving = false
                return
            }
        }

        // Build profile updates with preset speeds for the chosen tier.
        // display_name was set by the sign-up flow (email form or Apple
        // credential), so we don't write it again here.
        let speeds = Self.presetSpeeds(for: skillLevel)

        var updates: [String: AnyJSON] = [
            "skill_level": .string(skillLevel),
            "speed_green": .double(speeds.green),
            "speed_blue": .double(speeds.blue),
            "onboarding_completed": .bool(true)
        ]

        if let url = avatarUrlString { updates["avatar_url"] = .string(url) }
        if let sb = speeds.black { updates["speed_black"] = .double(sb) }
        if let sdb = speeds.doubleBlack { updates["speed_double_black"] = .double(sdb) }
        if let stp = speeds.terrainPark { updates["speed_terrain_park"] = .double(stp) }

        print("[Onboarding] Step 3: updating profile...")
        do {
            try await supabase.updateProfile(updates)
            if supabase.currentUserProfile?.onboardingCompleted != true {
                print("[Onboarding] Profile not updated locally, reloading...")
                await supabase.loadProfile()
            }
            print("[Onboarding] Step 3 done — onboarding complete!")
        } catch {
            print("[Onboarding] DB update failed: \(error)")
            saveError = "Failed to save your profile. Please check your connection and try again."
            isSaving = false
            return
        }

        isSaving = false
    }

    // MARK: - Preset Speeds

    private static func presetSpeeds(for level: String) -> (green: Double, blue: Double, black: Double?, doubleBlack: Double?, terrainPark: Double?) {
        switch level {
        case "beginner":
            return (green: 4, blue: 2, black: nil, doubleBlack: nil, terrainPark: nil)
        case "intermediate":
            return (green: 7, blue: 5, black: 3, doubleBlack: nil, terrainPark: 4)
        case "advanced":
            return (green: 10, blue: 8, black: 6, doubleBlack: 4, terrainPark: 6)
        case "expert":
            return (green: 12, blue: 10, black: 9, doubleBlack: 7, terrainPark: 8)
        default:
            return (green: 7, blue: 5, black: 3, doubleBlack: nil, terrainPark: 4)
        }
    }
}
