import PowderMeetAPI
import SwiftUI

/// Friends → Blocked: everyone this user has blocked, each with Unblock. The
/// empty state says where blocks come from, since there is no "add" here.
struct BlockedUsersSheet: View {
    @Environment(AppModel.self) private var model
    @State private var unblockTarget: SocialSnapshot.Person?

    init() {}

    var body: some View {
        Group {
            if model.social.blocks.isEmpty {
                EmptyStateView(
                    icon: "hand.raised", title: "No one blocked",
                    detail: "Long-press a friend, a contact or a request to block or report them. "
                        + "Blocks hide both sides: you won't see their activity and they won't see yours.")
                    .glassCard()
            } else {
                GlassSection {
                    ForEach(Array(model.social.blocks.enumerated()), id: \.element.id) { index, person in
                        if index > 0 { GlassDivider(inset: 66) }
                        PersonRow(userID: person.userID, path: person.avatarURL, name: person.displayName, detail: "Blocked") {
                            SecondaryButton(title: "Unblock", fillsWidth: false) { unblockTarget = person }
                                .accessibilityLabel("Unblock \(person.displayName)")
                        }
                    }
                }
            }
        }
        .pageScroll()
        .confirmCard(
            item: $unblockTarget, title: { "Unblock \($0.displayName)?" },
            message: { _ in "They will be able to see your activity again. Your friendship is not restored; send a new request for that." },
            confirm: "Unblock", isDestructive: false
        ) { model.unblock($0.userID) }
    }
}
