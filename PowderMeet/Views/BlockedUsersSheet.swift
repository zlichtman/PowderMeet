//
//  BlockedUsersSheet.swift
//  PowderMeet
//
//  Account → BLOCKED USERS sheet. Lists every user the local user has
//  blocked, with an UNBLOCK action per row. Reads from `FriendService`
//  state — `loadBlockedProfiles()` runs on appear since blocks have no
//  realtime channel and we want a fresh snapshot when the sheet opens.
//
//  Design: same HUD card treatment as the rest of the Account surfaces
//  so this feels native to the settings area, not a foreign list view.
//  Empty state explicitly tells the user where blocks come from
//  (long-press menu) so they understand the entry point if they tap
//  in expecting an "add to block list" action.
//

import SwiftUI

struct BlockedUsersSheet: View {
    @Environment(FriendService.self) private var friendService
    @Environment(\.dismiss) private var dismiss

    @State private var unblockTarget: UserProfile?

    var body: some View {
        // Custom HStack header instead of NavigationStack + toolbar:
        // iOS 18+ wraps every ToolbarItem in the system Liquid Glass
        // backdrop, which fights our HUDDoneButton chip. The same
        // pattern as ResortPickerSheet / FriendSearchSheet.
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 8) {
                        if friendService.blockedProfiles.isEmpty {
                            emptyState
                                .padding(.top, 60)
                        } else {
                            ForEach(friendService.blockedProfiles) { profile in
                                blockedRow(profile)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await friendService.loadBlocks()
            await friendService.loadBlockedProfiles()
        }
        .alert("Unblock this user?", isPresented: Binding(
            get: { unblockTarget != nil },
            set: { if !$0 { unblockTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { unblockTarget = nil }
            Button("Unblock") {
                guard let target = unblockTarget else { return }
                unblockTarget = nil
                Task { await friendService.unblock(target.id) }
            }
        } message: {
            Text("\(unblockTarget?.displayName ?? "This user") will be able to see your activity again. Your previous friendship is not restored — you'll need to send a new request.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("BLOCKED USERS")
                .hudType(.bodyEmph)
                .foregroundColor(HUDTheme.accent)
                .tracking(2)
            Spacer()
            HUDDoneButton()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.system(size: 28))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.4))

            Text("NO ONE BLOCKED")
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText.opacity(0.7))
                .tracking(1.5)

            Text("Long-press a friend, contact, or search result to block them. Blocks hide both sides — you won't see their activity and they won't see yours.")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Row

    private func blockedRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            avatarView(profile, size: 36)
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName.uppercased())
                    .hudType(.section)
                    .foregroundColor(HUDTheme.primaryText.opacity(0.8))
                    .tracking(0.5)
                    .lineLimit(1)
                Text("BLOCKED")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)
            }

            Spacer()

            Button {
                unblockTarget = profile
            } label: {
                Text("UNBLOCK")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(HUDTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatarView(_ profile: UserProfile, size: CGFloat) -> some View {
        if let urlString = profile.avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder(size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(HUDTheme.cardBorder, lineWidth: 0.5))
        } else {
            placeholder(size: size)
        }
    }

    private func placeholder(size: CGFloat) -> some View {
        Circle()
            .fill(HUDTheme.inputBackground)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
            )
    }
}
