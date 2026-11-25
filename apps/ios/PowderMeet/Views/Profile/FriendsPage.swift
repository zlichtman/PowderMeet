import AppCore
import MapScene
import MeetSolver
import PowderMeetAPI
import SwiftUI

/// Friends (`specs/13-APP-MAP.md` section 3), and the only place friend
/// requests appear: requests waiting, your friends (a tap opens their card),
/// friends found from the email addresses in your contacts, requests you
/// sent, and the blocked list. The search field at the bottom finds anyone by name; while it
/// holds a query the page shows only the people found. Remove, block and
/// report sit behind each row's "…" and long press.
struct FriendsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var friendToRemove: PersonTarget?
    @State private var userToBlock: PersonTarget?
    @State private var requestToWithdraw: PersonTarget?
    /// Suggestions hidden until the page next opens: nothing stores them, so
    /// the control says "for now".
    @State private var hiddenSuggestions: Set<UUID> = []

    private var social: SocialSnapshot { model.social }

    /// The public TestFlight link, shared when a name search finds no one.
    private static let inviteURL = URL(string: "https://testflight.apple.com/join/dejcRSgp")!

    var body: some View {
        Group {
            if model.peopleSearch.isActive {
                searchResults
            } else {
                lists
            }
        }
        .pageScroll {
            BottomSearchBar(text: $query, prompt: "Search by name", focus: $searchFocused)
        }
        .onChange(of: query) { _, new in model.searchPeople(new) }
        .onAppear {
            model.refreshFriends()
            // At most once a day, and only with Contacts access already given.
            model.refreshContactMatchesIfDue()
            // Back from a pushed card or report: the field still holds the query.
            if !query.isEmpty { model.searchPeople(query) }
            // Opened from "+ Add friend": the search field takes the keyboard.
            if model.focusesPeopleSearch {
                model.focusesPeopleSearch = false
                searchFocused = true
            }
        }
        .onDisappear { model.searchPeople("") }
        // Back from Settings: access may have changed there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshContactMatchesIfDue() }
        }
        .modifier(FriendAlerts(
            friendToRemove: $friendToRemove, userToBlock: $userToBlock, requestToWithdraw: $requestToWithdraw))
    }

    @ViewBuilder
    private var lists: some View {
        if !social.pendingIn.isEmpty {
            GlassSection("Requests · \(social.pendingIn.count)", accent: HUDTheme.accent) {
                rows(social.pendingIn) { requestRow($0) }
            }
        }

        // No empty state: with the keyboard up for a name search the page stays put.
        if !social.friends.isEmpty {
            GlassSection("Your friends · \(social.friends.count)") {
                rows(social.friends) { friendRow($0) }
            }
        }

        if !suggestions.isEmpty {
            GlassSection("From Your Contacts") {
                rows(suggestions) { suggestionRow($0) }
            }
        }

        GlassSection("Contacts") {
            contactsRow
        }

        if !social.pendingOut.isEmpty {
            GlassSection("Sent · \(social.pendingOut.count)") {
                rows(social.pendingOut) { sentRow($0) }
            }
        }

        if !social.blocks.isEmpty {
            GlassSection {
                GlassLinkRow(
                    icon: "hand.raised.fill", title: "Blocked", value: "\(social.blocks.count)",
                    route: PanelRoute.blocked)
            }
        }
    }

    /// Rows split by hairlines.
    private func rows<Item: Identifiable, Row: View>(
        _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { GlassDivider(inset: 66) }
            row(item)
        }
    }

    // MARK: Search by name

    @ViewBuilder
    private var searchResults: some View {
        let search = model.peopleSearch
        let found = model.peopleFound
        if let failure = search.failure {
            EmptyStateView(icon: "exclamationmark.triangle", title: failure.userMessage)
                .glassCard()
        } else if search.answered != nil, !found.isEmpty {
            GlassSection("People") {
                rows(found) { searchRow($0) }
            }
        } else if search.isSearching || search.answered != search.query {
            ProgressView()
                .tint(HUDTheme.spinnerInteractive)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 4) {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No one called “\(search.query.trimmingCharacters(in: .whitespaces))”",
                    detail: "They may not have joined yet.")
                ShareLink(
                    item: Self.inviteURL,
                    message: Text("Join me on PowderMeet so we can find each other on the mountain.")
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                        Text("Invite to PowderMeet")
                            .textRole(.bodyEmph)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(HUDTheme.primaryText)
                    .padding(.horizontal, 16)
                    .frame(minHeight: GlassLayout.chipHeight)
                    .background(HUDGlass.well, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
            }
            .glassCard()
        }
    }

    @ViewBuilder
    private func searchRow(_ person: UserSearchResult) -> some View {
        let target = PersonTarget(id: person.userID, displayName: person.displayName)
        switch person.relation {
        case .friend:
            Button { model.pushPanel(.friendCard(person.userID)) } label: {
                PersonRow(userID: person.userID, path: person.avatarURL, name: person.displayName, detail: "Friend") {
                    moreMenu(person.displayName) { searchActions(person) }
                    GlassChevron()
                }
            }
            .buttonStyle(.plain)
            .contextMenu { searchActions(person) }
            .accessibilityActions { searchActions(person) }
        case .requestReceived:
            PersonRow(
                userID: person.userID, path: person.avatarURL, name: person.displayName, detail: "Wants to be friends"
            ) {
                moreMenu(person.displayName) { searchActions(person) }
                IconButton(
                    systemImage: "checkmark", label: "Accept friend request from \(person.displayName)",
                    tint: HUDTheme.accent
                ) {
                    if let friendshipID = model.receivedRequest(from: person.userID) {
                        model.respondToFriendRequest(friendshipID, accept: true)
                    } else {
                        // `friend_request` accepts a request they already sent.
                        model.requestFriend(person.userID)
                    }
                }
            }
            .contextMenu { searchActions(person) }
        case .requestSent:
            PersonRow(userID: person.userID, path: person.avatarURL, name: person.displayName, detail: "Request sent") {
                moreMenu(person.displayName) { searchActions(person) }
                SecondaryButton(title: "Cancel", fillsWidth: false) { requestToWithdraw = target }
                    .accessibilityLabel("Cancel friend request to \(person.displayName)")
            }
            .contextMenu { searchActions(person) }
        case .none:
            PersonRow(userID: person.userID, path: person.avatarURL, name: person.displayName) {
                moreMenu(person.displayName) { searchActions(person) }
                IconButton(
                    systemImage: "person.badge.plus", label: "Send friend request to \(person.displayName)",
                    tint: HUDTheme.accent
                ) {
                    model.requestFriend(person.userID)
                }
            }
            .contextMenu { searchActions(person) }
        }
    }

    @ViewBuilder
    private func searchActions(_ person: UserSearchResult) -> some View {
        if person.relation == .friend {
            Button(role: .destructive) {
                friendToRemove = PersonTarget(id: person.userID, displayName: person.displayName)
            } label: {
                Label("Remove friend", systemImage: "person.fill.xmark")
            }
        }
        blockAndReport(person.userID, person.displayName, person.avatarURL, context: Self.reportContext(person.relation))
    }

    /// `user_reports.context` has no "search" (0017): someone found by name who
    /// is not a friend or a request is reported as found directly, as an add
    /// code was.
    private static func reportContext(_ relation: SearchRelation) -> ReportContext {
        switch relation {
        case .friend: .friend
        case .requestReceived: .request
        case .requestSent, .none: .code
        }
    }

    /// The "…" at a row's end, holding the same actions as its long press.
    private func moreMenu<Items: View>(_ name: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(HUDTheme.secondaryText)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(name)")
    }

    // MARK: Requests

    private func requestRow(_ person: SocialSnapshot.Person) -> some View {
        PersonRow(userID: person.userID, path: person.avatarURL, name: person.displayName, detail: "Wants to be friends") {
            HStack(spacing: 8) {
                IconButton(
                    systemImage: "xmark", label: "Decline friend request from \(person.displayName)",
                    tint: HUDTheme.secondaryText
                ) {
                    respond(to: person, accept: false)
                }
                IconButton(
                    systemImage: "checkmark", label: "Accept friend request from \(person.displayName)",
                    tint: HUDTheme.accent
                ) {
                    respond(to: person, accept: true)
                }
            }
        }
        .contextMenu {
            Button { respond(to: person, accept: true) } label: { Label("Accept", systemImage: "checkmark.circle") }
            Button(role: .destructive) { respond(to: person, accept: false) } label: {
                Label("Decline", systemImage: "xmark.circle")
            }
            blockAndReport(person.userID, person.displayName, person.avatarURL, context: .request)
        }
    }

    /// A pending request always has a friendship id; a block row never reaches here.
    private func respond(to person: SocialSnapshot.Person, accept: Bool) {
        guard let friendshipID = person.friendshipID else { return }
        model.respondToFriendRequest(friendshipID, accept: accept)
    }

    // MARK: Friends

    private func friendRow(_ friend: SocialSnapshot.Person) -> some View {
        Button { model.pushPanel(.friendCard(friend.userID)) } label: {
            // Its own clock, so "now" and the ring go once the position ages.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let live = isLive(friend.userID, at: context.date)
                PersonRow(
                    userID: friend.userID, path: friend.avatarURL, name: friend.displayName,
                    detail: Wording.friendDetail(
                        live: live, place: model.resort?.places[friend.userID],
                        resortName: model.selectedResort?.name, ability: friend.ability),
                    ring: live ? HUDTheme.accentGreen : nil
                ) {
                    moreMenu(friend.displayName) { friendActions(friend) }
                    GlassChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { friendActions(friend) }
        .accessibilityHint("Opens their card")
        // The button merges the row, "…" menu included, into one element.
        .accessibilityActions { friendActions(friend) }
    }

    /// The friend's position at the open resort is live.
    private func isLive(_ id: UUID, at now: Date) -> Bool {
        model.resort?.friends[id].map { FriendSignal.classify(lastSeen: $0.capturedAt, now: now) == .live } ?? false
    }

    @ViewBuilder
    private func friendActions(_ friend: SocialSnapshot.Person) -> some View {
        Button(role: .destructive) {
            friendToRemove = PersonTarget(id: friend.userID, displayName: friend.displayName)
        } label: {
            Label("Remove friend", systemImage: "person.fill.xmark")
        }
        blockAndReport(friend.userID, friend.displayName, friend.avatarURL, context: .friend)
    }

    @ViewBuilder
    private func blockAndReport(_ id: UUID, _ name: String, _ avatar: String?, context: ReportContext) -> some View {
        Button(role: .destructive) { userToBlock = PersonTarget(id: id, displayName: name) } label: {
            Label("Block", systemImage: "hand.raised.fill")
        }
        Button(role: .destructive) {
            model.pushPanel(.report(ReportTarget(userID: id, displayName: name, avatarURL: avatar, context: context)))
        } label: {
            Label("Report", systemImage: "exclamationmark.bubble")
        }
    }

    // MARK: Sent

    private func sentRow(_ person: SocialSnapshot.Person) -> some View {
        PersonRow(userID: person.userID, path: person.avatarURL, name: person.displayName, detail: "Request sent") {
            SecondaryButton(title: "Cancel", fillsWidth: false) {
                requestToWithdraw = PersonTarget(id: person.userID, displayName: person.displayName)
            }
            .accessibilityLabel("Cancel friend request to \(person.displayName)")
        }
        .contextMenu {
            blockAndReport(person.userID, person.displayName, person.avatarURL, context: .code)
        }
    }

    // MARK: Contacts

    /// Runs once when the user asks, then quietly once a day (`onAppear`).
    @ViewBuilder
    private var contactsRow: some View {
        let discovery = model.discovery
        if discovery.access == .denied {
            GlassNavRow(
                icon: "person.crop.circle.badge.exclamationmark", title: "Turn On Contacts in Settings",
                detail: "To find friends by their email addresses"
            ) {
                if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
            }
        } else {
            Button { model.findFriendsFromContacts() } label: {
                GlassRow(
                    icon: "person.crop.circle.badge.plus",
                    title: discovery.hasSearched ? "Check Contacts Again" : "Find Friends in Contacts",
                    detail: discovery.failure?.userMessage
                        ?? (discovery.wasCutShort ? "Only part of your contacts was checked" : nil)
                        ?? (discovery.hasSearched && !discovery.isSearching && discovery.matches.isEmpty
                            ? "No one in your contacts is on PowderMeet yet" : nil)
                        ?? (discovery.hasSearched ? nil : "Only hashed email addresses are sent; names and numbers stay on your phone")
                ) {
                    if discovery.isSearching { ProgressView().controlSize(.small) } else { GlassChevron() }
                }
            }
            .buttonStyle(.plain)
            .disabled(discovery.isSearching)
        }
    }

    /// Matches minus anyone already a friend, in a request, blocked or hidden,
    /// so one person never shows in two sections.
    private var suggestions: [UserMatch] {
        let known = Set((social.friends + social.pendingIn + social.pendingOut + social.blocks).map(\.userID))
        return model.discovery.matches.filter { !known.contains($0.id) && !hiddenSuggestions.contains($0.id) }
    }

    private func suggestionRow(_ match: UserMatch) -> some View {
        PersonRow(userID: match.id, path: match.avatarURL, name: match.displayName, detail: "In Your Contacts") {
            HStack(spacing: 8) {
                IconButton(systemImage: "xmark", label: "Hide \(match.displayName) for now", tint: HUDTheme.secondaryText) {
                    hide(match.id)
                }
                IconButton(systemImage: "person.badge.plus", label: "Send friend request to \(match.displayName)",
                           tint: HUDTheme.accent) {
                    model.requestFriend(match.id)
                }
            }
        }
        .contextMenu {
            Button { model.requestFriend(match.id) } label: { Label("Add Friend", systemImage: "person.badge.plus") }
            Button { hide(match.id) } label: { Label("Hide for Now", systemImage: "eye.slash") }
            blockAndReport(match.id, match.displayName, match.avatarURL, context: .contact)
        }
    }

    private func hide(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) { _ = hiddenSuggestions.insert(id) }
    }
}

