import AppCore
import MapScene
import MeetSolver
import PowderMeetAPI
import SwiftUI

/// A friend's card, laid out like the user's own profile card: photo and name,
/// their ski pair (their topsheet or the PowderMeet ski), their four lifetime
/// stats, where they are now, and Meet up; Remove, Block and Report are in the
/// title bubble's "…" (`FriendCardMenu`), away from Meet up. Everything
/// comes from the friend's `social_snapshot()` entry and, at the open resort,
/// their live position; the card asks for a fresh snapshot when it opens.
/// A sheet from the map, or a page pushed from Friends.
struct FriendCardSheet: View {
    @Environment(AppModel.self) private var model

    let friendID: UUID

    private var friend: SocialSnapshot.Person? { model.social.friends.first { $0.userID == friendID } }

    var body: some View {
        Group {
            if let friend {
                card(friend)
            } else {
                // Removed or blocked while the card was open, from here or elsewhere.
                EmptyStateView(icon: "person.crop.circle.badge.xmark", title: "Not on your friends list")
                    .glassCard()
                    .pageScroll()
            }
        }
        .onAppear { model.refreshFriends() }
    }

    private func card(_ friend: SocialSnapshot.Person) -> some View {
        let gear = Self.gear(friend)
        let ability = Ability(profileValue: friend.ability ?? "intermediate").label
        return Group {
            VStack(spacing: 14) {
                AvatarView(userID: friend.userID, path: friend.avatarURL, name: friend.displayName, size: 88)
                VStack(spacing: 4) {
                    Text(friend.displayName)
                        .textRole(.display)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    Text(sinceLine(friend, ability: ability))
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                }
                SkiPairView(
                    topLabel: gear.label ?? "PowderMeet", bottomLabel: ability,
                    highlight: liveHere(friend) ? .onMountain : .none, look: gear.look
                )
                .padding(.horizontal, 8)
                stats(friend.stats)
            }
            .frame(maxWidth: .infinity)
            .glassCard()

            GlassSection("Now") {
                whereNow(friend)
            }

            actions(friend)
        }
        .pageScroll()
    }

    private func sinceLine(_ friend: SocialSnapshot.Person, ability: String) -> String {
        guard let since = friend.at else { return ability }
        return "\(ability) · friends since \(since.formatted(.dateTime.month(.wide).year()))"
    }

    /// The same four figures as the user's own card, in the device's units; a
    /// dash for a figure no run has measured.
    private func stats(_ stats: LifetimeStats?) -> some View {
        func shown(_ value: Double?, _ format: (Double) -> String) -> String {
            value.flatMap { $0 > 0 ? format($0) : nil } ?? "—"
        }
        return StatBoxRow {
            StatBox(label: "Distance", value: shown(stats?.distanceM, UnitFormatter.distance))
            StatBox(label: "Vertical", value: shown(stats?.verticalM, UnitFormatter.verticalDrop))
            StatBox(label: "Avg speed", value: shown(stats?.avgSpeedMS, UnitFormatter.speed))
            StatBox(label: "Top speed", value: shown(stats?.topSpeedMS, UnitFormatter.speed))
        }
    }

    /// Live at the open resort; else the last position the server still holds
    /// (15 minutes); else not on the mountain.
    private func whereNow(_ friend: SocialSnapshot.Person) -> some View {
        if let presence = model.resort?.friends[friend.userID] {
            let resort = model.selectedResort?.name ?? "the mountain"
            // The run or lift while the map can tell; else just the resort.
            let place = FriendSignal.classify(lastSeen: presence.capturedAt, now: Date()) == .live
                ? model.resort?.places[friend.userID] : nil
            return GlassRow(
                icon: "location.fill", title: place ?? "At \(resort)",
                detail: "Seen \(Wording.age(since: presence.capturedAt).lowercased())", iconTint: HUDTheme.accentGreen)
        }
        if let seen = friend.lastSeen {
            let resort = seen.resortID.flatMap { id in model.catalog.resorts.first { $0.id == id }?.name }
            return GlassRow(
                icon: "location.fill", title: resort.map { "At \($0)" } ?? "On the move",
                detail: "Seen \(Wording.age(since: seen.at).lowercased())", iconTint: HUDTheme.accentGreen)
        }
        return GlassRow(icon: "location.slash", title: "Not on the mountain right now", iconTint: HUDTheme.secondaryText)
    }

    private func liveHere(_ friend: SocialSnapshot.Person) -> Bool {
        model.resort?.friends[friend.userID] != nil
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ friend: SocialSnapshot.Person) -> some View {
        let canMeet = liveHere(friend) && model.canStartMeet
        PrimaryButton(title: "Meet up", systemImage: "location.fill.viewfinder", isEnabled: canMeet) {
            model.startMeet(with: friend.userID)
        }
        .accessibilityHint(canMeet ? "" : "Available when you both have this resort open")
    }

    /// The friend's gear read the way the user's own is, for the ski pair.
    static func gear(_ friend: SocialSnapshot.Person) -> GearDraft {
        GearDraft(Profile(
            id: friend.userID, displayName: friend.displayName, ability: friend.ability ?? "intermediate",
            equipment: friend.equipment
        ))
    }
}

/// The "…" in a friend card's title bubble: Remove, Block and Report, each
/// asking first where it cannot be undone, as on the Friends rows.
struct FriendCardMenu: View {
    @Environment(AppModel.self) private var model
    let friendID: UUID

    @State private var confirmsRemove = false
    @State private var confirmsBlock = false

    private var friend: SocialSnapshot.Person? { model.social.friends.first { $0.userID == friendID } }

    var body: some View {
        if let friend {
            Menu {
                Button { confirmsRemove = true } label: { Label("Remove", systemImage: "person.fill.xmark") }
                Button(role: .destructive) { confirmsBlock = true } label: {
                    Label("Block", systemImage: "hand.raised.fill")
                }
                Button(role: .destructive) {
                    model.pushPanel(.report(ReportTarget(
                        userID: friend.userID, displayName: friend.displayName, avatarURL: friend.avatarURL,
                        context: .friend
                    )))
                } label: {
                    Label("Report", systemImage: "exclamationmark.bubble.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HUDTheme.primaryText)
                    .frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Actions for \(friend.displayName)")
            .confirmCard(
                "Remove friend?", isPresented: $confirmsRemove,
                message: "\(friend.displayName) will be removed from your friends. You can add them back later.",
                confirm: "Remove"
            ) {
                model.removeFriend(friend.userID)
                leave()
            }
            .confirmCard(
                "Block \(friend.displayName)?", isPresented: $confirmsBlock,
                message: "\(friend.displayName) won't see your activity and you won't see theirs. You can unblock them under Friends → Blocked.",
                confirm: "Block"
            ) {
                model.block(friend.userID)
                leave()
            }
        }
    }

    /// Back from the card to the level above.
    private func leave() {
        model.leavePanelPage(.friendCard(friendID))
    }
}
