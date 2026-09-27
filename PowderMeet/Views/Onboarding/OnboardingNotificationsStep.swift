//
//  OnboardingNotificationsStep.swift
//  PowderMeet
//
//  Final onboarding step. Asks the user to enable notifications and
//  blocks CONTINUE until iOS has recorded an answer (granted or denied).
//
//  Why blocking: meet-request pushes are the headline value of having
//  the app on the mountain — without them, a friend tapping POWDERMEET
//  while the receiver's phone is locked just disappears into the void.
//  The fire-and-forget call inside `SupabaseManager.loadProfile` works
//  for existing users who are already past onboarding, but a brand-new
//  signup that finishes onboarding before iOS shows the dialog can hit
//  the trailhead with no `device_tokens` row registered. That window
//  was the gap. Pinning the prompt to a dedicated step closes it.
//

import SwiftUI
import UserNotifications

struct OnboardingNotificationsStep: View {
    /// `.notDetermined` until iOS records an answer, then `.authorized`
    /// or `.denied`. Polled at view appear and after every tap of
    /// "TURN ON NOTIFICATIONS"; bound by `OnboardingView` via the
    /// `onStatusChange` closure so it can gate CONTINUE.
    @State private var status: UNAuthorizationStatus = .notDetermined
    var onStatusChange: (UNAuthorizationStatus) -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("STAY IN THE LOOP")
                .hudType(.title)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)
                .padding(.top, 32)

            // Explainer
            VStack(spacing: 14) {
                explainerRow(
                    icon: "bell.fill",
                    title: "MEET REQUESTS",
                    body: "Friends can ping you to meet up — even when your phone's in your pocket."
                )
                explainerRow(
                    icon: "person.2.fill",
                    title: "FRIEND REQUESTS",
                    body: "Get notified the second someone wants to ski with you."
                )
                explainerRow(
                    icon: "mappin.and.ellipse",
                    title: "ARRIVAL CUES",
                    body: "Quick alert when you've reached the meeting point."
                )
            }
            .padding(.horizontal, 32)

            Spacer()

            // Action
            Button {
                Task { await requestPermission() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: actionIcon)
                        .font(.system(size: 13))
                    Text(actionTitle)
                        .hudType(.bodyEmph)
                        .tracking(1.5)
                }
                .foregroundColor(actionForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(actionBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(actionBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(status == .authorized)
            .padding(.horizontal, 32)
            .padding(.bottom, 12)

            if status == .denied {
                // Denied isn't a dead end — they can still proceed,
                // but we surface a one-line nudge so they know what
                // they're skipping. Tapping the row jumps to Settings.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("OPEN SETTINGS TO ENABLE LATER")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1.2)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshStatus()
        }
    }

    private func explainerRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(HUDTheme.accent)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .hudType(.label)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1.2)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundColor(HUDTheme.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
    }

    // MARK: - Action button styling

    private var actionTitle: String {
        switch status {
        case .authorized:    return "NOTIFICATIONS ON"
        case .denied:        return "NOTIFICATIONS DISABLED"
        case .notDetermined: return "TURN ON NOTIFICATIONS"
        case .provisional, .ephemeral: return "NOTIFICATIONS ON"
        @unknown default:    return "TURN ON NOTIFICATIONS"
        }
    }

    private var actionIcon: String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "checkmark.circle.fill"
        case .denied:        return "exclamationmark.triangle.fill"
        case .notDetermined: return "bell.fill"
        @unknown default:    return "bell.fill"
        }
    }

    private var actionForeground: Color {
        switch status {
        case .authorized, .provisional, .ephemeral: return HUDTheme.primaryText
        case .denied: return HUDTheme.accentAmber
        default: return .white
        }
    }

    private var actionBackground: Color {
        switch status {
        case .authorized, .provisional, .ephemeral: return HUDTheme.cardBackground
        case .denied: return HUDTheme.accentAmber.opacity(0.10)
        default: return HUDTheme.accent
        }
    }

    private var actionBorder: Color {
        switch status {
        case .authorized, .provisional, .ephemeral: return HUDTheme.cardBorder
        case .denied: return HUDTheme.accentAmber.opacity(0.45)
        default: return .clear
        }
    }

    // MARK: - Permission flow

    private func requestPermission() async {
        // Cause iOS to surface the dialog (or no-op if already answered).
        // Notify.ensureAuthorized() is idempotent — first call requests,
        // subsequent calls return without re-prompting because the
        // service caches `didRequestAuthorization`.
        await Notify.shared.ensureAuthorized()
        await refreshStatus()
    }

    private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            status = settings.authorizationStatus
            onStatusChange(status)
        }
    }
}
