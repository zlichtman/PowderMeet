//
//  PendingRequestCard.swift
//  PowderMeet
//
//  Single pending friend request card (ACCEPT/DECLINE).
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI

struct PendingRequestCard: View {
    @Environment(FriendService.self) private var friendService

    let request: Friendship
    let requestProfile: UserProfile?

    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            if let urlString = requestProfile?.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: smallAvatarPlaceholder(size: 32)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .id(urlString)
            } else {
                smallAvatarPlaceholder(size: 32)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text((requestProfile?.displayName ?? "UNKNOWN").uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
                Text("WANTS TO CONNECT")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    Task {
                        do {
                            try await friendService.acceptRequest(request.id)
                        } catch {
                            errorMessage = "Couldn't accept: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(HUDTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        do {
                            try await friendService.declineRequest(request.id)
                        } catch {
                            errorMessage = "Couldn't decline: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(HUDTheme.secondaryText.opacity(0.3))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.accentAmber.opacity(0.3), lineWidth: 1)
        )
        .alert("ERROR", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func smallAvatarPlaceholder(size: CGFloat) -> some View {
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
