//
//  SentRequestsSheet.swift
//  PowderMeet
//
//  Friends → SENT REQUESTS sheet. Lists every outbound friend request
//  that's still pending, with a CANCEL action per row. Mirrors the
//  visual + behavioral pattern of `BlockedUsersSheet` so the two
//  bottom-of-list folders feel like siblings.
//
//  The previous inline "WAITING" section in FriendsSheet had two
//  problems:
//    1. The row showed "FRIEND" instead of the addressee's name —
//       `loadPendingProfiles` only fetched profiles for inbound
//       requests, leaving the outbound side blank.
//    2. The list could grow long enough to push the friends section
//       below the fold; relegating it to a sheet keeps the main
//       Friends scroll focused on relationships you've already
//       confirmed.
//

import SwiftUI

struct SentRequestsSheet: View {
    @Environment(FriendService.self) private var friendService
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [UUID: UserProfile] = [:]
    @State private var requestToCancel: UserProfile?

    var body: some View {
        // Custom HStack header instead of NavigationStack + toolbar:
        // iOS 18+ wraps every ToolbarItem in the system Liquid Glass
        // backdrop, which fights our HUDDoneButton chip. Same pattern
        // as ResortPickerSheet / FriendSearchSheet.
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 8) {
                        if friendService.pendingSent.isEmpty {
                            emptyState
                                .padding(.top, 60)
                        } else {
                            ForEach(friendService.pendingSent) { request in
                                sentRow(request)
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
            await loadProfiles()
        }
        .alert("Withdraw request?", isPresented: Binding(
            get: { requestToCancel != nil },
            set: { if !$0 { requestToCancel = nil } }
        )) {
            Button("Keep", role: .cancel) { requestToCancel = nil }
            Button("Withdraw", role: .destructive) {
                guard let target = requestToCancel else { return }
                requestToCancel = nil
                Task { try? await friendService.cancelSentRequest(to: target.id) }
            }
        } message: {
            Text("Cancel your friend request to \(requestToCancel?.displayName ?? "this user")?")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("SENT REQUESTS")
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
            Image(systemName: "paperplane")
                .font(.system(size: 28))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.4))

            Text("NO PENDING REQUESTS")
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText.opacity(0.7))
                .tracking(1.5)

            Text("When you send a friend request, it appears here until the other user accepts or you cancel it.")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Row

    private func sentRow(_ request: Friendship) -> some View {
        let user = profiles[request.addresseeId]
        let displayName = user?.displayName ?? "—"
        return HStack(spacing: 12) {
            if let user {
                avatarView(user, size: 36)
                    .opacity(0.85)
            } else {
                placeholder(size: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.uppercased())
                    .hudType(.section)
                    .foregroundColor(HUDTheme.primaryText.opacity(0.85))
                    .tracking(0.5)
                    .lineLimit(1)
                Text("REQUEST SENT")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accentAmber.opacity(0.8))
                    .tracking(0.5)
            }

            Spacer()

            Button {
                requestToCancel = user ?? UserProfile.defaultProfile(id: request.addresseeId)
            } label: {
                Text("CANCEL")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accentAmber)
                    .tracking(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(HUDTheme.accentAmber.opacity(0.12))
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

    // MARK: - Profile loading

    private func loadProfiles() async {
        for request in friendService.pendingSent {
            if profiles[request.addresseeId] == nil {
                if let profile = await friendService.loadProfile(id: request.addresseeId) {
                    profiles[request.addresseeId] = profile
                }
            }
        }
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
