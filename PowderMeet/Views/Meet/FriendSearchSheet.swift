//
//  FriendSearchSheet.swift
//  PowderMeet
//
//  Search users by name, view status, send friend request.
//

import SwiftUI

struct FriendSearchSheet: View {
    @Environment(FriendService.self) private var friendService

    @State private var query = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var sentIds: Set<UUID> = []
    @State private var requestToCancel: UserProfile?

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                HStack {
                    Text("FIND FRIENDS")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(2)
                    Spacer()
                    HUDDoneButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // ── Search Bar ──
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.5))

                    TextField("", text: $query, prompt: Text("SEARCH BY NAME").foregroundColor(HUDTheme.secondaryText.opacity(0.4)))
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
                .padding(.horizontal, 20)
                .onChange(of: query) { _, newValue in
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await friendService.searchUsers(query: newValue)
                    }
                }

                // ── Results ──
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if friendService.searchResults.isEmpty && !query.isEmpty {
                            VStack(spacing: 8) {
                                Text("NO USERS FOUND")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(HUDTheme.secondaryText)
                                    .tracking(1)
                            }
                            .padding(.top, 40)
                        } else {
                            ForEach(friendService.searchResults) { user in
                                searchResultRow(user)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .presentationDetents([.large, .medium])
        .task {
            // Reconcile with server so we don't show stale amber PENDING from an
            // in-flight snapshot taken before `friends` finished hydrating.
            async let f: () = friendService.loadFriends()
            async let p: () = friendService.loadPending()
            _ = await (f, p)
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
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
    }

    // MARK: - Search Result Row

    private func searchResultRow(_ user: UserProfile) -> some View {
        let status = friendService.relationshipStatus(with: user.id)
        let justSent = sentIds.contains(user.id)

        return HStack(spacing: 12) {
            // Avatar
            if let urlString = user.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        searchAvatarPlaceholder
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            } else {
                searchAvatarPlaceholder
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.5)
                    .lineLimit(1)
            }

            Spacer()

            // Action button
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

    private var searchAvatarPlaceholder: some View {
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
