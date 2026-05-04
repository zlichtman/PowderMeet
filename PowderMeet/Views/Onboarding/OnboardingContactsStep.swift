//
//  OnboardingContactsStep.swift
//  PowderMeet
//
//  Step 3: Contacts permission request for friend suggestions.
//

import SwiftUI
import Contacts

struct OnboardingContactsStep: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.rectangle.stack.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    statusGranted ? HUDTheme.accentGreen : HUDTheme.accent,
                    statusGranted ? HUDTheme.accentGreen.opacity(0.3) : HUDTheme.accent.opacity(0.3)
                )

            Text("FIND YOUR FRIENDS")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)

            Text("ALLOW POWDERMEET TO CHECK YOUR CONTACTS TO FIND FRIENDS ALREADY ON THE APP")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText)
                .multilineTextAlignment(.center)
                .tracking(0.5)
                .lineSpacing(4)
                .padding(.horizontal, 28)

            if statusGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.accentGreen)
                    Text("CONTACTS ENABLED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.accentGreen)
                        .tracking(1)
                }
                .padding(.top, 8)
            } else if status == .denied || status == .restricted {
                Text("CONTACTS DENIED — OPEN SETTINGS TO ENABLE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accentAmber)
                    .tracking(0.5)
            }

            Spacer()
            Spacer()
        }
        .onAppear {
            status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined {
                Task {
                    _ = await ContactsService.shared.fetchContactEmails()
                    status = CNContactStore.authorizationStatus(for: .contacts)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // If the user toggled permission in Settings, pick it up on return.
            if phase == .active {
                status = CNContactStore.authorizationStatus(for: .contacts)
            }
        }
    }

    private var statusGranted: Bool {
        status == .authorized
    }
}
