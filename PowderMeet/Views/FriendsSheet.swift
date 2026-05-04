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

    @State private var searchQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var sentIds: Set<UUID> = []
    @State private var pendingProfiles: [UUID: UserProfile] = [:]
    @State private var friendToRemove: UserProfile?
    @State private var requestToCancel: UserProfile?

    var body: some View {
        VStack(spacing: 0) {
            // ── Search Bar ──
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))

                TextField("", text: $searchQuery, prompt: Text("SEARCH BY NAME")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                )
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
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

            // ── Content ──
            LazyVStack(spacing: 0) {
                if !searchQuery.isEmpty {
                    if friendService.searchResults.isEmpty {
                        Text("NO USERS FOUND")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                    contactSuggestionsSection

                    if !friendService.pendingReceived.isEmpty {
                        sectionHeader("PENDING")
                            .padding(.top, 16)
                        ForEach(friendService.pendingReceived) { request in
                            pendingRequestCard(request)
                                .padding(.top, 8)
                        }
                    }

                    if !friendService.friends.isEmpty {
                        sectionHeader("YOUR FRIENDS · \(friendService.friends.count)")
                            .padding(.top, 16)
                        ForEach(friendService.friends) { friend in
                            friendRow(friend)
                                .padding(.top, 8)
                        }
                    } else if friendService.pendingReceived.isEmpty
                                && friendService.contactSuggestions.isEmpty {
                        Text("ADD SKIERS YOU MEET UP WITH")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                            .tracking(1)
                            .padding(.top, 24)
                    }
                }
            }
            .padding(.top, 12)
        }
        .alert("REMOVE FRIEND?", isPresented: Binding(
            get: { friendToRemove != nil },
            set: { if !$0 { friendToRemove = nil } }
        )) {
            Button("CANCEL", role: .cancel) { friendToRemove = nil }
            Button("REMOVE", role: .destructive) {
                guard let friend = friendToRemove else { return }
                friendToRemove = nil
                Task { try? await friendService.removeFriend(friend.id) }
            }
        } message: {
            Text("Remove \(friendToRemove?.displayName ?? "this friend")? You can add them back later.")
        }
        .alert("CANCEL REQUEST?", isPresented: Binding(
            get: { requestToCancel != nil },
            set: { if !$0 { requestToCancel = nil } }
        )) {
            Button("KEEP", role: .cancel) { requestToCancel = nil }
            Button("WITHDRAW", role: .destructive) {
                guard let user = requestToCancel else { return }
                requestToCancel = nil
                Task { try? await friendService.cancelSentRequest(to: user.id) }
            }
        } message: {
            Text("Cancel your request to \(requestToCancel?.displayName ?? "this user")?")
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

    // MARK: - Section Header

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                .tracking(2)
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
        }
    }

    // MARK: - Contact Suggestions

    @ViewBuilder
    private var contactSuggestionsSection: some View {
        let contactsStatus = ContactsService.shared.status

        if contactsStatus != .denied && contactsStatus != .restricted {
            // Always show a tap target so the user can re-run the
            // contact match whenever they want — we don't store the
            // raw contacts, so each tap re-asks the OS for the latest
            // emails/phones, hashes, and queries the server fresh.
            let hasSuggestions = !friendService.contactSuggestions.isEmpty
            let label = hasSuggestions ? "RESCAN CONTACTS" : "FIND FRIENDS FROM CONTACTS"
            let subtitle = hasSuggestions
                ? "WE DON'T STORE CONTACTS — RESCANS EACH TIME"
                : "SEE WHO'S ALREADY ON POWDERMEET · NEVER STORED"

            Button {
                Task { await friendService.loadContactSuggestions() }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(HUDTheme.accentAmber.opacity(0.12))
                            .frame(width: 36, height: 36)
                        if friendService.isLoadingContactSuggestions {
                            ProgressView()
                                .tint(HUDTheme.accentAmber)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: hasSuggestions
                                  ? "arrow.triangle.2.circlepath"
                                  : "person.crop.rectangle.stack.fill")
                                .font(.system(size: 16))
                                .foregroundColor(HUDTheme.accentAmber)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(friendService.isLoadingContactSuggestions ? "SCANNING…" : label)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(0.5)
                        Text(subtitle)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(0.3)
                    }
                    Spacer()
                    if !friendService.isLoadingContactSuggestions {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(HUDTheme.accentAmber.opacity(0.6))
                    }
                }
                .padding(12)
                .background(HUDTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(HUDTheme.accentAmber.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(friendService.isLoadingContactSuggestions)
            .padding(.top, 4)

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
                    sectionHeader("SUGGESTED")
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
                Text(profile.skillLevel.uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
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
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.accentAmber.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Pending Request Card

    private func pendingRequestCard(_ request: Friendship) -> some View {
        let requestProfile = pendingProfiles[request.requesterId]

        return HStack(spacing: 12) {
            avatarView(requestProfile, size: 32)

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
    }

    // MARK: - Friend Row

    private func friendRow(_ friend: UserProfile) -> some View {
        HStack(spacing: 12) {
            avatarView(friend, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(friend.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(friend.skillLevel.uppercased())
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.accent.opacity(0.7))
                        .tracking(0.5)
                }
            }

            Spacer()

            Button {
                friendToRemove = friend
            } label: {
                Image(systemName: "person.fill.xmark")
                    .font(.system(size: 12))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove friend \(friend.displayName)")
        }
        .padding(12)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Search Result Row

    private func searchResultRow(_ user: UserProfile) -> some View {
        let status = friendService.relationshipStatus(with: user.id)
        let justSent = sentIds.contains(user.id)

        return HStack(spacing: 12) {
            avatarView(user, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
            }

            Spacer()

            switch status {
            case .friends:
                Text("FRIENDS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HUDTheme.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

            case .none:
                if justSent {
                    Text("SENT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(HUDTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Avatar Helper

    @ViewBuilder
    private func avatarView(_ profile: UserProfile?, size: CGFloat) -> some View {
        if let urlString = profile?.avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: avatarPlaceholder(size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .id(urlString)
        } else {
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
