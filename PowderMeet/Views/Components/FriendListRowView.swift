//
//  FriendListRowView.swift
//  PowderMeet
//
//  Equatable friend row used in the Profile → FRIENDS sub-tab.
//
//  Why this exists: `loadSocialSnapshot` re-runs on every friendships
//  realtime event and returns a freshly-decoded friend struct each
//  time. Even with the snapshot-diff guard in `FriendService`, server-
//  managed columns like `updated_at` keep flipping the array contents
//  to "different" — every row re-runs its body, every body re-runs
//  the synchronous `TopsheetCache.load` and re-creates the
//  `CachedAvatarView`. Visually this reads as the avatar + ski combo
//  flickering during snapshot ticks even when nothing visible changed.
//
//  Conforming the row to `Equatable` and applying `.equatable()` at
//  the call site lets SwiftUI skip the body re-run entirely whenever
//  the visible fields (id, name, skill, avatar URL, ski id, online
//  flag) match. Closures + the resolved catalog entry are excluded
//  from `==` since they don't drive the rendered output.
//

import SwiftUI

struct FriendListRowView: View, Equatable {
    let friendId: UUID
    let displayName: String
    let skillLevel: String
    let avatarUrl: String?
    let preferredSkiId: UUID?
    let skiEntry: SkiCatalogEntry?
    let isOnline: Bool

    let onUnfriend: () -> Void
    let onBlock: () -> Void

    /// Compare ONLY render-relevant fields. Closures aren't equatable
    /// and shouldn't influence the diff anyway.
    ///
    /// IMPORTANT: include `skiEntry?.topsheetAssetKey` in the diff.
    /// `skiEntry` is resolved from the session-cached catalog at row
    /// construction time, and on cold launch the catalog isn't yet
    /// hydrated when the social snapshot lands — `skiCatalogEntry(forSkiId:)`
    /// returns nil for that first render. When `fetchSkisCatalog()`
    /// completes and bumps `skisCatalogVersion`, FriendsSheet reconstructs
    /// the row with the now-resolved entry; if `==` doesn't see the
    /// nil→entry transition (because preferredSkiId is unchanged) it
    /// short-circuits the re-render and the topsheet never paints —
    /// until some OTHER field (online flag, name) flips and the body
    /// runs again, popping the ski in late. That late pop is the
    /// "friend's skis preview glitches out" symptom.
    static func == (lhs: FriendListRowView, rhs: FriendListRowView) -> Bool {
        lhs.friendId == rhs.friendId
            && lhs.displayName == rhs.displayName
            && lhs.skillLevel == rhs.skillLevel
            && lhs.avatarUrl == rhs.avatarUrl
            && lhs.preferredSkiId == rhs.preferredSkiId
            && lhs.skiEntry?.topsheetAssetKey == rhs.skiEntry?.topsheetAssetKey
            && lhs.isOnline == rhs.isOnline
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAvatarView(urlString: avatarUrl, size: SkiPairView.defaultPairHeight) {
                avatarPlaceholder
            }
            .overlay(
                Circle()
                    .stroke(isOnline ? HUDTheme.accentGreen : Color.clear, lineWidth: 2)
            )

            SkiPairView(
                topLabel: displayName,
                bottomLabel: skillLevel,
                entry: skiEntry,
                showFallback: false
            )
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: onUnfriend) {
                Label("Unfriend", systemImage: "person.fill.xmark")
            }
            Button(role: .destructive, action: onBlock) {
                Label("Block", systemImage: "hand.raised.fill")
            }
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(HUDTheme.inputBackground)
            .frame(
                width: SkiPairView.defaultPairHeight,
                height: SkiPairView.defaultPairHeight
            )
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: SkiPairView.defaultPairHeight * 0.4))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
            )
    }
}
