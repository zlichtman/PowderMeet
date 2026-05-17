//
//  FriendsSheet.swift
//  PowderMeet
//
//  Inline friends content used by the Profile page's FRIENDS tab:
//  search, contact suggestions, pending requests, friends with unfriend.
//

import SwiftUI
import Contacts

struct FriendsListContent: View {
    @Environment(FriendService.self) private var friendService
    @Environment(SupabaseManager.self) private var supabase

    /// Optional set of friend IDs currently broadcasting presence.
    /// When provided, accepted-friend rows render an accent ring on
    /// the avatar. Caller passes this in from the realtime location
    /// service (the friend tab in Profile does; standalone sheets
    /// don't bother). Empty set = no ring on anyone.
    let friendsPresent: Set<UUID>

    init(friendsPresent: Set<UUID> = []) {
        self.friendsPresent = friendsPresent
    }

    @State private var searchQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var sentIds: Set<UUID> = []
    @State private var pendingProfiles: [UUID: UserProfile] = [:]
    @State private var friendToRemove: UserProfile?
    @State private var requestToCancel: UserProfile?
    @State private var userToBlock: UserProfile?

    var body: some View {
        VStack(spacing: 0) {
            // Section header makes the search bar's purpose obvious —
            // without it new users don't realize search is the path to
            // add a friend.
            HUDSectionHeader(label: "POWDER MEETERS")
                .padding(.bottom, 10)

            // ── Search Bar + Contact Rescan ──
            // The search field flexes (.frame(maxWidth: .infinity))
            // and the rescan button is a fixed 40pt square, so the
            // search bar shrinks by EXACTLY 40 + 8pt spacing — a
            // layout-driven "perfect fit", no magic numbers. The
            // rescan affordance moved here from a big amber card so
            // the contact section is just results.
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.5))

                    TextField("", text: $searchQuery, prompt: Text("SEARCH BY NAME")
                        .font(HUDTheme.font(.body))
                        .foregroundColor(HUDTheme.textTertiary)
                    )
                    .hudType(.body)
                    .foregroundColor(HUDTheme.primaryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(HUDTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                )
                .onChange(of: searchQuery) { _, newValue in
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await friendService.searchUsers(query: newValue)
                    }
                }

