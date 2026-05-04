//
//  ProfileView.swift
//  PowderMeet
//
//  Profile page: horizontal hero (avatar + name LEFT, 2x2 stats RIGHT),
//  live status (resort + node, double-tap opens hidden dev location picker),
//  and three inline tabs — FRIENDS, ACTIVITY, ACCOUNT.
//

import SwiftUI
import PhotosUI
import Supabase

private enum ProfileTab: String, CaseIterable, Identifiable {
    case friends = "FRIENDS"
    case activity = "ACTIVITY"
    case account = "ACCOUNT"
    var id: String { rawValue }
}

struct ProfileView: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(FriendService.self) private var friendService
    @Environment(ResortDataManager.self) private var resortManager
    @Environment(LocationManager.self) private var locationManager

    @Binding var testMyNodeId: String?

    // Hero edit
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var nameConflictMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: Image?

    // Inline tab + dev sheet
    @State private var selectedTab: ProfileTab = .friends
    @State private var showLocationPicker = false

    // Inflight
    @State private var isUploadingAvatar = false
    @State private var errorMessage: String?

    private var profile: UserProfile? { supabase.currentUserProfile }
    private var stats: ProfileStats? { supabase.currentUserStats }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            if let profile {
                ScrollView {
                    VStack(spacing: 18) {
                        hero(profile)
                            .padding(.top, 12)
                            .padding(.horizontal, 20)

                        liveStatusCard
                            .padding(.horizontal, 20)

                        tabSelector
                            .padding(.horizontal, 20)

                        tabBody
                            .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(HUDTheme.spinnerInteractive)
                    Text("LOADING PROFILE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: profile?.avatarUrl) {
            guard let urlString = profile?.avatarUrl,
                  let url = URL(string: urlString) else { return }
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                if let (data, response) = try? await URLSession.shared.data(from: url),
                   let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let uiImage = UIImage(data: data) {
                    avatarImage = Image(uiImage: uiImage)
                    return
                }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await uploadAvatar(from: newItem) }
        }
        .onChange(of: editedName) { _, _ in
            if nameConflictMessage != nil { nameConflictMessage = nil }
        }
        // RoutingTestSheet is a TestFlight-grade dev affordance, not just
        // DEBUG — the live status card's tap gate is
        // BuildEnvironment.isPreRelease, which fires on Debug builds AND
        // TestFlight betas. Compile-gating the sheet on `#if DEBUG` was
        // why TestFlight users could tap the card and see nothing happen
        // (the binding flipped but the modifier wasn't attached).
        .sheet(isPresented: $showLocationPicker) {
            RoutingTestSheet(testMyNodeId: $testMyNodeId)
        }
        .onChange(of: resortManager.currentGraph?.fingerprint) { _, _ in
            if let id = testMyNodeId, resortManager.currentGraph?.nodes[id] == nil {
                testMyNodeId = nil
            }
        }
        .alert("ERROR", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Hero (horizontal: avatar + name LEFT, 2x2 stats RIGHT)

    private func hero(_ profile: UserProfile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // ── LEFT: avatar + name + skill chip ──
            VStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack {
                        avatarView(profile)
                            .overlay(
                                Group {
                                    if isUploadingAvatar {
                                        Circle()
                                            .fill(HUDTheme.modalScrim)
                                            .overlay(ProgressView().tint(HUDTheme.spinnerForm))
                                    }
                                }
                            )
                        Circle()
                            .fill(HUDTheme.accent)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: isUploadingAvatar ? "arrow.up.circle.fill" : "camera.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                            )
                            .offset(x: 28, y: 28)
                    }
                }
                .disabled(isUploadingAvatar)

                if isEditingName {
                    editNameField
                } else {
                    Button {
                        editedName = profile.displayName
                        isEditingName = true
                    } label: {
                        Text(profile.displayName.uppercased())
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.primaryText)
                            .tracking(1.5)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 110)

            // ── RIGHT: 2x2 stats grid ──
            statsGrid
                .frame(maxWidth: .infinity)
        }
    }

    private var editNameField: some View {
        VStack(spacing: 4) {
            TextField("", text: $editedName,
                      prompt: Text("YOUR NAME").foregroundColor(HUDTheme.secondaryText.opacity(0.4)))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { commitName() }
                .padding(.horizontal, 6)
                .frame(height: 32)
                .background(HUDTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                )

            if let conflict = nameConflictMessage {
                Text(conflict)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accentRed)
                    .tracking(0.5)
            }
        }
    }

    private func commitName() {
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameConflictMessage = "Name can't be empty"
            return
        }
        Task {
            let taken = await supabase.isDisplayNameTaken(name)
            if taken {
                nameConflictMessage = "\"\(name)\" is already taken"
                return
            }
            nameConflictMessage = nil
            do {
                // setDisplayName mirrors to auth user-metadata too,
                // so the Supabase Dashboard's "Display Name" column
                // stays in sync with the profile row.
                try await supabase.setDisplayName(name)
                isEditingName = false
            } catch {
                // The pre-update `isDisplayNameTaken` check has a race
                // window: between the check and the update, another
                // device can claim the same name. The UNIQUE constraint
                // on the column then rejects this update with a Postgres
                // 23505 (unique_violation). Surface a clear conflict
                // message instead of the opaque Supabase error and keep
                // the name editor open so the user can pick something else.
                if Self.isUniqueViolation(error) {
                    nameConflictMessage = "\"\(name)\" was just taken — try another."
                    // Re-load profile so the UI reflects the server's truth
                    // (in case our local profile drifted during the race).
                    await supabase.loadProfile()
                } else {
                    errorMessage = "Couldn't save name: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Postgres 23505 unique-violation surfaces through PostgREST as a
    /// `PostgrestError` with code "23505" or a message containing
    /// "duplicate key value". We sniff both since the SDK has historically
    /// inconsistent error shapes across versions.
    private static func isUniqueViolation(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        if message.contains("duplicate key") || message.contains("unique constraint") {
            return true
        }
        // PostgrestError exposes its `code` via Mirror — avoids importing
        // PostgREST types into this file.
        for child in Mirror(reflecting: error).children {
            if let label = child.label,
               label == "code" || label == "errorCode",
               let code = child.value as? String,
               code == "23505" {
                return true
            }
        }
        return false
    }

    // MARK: - Avatar View

    private func avatarView(_ profile: UserProfile) -> some View {
        Group {
            if let avatarImage {
                avatarImage
                    .resizable().scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(HUDTheme.accent.opacity(0.5), lineWidth: 2))
            } else if profile.avatarUrl != nil {
                Circle()
                    .fill(HUDTheme.cardBackground)
                    .frame(width: 80, height: 80)
                    .overlay(ProgressView().tint(HUDTheme.spinnerInteractive))
                    .overlay(Circle().stroke(HUDTheme.accent.opacity(0.3), lineWidth: 2))
            } else {
                Circle()
                    .fill(HUDTheme.cardBackground)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 32))
                            .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                    )
                    .overlay(Circle().stroke(HUDTheme.cardBorder, lineWidth: 1))
            }
        }
    }

    // MARK: - Live Status

    /// Human-readable "where on the mountain" string. Prefers an explicit dev
    /// test-node (double-tap to pick), falls back to the nearest graph node
    /// under the real GPS fix. Returns nil when we have neither.
    /// `.withChainPosition` so the HUD reads the same as the picker
    /// row the user just selected — "Frontside Run · Black · TOP" stays
    /// consistent rather than collapsing to "Frontside Run".
    private var liveLocationName: String? {
        guard let graph = resortManager.currentGraph else { return nil }
        let naming = MountainNaming(graph)
        if let nodeId = testMyNodeId, graph.nodes[nodeId] != nil {
            return naming.nodeLabel(nodeId, style: .withChainPosition)
        }
        if let sticky = locationManager.gpsStickyGraphNodeId, graph.nodes[sticky] != nil {
            return naming.nodeLabel(sticky, style: .withChainPosition)
        }
        if let coord = locationManager.currentLocation {
            return naming.locationLabel(near: coord, style: .withChainPosition)
        }
        return nil
    }

    private var liveStatusCard: some View {
        // Use `currentEntry` (the selected resort) rather than `currentResort`
        // (the raw ResortData). ResortDataManager skips populating
        // `currentResort` on the disk-cache fast path, which used to leave the
        // status card stuck on OFFLINE / NO RESORT even with a graph loaded.
        let resortName = resortManager.currentEntry?.name
        // On-mountain = at a resort with any live fix (real GPS or dev test
        // node). Previously this required a test-node, so normal users stayed
        // OFFLINE forever even while skiing.
        let hasLiveFix = testMyNodeId != nil || locationManager.currentLocation != nil
        let isOnline = resortName != nil && hasLiveFix

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isOnline ? HUDTheme.accentGreen : HUDTheme.secondaryText.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(isOnline ? "ON THE MOUNTAIN" : "OFFLINE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isOnline ? HUDTheme.accentGreen : HUDTheme.secondaryText)
                    .tracking(1.5)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text((resortName ?? "NO RESORT").uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1)
                    .lineLimit(1)
                Text((liveLocationName ?? "TAP TO SET LOCATION").uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(isOnline ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.7))
                    .tracking(0.5)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isOnline ? HUDTheme.accentGreen.opacity(0.3) : HUDTheme.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // Single tap opens the manual node picker — the card's own copy
        // says "TAP TO SET LOCATION" so anything other than a single
        // tap reads as broken. Enabled in DEBUG and TestFlight builds,
        // no-op in App Store production. We always attach the gesture
        // so layout / hit-testing is identical across configurations;
        // the action is gated at fire time.
        .onTapGesture {
            if BuildEnvironment.isPreRelease { showLocationPicker = true }
        }
    }

    // MARK: - Stats Grid (compact for hero)

    private var statsGrid: some View {
        let s = stats ?? .empty(for: profile?.id ?? UUID())

        // Column 1 stacks cumulative totals (TOTAL DISTANCE over TOTAL VERTICAL);
        // column 2 stacks speed (AVG SPEED over TOP SPEED).
        // AVG SPEED is server-aggregated as the mean of per-run averages
        // — matches Slopes' lifetime tile (see migration 20260429).
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                statCell(label: "TOTAL DISTANCE", value: UnitFormatter.distance(s.totalDistanceM))
                statCell(label: "AVG SPEED", value: Self.formatSpeed(s.avgSpeedMs))
            }
            HStack(spacing: 6) {
                statCell(label: "TOTAL VERTICAL", value: UnitFormatter.verticalDrop(s.verticalM))
                statCell(label: "TOP SPEED", value: Self.formatSpeed(s.topSpeedMs))
            }
        }
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1.2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private static func formatSpeed(_ metersPerSecond: Double) -> String {
        guard metersPerSecond > 0 else { return "—" }
        let isMetric = Locale.current.measurementSystem == .metric
        if isMetric {
            return String(format: "%.1f KPH", metersPerSecond * 3.6)
        } else {
            return String(format: "%.1f MPH", metersPerSecond * 2.23694)
        }
    }

    // MARK: - Tab Selector + Body

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(ProfileTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                        if tab == .friends {
                            Task {
                                await friendService.loadFriends()
                                await friendService.loadPending()
                            }
                        }
                    }
                } label: {
                    let isSelected = selectedTab == tab
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? HUDTheme.accent : HUDTheme.secondaryText)
                            .tracking(1.5)

                        Rectangle()
                            .fill(isSelected ? HUDTheme.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            VStack {
                Spacer()
                Rectangle().fill(HUDTheme.cardBorder).frame(height: 0.5)
            }
        )
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .friends:
            FriendsListContent()
        case .activity:
            ActivityTabContent()
        case .account:
            AccountTabContent()
        }
    }

    // MARK: - Avatar Upload

    private func uploadAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Couldn't read the selected image."
            return
        }
        guard data.count <= 50 * 1024 * 1024 else {
            errorMessage = "Image is too large (max 50MB)."
            return
        }
        guard let uiImage = UIImage(data: data) else {
            errorMessage = "Unsupported image format."
            return
        }

        let side = min(uiImage.size.width, uiImage.size.height)
        let cropRect = CGRect(
            x: (uiImage.size.width - side) / 2,
            y: (uiImage.size.height - side) / 2,
            width: side, height: side
        )
        guard let cgCropped = uiImage.cgImage?.cropping(to: cropRect) else { return }
        let cropped = UIImage(cgImage: cgCropped, scale: uiImage.scale, orientation: uiImage.imageOrientation)

        let targetSize = CGSize(width: 512, height: 512)
        let resized = UIGraphicsImageRenderer(size: targetSize).image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = resized.jpegData(compressionQuality: 0.7) else { return }

        avatarImage = Image(uiImage: resized)
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            let url = try await supabase.uploadAvatar(imageData: jpegData)
            try await supabase.updateProfile(["avatar_url": .string(url)])
        } catch {
            errorMessage = "Avatar upload failed: \(error.localizedDescription)"
        }
    }
}

#Preview { ProfileView(testMyNodeId: .constant(nil)) }
