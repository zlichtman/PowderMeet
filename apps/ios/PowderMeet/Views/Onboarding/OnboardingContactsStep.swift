import AppCore
import PowderMeetAPI
import SwiftUI
import UIKit

/// Last step. Contacts: finds friends already on PowderMeet by the email
/// addresses in the address book. The card says why first; the system prompt
/// comes only from the step's own button ("Find Friends in Contacts", in
/// `OnboardingView`). The matches are listed with Add.
struct OnboardingContactsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var discovery: DiscoveryState { model.discovery }

    private var denied: Bool { discovery.access == .denied }

    private var granted: Bool {
        discovery.hasSearched && !denied && discovery.failure == nil
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.rectangle.stack.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    granted ? HUDTheme.accentGreen : HUDTheme.accent,
                    granted ? HUDTheme.accentGreen.opacity(0.3) : HUDTheme.accent.opacity(0.3)
                )

            Text("Find Your Friends")
                .textRole(.title)
                .foregroundColor(HUDTheme.primaryText)

            if !discovery.hasSearched, !discovery.isSearching, !denied {
                Text("PowderMeet checks the email addresses in your contacts to find friends already here. Only scrambled (hashed) email addresses are sent to find them; names and numbers stay on your phone.")
                    .textRole(.body)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            status

            if granted, !discovery.matches.isEmpty {
                // The step scrolls as a whole, so the list is not a scroll of its own.
                VStack(spacing: 0) {
                    ForEach(Array(discovery.matches.enumerated()), id: \.element.id) { index, match in
                        if index > 0 { GlassDivider(inset: 66) }
                        matchRow(match)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()
            Spacer()
        }
        .onboardingStepScroll()
        // Access may already be decided (Settings, an earlier install).
        .onAppear { model.refreshContactsAccess() }
    }

    @ViewBuilder
    private var status: some View {
        if discovery.isSearching {
            ProgressView()
                .tint(HUDTheme.accent)
                .scaleEffect(0.8)
                .padding(.top, 8)
        } else if denied {
            VStack(spacing: 12) {
                Text("Contacts access is off. You can turn it on in Settings.")
                    .textRole(.body)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .multilineTextAlignment(.center)
                SecondaryButton(title: "Open Settings", fillsWidth: false) {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                }
            }
            .padding(.horizontal, 28)
        } else if let failure = discovery.failure {
            VStack(spacing: 12) {
                Text(failure.userMessage)
                    .textRole(.label)
                    .foregroundColor(HUDTheme.accentAmber)
                    .multilineTextAlignment(.center)
                SecondaryButton(title: "Try again", systemImage: "arrow.clockwise", fillsWidth: false) {
                    model.findFriendsFromContacts()
                }
            }
            .padding(.horizontal, 28)
        } else if granted {
            VStack(spacing: 8) {
                Label("Contacts checked", systemImage: "checkmark.circle.fill")
                    .textRole(.section)
                    .foregroundColor(HUDTheme.accentGreen)
                if discovery.matches.isEmpty {
                    Text("No one in your contacts is on PowderMeet yet")
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
            }
            .padding(.top, 8)
        }
    }

    private func matchRow(_ match: UserMatch) -> some View {
        PersonRow(userID: match.id, path: match.avatarURL, name: match.displayName) {
            relationship(match)
        }
    }

    @ViewBuilder
    private func relationship(_ match: UserMatch) -> some View {
        let social = model.social
        if social.friends.contains(where: { $0.userID == match.id }) {
            StatusChip(text: "Friends", tint: HUDTheme.accentGreen)
        } else if social.pendingOut.contains(where: { $0.userID == match.id }) {
            StatusChip(text: "Request sent", tint: HUDTheme.accentAmber)
        } else if let request = social.pendingIn.first(where: { $0.userID == match.id }),
                  let friendshipID = request.friendshipID {
            // They asked first: Accept answers their request.
            SecondaryButton(title: "Accept", systemImage: "checkmark", fillsWidth: false) {
                model.respondToFriendRequest(friendshipID, accept: true)
            }
            .accessibilityLabel("Accept friend request from \(match.displayName)")
        } else {
            SecondaryButton(title: "Add", systemImage: "person.badge.plus", fillsWidth: false) {
                model.requestFriend(match.id)
            }
            .accessibilityLabel("Send friend request to \(match.displayName)")
        }
    }
}