/// Remove, withdraw and block each ask first.
private struct FriendAlerts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var friendToRemove: PersonTarget?
    @Binding var userToBlock: PersonTarget?
    @Binding var requestToWithdraw: PersonTarget?

    func body(content: Content) -> some View {
        content
            .confirmCard(
                item: $requestToWithdraw, title: { _ in "Withdraw request?" },
                message: { "Cancel your friend request to \($0.displayName)?" },
                confirm: "Withdraw", cancel: "Keep"
            ) { target in
                // `friend_remove` deletes the pending row as it does an accepted one.
                model.removeFriend(target.id)
            }
            .confirmCard(
                item: $friendToRemove, title: { _ in "Remove friend?" },
                message: { "\($0.displayName) will be removed from your friends. You can add them back later." },
                confirm: "Remove"
            ) { model.removeFriend($0.id) }
            .confirmCard(
                item: $userToBlock, title: { _ in "Block this person?" },
                message: { "\($0.displayName) won't see your activity and you won't see theirs. You can unblock them under Blocked." },
                confirm: "Block"
            ) { model.block($0.id) }
    }
}

/// A person in a list: their photo, name and one line, then the row's actions.
struct PersonRow<Trailing: View>: View {
    let userID: UUID
    let path: String?
    let name: String
    var detail: String?
    var ring: Color?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(userID: userID, path: path, name: name, size: 38)
                .overlay {
                    if let ring { Circle().strokeBorder(ring, lineWidth: 2) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .textRole(.body)
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, GlassLayout.cardPadding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: GlassLayout.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Whoever an alert is about: a friend, a request, a contact match or someone
/// found by name.
private nonisolated struct PersonTarget: Hashable {
    let id: UUID
    let displayName: String
}