                rescanContactsButton
            }

            // ── Content bucket ──
            // Bounded scroll inside the otherwise-fixed Profile tab.
            // Header + search bar above stay pinned; only the list
            // of rows here scrolls, keeping the page itself still.
            // In the standalone FriendsSheet (sheet variant) the
            // surrounding sheet supplies the bounded surface, so the
            // same inner ScrollView works there too.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !searchQuery.isEmpty {
                        if friendService.searchResults.isEmpty {
                            Text("NO USERS FOUND")
                                .hudType(.label)
                                .foregroundColor(HUDTheme.secondaryText)
                                .tracking(1)
                                .padding(.top, 40)
                        } else {
                            ForEach(friendService.searchResults) { user in
                                searchResultRow(user)
                                    .padding(.top, 8)
                            }
                        }
                    } else {
                        // Sent + blocked folders moved to Profile → Account →
                        // FRIENDS section. The friends sheet stays focused on
                        // active relationships and inbound requests.
                        contactSuggestionsSection
                            .padding(.top, 4)

                        // ── Inbound requests ("WANTS TO CONNECT") ──
                        // Highest-priority section: someone asked, the
                        // user owes a yes/no. Stays inline (vs the
                        // sent-requests folder) because acting on these
                        // is the only first-class action surface for
                        // friends-tab visits — burying them in a sub-sheet
                        // hides the primary "yes/no" decision.
                        if !friendService.pendingReceived.isEmpty {
                            HUDSectionHeader(label: "WANTS TO CONNECT", accent: HUDTheme.accentAmber, accentDot: true)
                                .padding(.top, 16)
                            ForEach(friendService.pendingReceived) { request in
                                pendingRequestCard(request)
                                    .padding(.top, 8)
                            }
                        }

                        if !friendService.friends.isEmpty {
                            HUDSectionHeader(label: "YOUR FRIENDS · \(friendService.friends.count)", accent: HUDTheme.accent, accentDot: true)
                                .padding(.top, 16)
                            ForEach(friendService.friends) { friend in
                                friendRow(friend)
                                    .padding(.top, 8)
                            }
                        } else if friendService.pendingReceived.isEmpty
                                    && friendService.pendingSent.isEmpty
                                    && friendService.contactSuggestions.isEmpty {
                            Text("ADD SKIERS YOU MEET UP WITH")
                                .hudType(.label)
                                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                                .tracking(1)
                                .padding(.top, 24)
                        }
                    }
                }
                .padding(.top, 12)
            }
            .frame(maxHeight: .infinity)
            .scrollIndicators(.visible)
        }
        // Search sits at the top; the list scrolls itself. Don't let
        // the keyboard heave the whole sheet upward on focus.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .alert("Remove friend?", isPresented: Binding(
            get: { friendToRemove != nil },
            set: { if !$0 { friendToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { friendToRemove = nil }
            Button("Remove", role: .destructive) {
                guard let friend = friendToRemove else { return }
                friendToRemove = nil
                Task { try? await friendService.removeFriend(friend.id) }
            }
        } message: {
            Text("\(friendToRemove?.displayName ?? "This friend") will be removed from your friends list. You can add them back later.")
        }
        .alert("Withdraw request?", isPresented: Binding(
            get: { requestToCancel != nil },
            set: { if !$0 { requestToCancel = nil } }
        )) {
            Button("Keep", role: .cancel) { requestToCancel = nil }
            Button("Withdraw", role: .destructive) {
                guard let user = requestToCancel else { return }
                requestToCancel = nil
                Task { try? await friendService.cancelSentRequest(to: user.id) }
            }
        } message: {
            Text("Cancel your friend request to \(requestToCancel?.displayName ?? "this user")?")
        }
        .alert("Block this user?", isPresented: Binding(
            get: { userToBlock != nil },
            set: { if !$0 { userToBlock = nil } }
        )) {
            Button("Cancel", role: .cancel) { userToBlock = nil }
            Button("Block", role: .destructive) {
                guard let user = userToBlock else { return }
                userToBlock = nil
                Task { await friendService.block(user.id) }
            }
        } message: {
            Text("\(userToBlock?.displayName ?? "This user") won't see your activity and you won't see theirs. You can manage blocks from Profile → Account → Friends.")
        }
        .task {
            await loadPendingProfiles()
            if ContactsService.shared.status == .authorized {
                await friendService.loadContactSuggestions()
            }
        }
        .onChange(of: friendService.pendingReceived.count) { _, _ in
            Task { await loadPendingProfiles() }
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    // MARK: - Contact Rescan

    /// Compact square button paired with the search bar. Same input
    /// chrome (inputBackground / cardBorder / radius 8 / 40pt) so the
    /// two read as one control row — NOT a loud yellow logo button.
    /// Hidden when contacts are denied/restricted, which lets the
    /// search field reclaim the full width automatically.
    @ViewBuilder
    private var rescanContactsButton: some View {
        let status = ContactsService.shared.status
        if status != .denied && status != .restricted {
            Button {
                guard !friendService.isLoadingContactSuggestions else { return }
                Task { await friendService.loadContactSuggestions() }
                // Surface the privacy reassurance as a standard iOS
                // notification (lock-screen / banner / notification
                // center) instead of an in-app toast.
                Notify.shared.post(.contactsRescanned)
            } label: {
                ZStack {
                    if friendService.isLoadingContactSuggestions {
                        ProgressView()
                            .tint(HUDTheme.accentAmber)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(HUDTheme.accentAmber)
                    }
                }
                .frame(width: 40, height: 40)
                .background(HUDTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HUDTheme.accentAmber.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(friendService.isLoadingContactSuggestions)
            .accessibilityLabel("Rescan contacts for friends")
        }
    }

    // MARK: - Contact Suggestions

    @ViewBuilder
    private var contactSuggestionsSection: some View {
        let contactsStatus = ContactsService.shared.status

        if contactsStatus != .denied && contactsStatus != .restricted {
            // The rescan trigger lives next to the search bar now
            // (`rescanContactsButton`). This section is purely the
            // results — we never store the raw contacts; each rescan
            // re-asks the OS and queries the server fresh.
            if !friendService.isLoadingContactSuggestions {
                // Filter out anyone already a friend or with a pending request.
                // `loadContactSuggestions` filters against the friends list at
                // the moment it runs, but on cold launch it often completes
                // before `loadFriends`, and the accept flow doesn't re-filter
                // suggestions. Without this guard the same UUID can appear in
                // both the SUGGESTED and YOUR FRIENDS sections of this
                // LazyVStack — SwiftUI logs "ID … used by multiple child views".
                let friendIds = Set(friendService.friends.map(\.id))
                let pendingIds = Set(
                    friendService.pendingReceived.map(\.requesterId)
                    + friendService.pendingSent.map(\.addresseeId)
                )
                let suggestions = friendService.contactSuggestions.filter {
                    !friendIds.contains($0.id) && !pendingIds.contains($0.id)
                }
                if !suggestions.isEmpty {
                    HUDSectionHeader(label: "SUGGESTED")
                        .padding(.top, 4)
                    ForEach(suggestions) { suggestion in
                        contactSuggestionRow(suggestion)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func contactSuggestionRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            avatarView(profile, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName.uppercased())
                    .hudType(.label)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
                Text(profile.skillLevel.uppercased())
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accentAmber.opacity(0.7))
                    .tracking(0.5)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    friendService.dismissSuggestion(profile.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    try? await friendService.sendRequest(to: profile.id)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        friendService.dismissSuggestion(profile.id)
                    }
                }
            } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(HUDTheme.accentAmber)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(HUDTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            // Dashed amber border distinguishes contact suggestions
            // from accepted friends at a glance — "this isn't your
            // friend yet, just someone matched from contacts."
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    HUDTheme.accentAmber.opacity(0.35),
                    style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
                )
        )
        .contextMenu {
            Button {
                Task {
                    try? await friendService.sendRequest(to: profile.id)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        friendService.dismissSuggestion(profile.id)
                    }
                }
            } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    friendService.dismissSuggestion(profile.id)
                }
            } label: {
                Label("Hide Suggestion", systemImage: "eye.slash")
            }
            Button(role: .destructive) {
                userToBlock = profile
            } label: {
                Label("Block", systemImage: "hand.raised.fill")
            }
        }
    }

    // MARK: - Pending Request Card

    private func pendingRequestCard(_ request: Friendship) -> some View {
        let requestProfile = pendingProfiles[request.requesterId]

        return HStack(spacing: 12) {
            avatarView(requestProfile, size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text((requestProfile?.displayName ?? "UNKNOWN").uppercased())
                    .hudType(.label)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
                Text("WANTS TO CONNECT")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    Task { try? await friendService.acceptRequest(request.id) }
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
                    Task { try? await friendService.declineRequest(request.id) }
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
        .contextMenu {
            Button {
                Task { try? await friendService.acceptRequest(request.id) }
            } label: {
                Label("Accept", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                Task { try? await friendService.declineRequest(request.id) }
            } label: {
                Label("Decline", systemImage: "xmark.circle")
            }
            Button(role: .destructive) {
                userToBlock = requestProfile ?? UserProfile.defaultProfile(id: request.requesterId)
            } label: {
                Label("Block", systemImage: "hand.raised.fill")
            }
        }
    }

    // MARK: - Friend Row

    /// Row construction defers to `FriendListRowView`, an `Equatable`
    /// View that only re-renders when render-relevant fields actually
    /// changed. Without this, a `loadSocialSnapshot` that returns the
    /// same friend with a fresh server-side `updatedAt` flips the
    /// snapshot diff to "different" and re-runs every row's body —
    /// the avatar/ski combo glitches as `CachedAvatarView` / topsheet
    /// load paths re-execute against unchanged inputs. `.equatable()`
    /// SHORT-CIRCUITS those re-runs at the framework level.
    private func friendRow(_ friend: UserProfile) -> some View {
        FriendListRowView(
            friendId: friend.id,
            displayName: friend.displayName,
            skillLevel: friend.skillLevel,
            avatarUrl: friend.avatarUrl,
            preferredSkiId: friend.preferredSkiId,
            skiEntry: supabase.skiCatalogEntry(forSkiId: friend.preferredSkiId),
            isOnline: friendsPresent.contains(friend.id),
            onUnfriend: { friendToRemove = friend },
            onBlock: { userToBlock = friend }
        )
        .equatable()
    }

    // MARK: - Search Result Row

    private func searchResultRow(_ user: UserProfile) -> some View {
        let status = friendService.relationshipStatus(with: user.id)
        let justSent = sentIds.contains(user.id)

        return HStack(spacing: 12) {
            avatarView(user, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName.uppercased())
                    .hudType(.section)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
            }

            Spacer()

            switch status {
            case .friends:
                Text("FRIENDS")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HUDTheme.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

            case .pendingSent:
                Button {
                    requestToCancel = user
                } label: {
                    Text("PENDING")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.accentAmber)
                        .tracking(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HUDTheme.accentAmber.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

            case .pendingReceived:
                Text("RESPOND")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HUDTheme.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

            case .none:
                if justSent {
                    Text("SENT")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HUDTheme.accent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Button {
                        Task {
                            try? await friendService.sendRequest(to: user.id)
                            sentIds.insert(user.id)
                        }
                    } label: {
                        Text("ADD")
                            .hudType(.label)
                            .foregroundColor(.white)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(HUDTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }

            case .blocked:
                // Blocked rows shouldn't normally appear here (the
                // service filters them out of search results), but
                // render a neutral marker for the edge case where a
                // row arrives through a path that bypasses the filter.
                Text("BLOCKED")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HUDTheme.secondaryText.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(10)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
        .contextMenu {
            // Block is the universal action across every search row;
            // friend / pending / suggestion-specific actions are
            // already exposed via the visible chip + button on the row
            // itself, so the menu is intentionally minimal here.
            Button(role: .destructive) {
                userToBlock = user
            } label: {
                Label("Block", systemImage: "hand.raised.fill")
            }
        }
    }

    // MARK: - Avatar Helper

    @ViewBuilder
    private func avatarView(_ profile: UserProfile?, size: CGFloat) -> some View {
        // Process-wide UIImage cache survives LazyVStack row remounts
        // during scroll, eliminating the placeholder-flash that AsyncImage
        // otherwise inflicts on every reappearance.
        CachedAvatarView(urlString: profile?.avatarUrl, size: size) {
            avatarPlaceholder(size: size)
        }
    }

    private func avatarPlaceholder(size: CGFloat) -> some View {
        Circle()
            .fill(HUDTheme.inputBackground)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
            )
    }

    // MARK: - Pending Profile Loading

    private func loadPendingProfiles() async {
        for request in friendService.pendingReceived {
            if pendingProfiles[request.requesterId] == nil {
                if let profile = await friendService.loadProfile(id: request.requesterId) {
                    pendingProfiles[request.requesterId] = profile
                }
            }
        }
    }
}
