//
//  FriendRowView.swift
//  PowderMeet
//
//  Single friend row with avatar, name, location, skill badge, selection indicator.
//  Extracted from MeetView.swift — pure refactor, no behavior changes.
//

import SwiftUI
import CoreLocation

struct FriendRowView: View {
    let friend: UserProfile
    let isActive: Bool
    let isAtResort: Bool
    let locationName: String?
    let resortLabel: String
    var onTap: () -> Void

    var body: some View {
        Button {
            guard isAtResort else { return }
            onTap()
        } label: {
            HStack(spacing: 10) {
                // Avatar
                if let urlString = friend.avatarUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            friendAvatarPlaceholder
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .id(urlString)
                } else {
                    friendAvatarPlaceholder
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isActive ? HUDTheme.accent : HUDTheme.primaryText)
                        .tracking(0.5)
                        .lineLimit(1)

                    if !isAtResort {
                        Text("NOT AT RESORT")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                            .tracking(0.5)
                    } else {
                        // Current on-mountain location (from broadcast)
                        if let locationName = locationName {
                            HStack(spacing: 3) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(HUDTheme.accentGreen)
                                Text(locationName.uppercased())
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundColor(HUDTheme.accentGreen.opacity(0.9))
                                    .tracking(0.5)
                                    .lineLimit(1)
                            }
                        } else {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(HUDTheme.accent)
                                    .frame(width: 5, height: 5)
                                Text(resortLabel)
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundColor(HUDTheme.accent.opacity(0.7))
                                    .tracking(0.5)
                                    .lineLimit(1)
                            }
                        }

                        // Skill level
                        HStack(spacing: 4) {
                            Text(friend.skillLevel.uppercased())
                                .font(.system(size: 7, weight: .medium, design: .monospaced))
                                .foregroundColor(HUDTheme.accent.opacity(0.7))
                                .tracking(0.5)
                        }
                    }
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.accent)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.3))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(isActive ? HUDTheme.accent.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isAtResort ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isAtResort)
    }

    private var friendAvatarPlaceholder: some View {
        Circle()
            .fill(HUDTheme.inputBackground)
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
            )
    }
}
