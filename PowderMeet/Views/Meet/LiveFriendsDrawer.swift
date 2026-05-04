//
//  LiveFriendsDrawer.swift
//  PowderMeet
//
//  Collapsible drawer showing only friends currently live at the same
//  resort. Lives at the top of the Meet tab so users can immediately
//  see who's here and tap to start a meeting flow. Replaces the
//  bottom `FriendsListSection` from earlier builds.
//
//  Per-row presentation data is precomputed by the parent (same shape
//  as the old FriendsListSection.Row). The drawer itself only needs
//  the rows + tap handler + an `isExpanded` binding.
//

import SwiftUI

struct LiveFriendsDrawer: View {
    /// Pre-resolved per-row presentation data. Caller filters to
    /// "live + at resort" before passing.
    struct Row: Identifiable {
        let friend: UserProfile
        let isActive: Bool
        let locationName: String?
        let resortLabel: String

        var id: UUID { friend.id }
    }

    let rows: [Row]
    let onTap: (UserProfile) -> Void
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                Rectangle()
                    .fill(HUDTheme.cardBorder)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)

                if rows.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { row in
                            FriendRowView(
                                friend: row.friend,
                                isActive: row.isActive,
                                isAtResort: true,
                                locationName: row.locationName,
                                resortLabel: row.resortLabel,
                                onTap: { onTap(row.friend) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(HUDTheme.accent)

                Text("FRIENDS HERE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1.5)

                Text("\(rows.count)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(rows.isEmpty ? HUDTheme.secondaryText.opacity(0.5) : HUDTheme.accent)
                    .tracking(0.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill((rows.isEmpty ? HUDTheme.secondaryText : HUDTheme.accent).opacity(0.12))
                    )

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(HUDTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse friends here" : "Expand friends here")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 22))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.2))
            Text("NO FRIENDS HERE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                .tracking(1.5)
            Text("INVITE PEOPLE FROM THE PROFILE TAB")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}
