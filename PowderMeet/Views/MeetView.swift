//
//  MeetView.swift
//  PowderMeet
//
//  Social + routing tab. The body is a thin compositor over the
//  per-section subviews in `Views/Meet/`; this file owns the
//  cross-section state (selected friend, solver result, request-sent
//  flag) and the heavy logic (debounced re-solve, send-meet-request,
//  friend-position helpers).
//

import SwiftUI
import CoreLocation

struct MeetView: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(FriendService.self) private var friendService
    @Environment(ResortDataManager.self) private var resortManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(MeetRequestService.self) private var meetRequestService

    @Binding var meetingResult: MeetingResult?
    var friendLocations: [UUID: RealtimeLocationService.FriendLocation]
    var friendsPresent: Set<UUID> = []
    var resortConditions: ResortConditions?
    var activeMeetSession: ActiveMeetSession?
    var onSwitchToMap: (() -> Void)?
    var onMeetAccepted: ((MeetRequest) -> Void)?
    var onEndMeetup: (() -> Void)?

    // ── Test location support ──
    @Binding var testMyNodeId: String?

    /// Cross-section coordination state (selected friend, solver result,
    /// request-sent flag, etc.) — see `Views/Meet/MeetFlow.swift`. Kept
    /// as a single `@Observable` instance so the heavy logic methods
    /// mutate one object instead of fanning out across @State bindings.
    @State private var flow = MeetFlow()

    @State private var liveDrawerExpanded = true     // drawer starts open so FRIENDS HERE is visible
    @State private var meetTab: MeetTab = .navigation

    private enum MeetTab: String, CaseIterable, Identifiable {
        case navigation = "NAVIGATION"
        case requests   = "REQUESTS"
        var id: String { rawValue }
    }

    /// Coalesces rapid re-solve triggers from *user-driven* taps on
    /// the test-location picker: the user can mash through it faster
    /// than Dijkstra runs, so we collapse to the last pick. NOT used
    /// for friend taps (handled by `MeetPrefetcher` + the gen-guarded
    /// detached solve, which makes the foreground call effectively
    /// instant on a primed cache and self-cancelling on a stale gen),
    /// remote friend broadcasts, or accepted GPS fixes — those are
    /// already throttled upstream (broadcaster: 120ms moving / 850ms
    /// idle; locationManager: 11 m `lastSolvedMyKey` gate).
    @State private var solveDebouncer = Debouncer(milliseconds: 100)

    /// Background prefetcher for visible-friend meet routes.
    /// Pre-warms the static solver cache as friend locations update,
    /// so a tap finds the result already cached and renders ~instantly.
    /// Cancelled at the top of `handleFriendTap` so the foreground
    /// solve has CPU to itself if the prefetch happens to be running.
    @State private var prefetcher = MeetPrefetcher()

    private var selectedFriend: UserProfile? {
        guard let id = flow.selectedFriendId else { return nil }
        return friendService.friends.first { $0.id == id }
    }

    /// Coarse fingerprint of the selected friend's position (~11 m
    /// buckets from the 4-decimal rounding). Drives `.onChange` so the
    /// solver re-runs when the friend actually moves — not on every
    /// sub-meter GPS jitter, which would thrash the solver despite the
    /// static cache. `nil` means the friend has no known location; a
    /// change from nil→value covers the "first broadcast arrived after
    /// the tap" case.
    private var selectedFriendLocationKey: String? {
        guard let id = flow.selectedFriendId, let loc = friendLocations[id] else { return nil }
        let lat = (loc.latitude * 10_000).rounded() / 10_000
        let lon = (loc.longitude * 10_000).rounded() / 10_000
        // Include nearestNodeId so a node reassignment (e.g. they crested
        // onto a new lift) re-solves even if the coarse lat/lon bucket
        // is unchanged.
        return "\(lat),\(lon),\(loc.nearestNodeId ?? "-")"
    }

    /// Coarse fingerprint of every friend's position, for the prefetch
    /// watcher. Same 11 m bucketing per friend as
    /// `selectedFriendLocationKey`; concatenated so any friend's
    /// movement bumps the key. The prefetcher's per-friend 5 s
    /// throttle bounds aggregate prefetches even when many friends
    /// are moving at once.
    private var allFriendsLocationKey: String {
        friendLocations
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { (id, loc) in
                let lat = (loc.latitude * 10_000).rounded() / 10_000
                let lon = (loc.longitude * 10_000).rounded() / 10_000
                return "\(id.uuidString):\(lat),\(lon),\(loc.nearestNodeId ?? "-")"
            }
            .joined(separator: "|")
    }

    /// Helper used by the prefetch hooks. Iterates the friend roster,
    /// schedules a background solve for each — the per-friend 5 s
    /// throttle on `MeetPrefetcher` ensures a cold start with N
    /// friends produces at most N solves, not N per location update.
    private func prefetchVisibleFriends() {
        let active = activeMeetSession != nil
        for friend in friendService.friends {
            // Only prefetch for friends with a known location at our
            // resort — `makeSolverInputs` would short-circuit otherwise
            // and burn one of the prefetcher's throttle slots for nothing.
            guard friendLocations[friend.id] != nil else { continue }
            Task {
                guard let inputs = await makeSolverInputs(for: friend, setUserVisibleErrors: false) else { return }
                prefetcher.prefetch(for: friend, inputs: inputs, hasActiveMeetup: active)
            }
        }
    }

    var body: some View {
        // `@Bindable` opt-in for `$flow.currentCardPage` below — required
        // for binding into a SwiftUI subview from an `@Observable` class.
        @Bindable var flow = flow

        return ZStack(alignment: .top) {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer().frame(height: 12)
                        contentSections
                        Spacer().frame(height: 20)
                    }
                }
                .scrollIndicators(.hidden)

                // ── Friends drawer + POWDERMEET button — pinned at the
                //    bottom so the drawer always sits directly above the
                //    action button. Drawer is the friend picker for the
                //    meet flow; collapsing it gets it out of the way
                //    when not needed. Hidden during active meetup
                //    (the active card replaces both). ──
                if activeMeetSession == nil {
                    VStack(spacing: 8) {
                        LiveFriendsDrawer(
                            rows: liveDrawerRows,
                            onTap: handleFriendTap,
                            isExpanded: $liveDrawerExpanded
                        )
                        .padding(.horizontal, 20)

                        PowderMeetActionButton(
                            hasFriend: flow.selectedFriendId != nil,
                            hasResult: flow.fullMeetingResult != nil,
                            hasSelection: flow.selectedOptionIndex != nil,
                            isSolving: flow.isSolving,
                            requestSent: flow.requestSent,
                            action: sendMeetRequest
                        )
                        .padding(.horizontal, 20)

                        if let err = flow.sendError {
                            // Inline error under the action button. Tap to
                            // retry — clears the error and re-fires send.
                            Button {
                                flow.sendError = nil
                                sendMeetRequest()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 11))
                                    Text(err.uppercased())
                                        .hudType(.label)
                                        .tracking(0.8)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .foregroundColor(HUDTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(HUDTheme.accent.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(HUDTheme.accent.opacity(0.45), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .background(HUDTheme.mapBackground)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            async let friendsSync: () = friendService.loadFriends()
            async let pendingSync: () = friendService.loadPending()
            async let profiles: () = loadPendingProfiles()
            async let incoming: () = meetRequestService.loadIncoming()
            async let sent: () = meetRequestService.loadSent()
            _ = await (friendsSync, pendingSync, profiles, incoming, sent)
        }
        .onChange(of: friendService.pendingReceived.count) { _, _ in
            Task { await loadPendingProfiles() }
        }
        // Reset request state when active meetup changes (starts or ends)
        .onChange(of: activeMeetSession?.id) { _, newSession in
            if newSession != nil {
                // Meetup just started — reset selector state
                flow.requestSent = false
                flow.selectedFriendId = nil
                flow.fullMeetingResult = nil
                flow.selectedOptionIndex = nil
                flow.currentCardPage = 0
            } else {
                // Meetup ended — reset everything
                flow.requestSent = false
            }
        }
        // Live-preview the paged option on the map. Without this, the
        // map's meeting pin + route lines stayed frozen on whatever
        // the user last pushed via SHOW ROUTE ON MAP, so paging
        // through OPTION 2 / OPTION 3 felt like "they all show the
        // same spot" even when the underlying graph nodes differed.
        // This is preview-only — it doesn't promote `selectedOption
        // Index`, so tapping is still the explicit "I want this one"
        // commitment.
        .onChange(of: flow.currentCardPage) { _, newPage in
            previewSelectedRouteOnMap(index: newPage)
        }
        // Also push the current page to the map whenever a fresh
        // solve lands. On a friend-tap → solve → TOP MATCH cards, the
        // map should mirror those cards immediately. `MeetingResult`
        // is `Equatable` (`MeetingPointSolver.swift`), so this only
        // fires when the underlying result actually differs.
        .onChange(of: flow.fullMeetingResult) { _, _ in
            previewSelectedRouteOnMap(index: flow.currentCardPage)
        }
        // Re-solve when test locations change
        .onChange(of: testMyNodeId) { _, _ in
            if let friend = selectedFriend {
                meetingResult = nil
                flow.fullMeetingResult = nil
                flow.selectedOptionIndex = nil
                flow.currentCardPage = 0
                flow.requestSent = false
                solveDebouncer.schedule { await solveMeeting(with: friend) }
            }
        }
        // Re-solve whenever the selected friend's position meaningfully
        // changes. Covers two cases in one watcher:
        //   1. First broadcast arrives after the user already tapped —
        //      the key goes nil → value, kicking off the initial solve.
        //   2. Friend moves while we're showing a route — re-solve so
        //      the meeting point and ETAs track their actual position
        //      instead of freezing at the spot they were when we first
        //      solved.
        // No debouncer here: the broadcaster already throttles
        // (120 ms moving / 850 ms idle in RealtimeLocationService) and
        // `selectedFriendLocationKey` rounds to ~11 m so sub-meter
        // jitter doesn't fire this watcher to begin with. Adding a
        // 100 ms receiver-side debounce on top of that was perceived
        // by users as friend-dot lag with no coalescing benefit.
        .onChange(of: selectedFriendLocationKey) { _, newKey in
            guard newKey != nil, let friend = selectedFriend else { return }
            Task { await solveMeeting(with: friend) }
        }
        // Re-solve when MY position meaningfully shifts too — same
        // rationale. Rounded to ~11 m via `lastSolvedMyKey` so jitter
        // doesn't thrash, and `LocationManager` itself already filters
        // by horizontal accuracy + minimum delta, so accepted fixes
        // arrive at human-paced cadence. No further debounce needed.
        .onChange(of: locationManager.fixGeneration) { _, _ in
            guard let friend = selectedFriend,
                  let coord = locationManager.currentLocation else { return }
            let lat = (coord.latitude * 10_000).rounded() / 10_000
            let lon = (coord.longitude * 10_000).rounded() / 10_000
            let key = "\(lat),\(lon)"
            guard key != flow.lastSolvedMyKey else { return }
            flow.lastSolvedMyKey = key
            Task { await solveMeeting(with: friend) }
        }
        // Re-solve when the user's skill / speed / condition fields
        // or the per-edge-speed caches change. Skill picker, RESET
        // STATS, activity import, and live-recorder flush all bump
        // `supabase.solverInputsKey`; without this watcher those
        // changes only landed on the *next* solve, which made the
        // skill slider feel inert and "I uploaded stats" produce no
        // visible route delta. The static solver cache key already
        // contains the same axes so this fires a fresh compute.
        .onChange(of: supabase.solverInputsKey) { _, _ in
            // Stale cache entries primed under the old physics need
            // to re-warm; clear the per-friend throttle so the next
            // friend-location update doesn't sit out the 5 s window.
            prefetcher.resetThrottle()
            prefetchVisibleFriends()
            guard let friend = selectedFriend else { return }
            Task { await solveMeeting(with: friend) }
        }
        // Background prefetch: pre-run the solver for every friend
        // with a known location so `handleFriendTap` finds the result
        // already cached. Triggered on first appear and every time
        // any friend's coarse position changes. Per-friend 5 s
        // throttle on `MeetPrefetcher` keeps this bounded even with
        // many friends idle-broadcasting at 850 ms.
        .task {
            prefetchVisibleFriends()
        }
        .onChange(of: allFriendsLocationKey) { _, _ in
            prefetchVisibleFriends()
        }
        .onChange(of: friendService.friends.count) { _, _ in
            prefetchVisibleFriends()
        }
    }

    // MARK: - Body composition

    @ViewBuilder
    private var contentSections: some View {
        let othersIncoming = meetRequestService.incomingRequests.filter {
            $0.id != activeMeetSession?.id
        }

        // ── Top: NAVIGATION / REQUESTS tab switcher ──
        // Same shape as AuthView's LOGIN/SIGN UP toggle: an HStack of
        // tabButtons inside a rounded inset, active tab gets the
        // accent fill. Auto-flips to REQUESTS when a new request comes
        // in so it doesn't sit invisible on the wrong tab.
        meetTabSwitcher(requestCount: othersIncoming.count)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .onChange(of: othersIncoming.count) { oldCount, newCount in
                if newCount > oldCount && meetTab == .navigation {
                    withAnimation(.easeInOut(duration: 0.2)) { meetTab = .requests }
                }
            }

        switch meetTab {
        case .navigation:
            navigationTabContent(activeSession: activeMeetSession)
        case .requests:
            requestsTabContent(othersIncoming: othersIncoming)
        }
    }

    // MARK: - NAVIGATION tab body

    @ViewBuilder
    private func navigationTabContent(activeSession: ActiveMeetSession?) -> some View {
        // Local @Bindable for `$flow.currentCardPage` — same opt-in
        // pattern as the top-level body; needed because this
        // sub-builder also passes a binding into MeetingOptionsSection.
        @Bindable var flow = flow

        if let session = activeSession {
            // Active meetup replaces the picker / options flow.
            HUDSectionHeader(label: "ACTIVE MEETUP").padding(.horizontal, 20)
                .padding(.bottom, 10)
            ActiveMeetupCardView(
                session: session,
                graph: resortManager.currentGraph,
                onViewOnMap: { onSwitchToMap?() },
                onEndMeetup: { onEndMeetup?() }
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        } else if flow.fullMeetingResult != nil || flow.isSolving {
            HUDSectionHeader(label: "MEETING OPTIONS").padding(.horizontal, 20)
                .padding(.bottom, 10)
            MeetingOptionsSection(
                result: flow.fullMeetingResult,
                isSolving: flow.isSolving,
                errorMessage: flow.solveErrorMessage,
                graph: resortManager.currentGraph,
                friendName: selectedFriend?.displayName,
                selectedOptionIndex: flow.selectedOptionIndex,
                currentCardPage: $flow.currentCardPage,
                onSelectOption: selectOption,
                onShowRoute: {
                    applySelectedRoute()
                    onSwitchToMap?()
                }
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        } else {
            // Quiet state — drawer + button below carry the workflow.
            navIdleHint
        }
    }

    private var navIdleHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.skiing.downhill")
                .font(.system(size: 28))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.3))
            Text("TAP A FRIEND BELOW TO START A MEETUP")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    // MARK: - REQUESTS tab body

    @ViewBuilder
    private func requestsTabContent(othersIncoming: [MeetRequest]) -> some View {
        if othersIncoming.isEmpty && friendService.pendingReceived.isEmpty {
            requestsEmptyState
        } else {
            if !othersIncoming.isEmpty {
                HUDSectionHeader(label: "INCOMING MEET REQUESTS").padding(.horizontal, 20)
                    .padding(.bottom, 10)
                IncomingMeetRequestsSection(
                    incoming: othersIncoming,
                    onMeetAccepted: onMeetAccepted
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if !friendService.pendingReceived.isEmpty {
                HUDSectionHeader(label: "PENDING FRIEND REQUESTS").padding(.horizontal, 20)
                    .padding(.bottom, 10)
                PendingFriendRequestsSection(
                    pendingReceived: friendService.pendingReceived,
                    pendingProfiles: flow.pendingProfiles
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private var requestsEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.25))
            Text("NO PENDING REQUESTS")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1.5)
            Text("MEET INVITES AND FRIEND REQUESTS LAND HERE")
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText.opacity(0.45))
                .tracking(0.5)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
    }

    // MARK: - Tab switcher

    private func meetTabSwitcher(requestCount: Int) -> some View {
        HStack(spacing: 0) {
            tabButton(title: MeetTab.navigation.rawValue,
                      isActive: meetTab == .navigation,
                      badge: nil) {
                withAnimation(.easeInOut(duration: 0.2)) { meetTab = .navigation }
            }
            tabButton(title: MeetTab.requests.rawValue,
                      isActive: meetTab == .requests,
                      badge: requestCount > 0 ? requestCount : nil) {
                withAnimation(.easeInOut(duration: 0.2)) { meetTab = .requests }
            }
        }
        .background(HUDTheme.inputBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func tabButton(title: String, isActive: Bool, badge: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .hudType(.label)
                    .foregroundColor(isActive ? .white : HUDTheme.secondaryText.opacity(0.5))
                    .tracking(1.5)
                if let badge {
                    Text("\(badge)")
                        .hudType(.caption)
                        .foregroundColor(isActive ? .white : HUDTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill((isActive ? Color.white : HUDTheme.accent).opacity(0.18))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(isActive ? HUDTheme.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Friend Tap Handler

    private func handleFriendTap(_ friend: UserProfile) {
        let isActive = flow.selectedFriendId == friend.id
        if isActive {
            // Deselect in the picker — but leave `meetingResult` (the
            // route on the map) alone. The user explicitly asked for
            // route persistence: a route that's been pushed to the map
            // with SHOW ROUTE ON MAP should stick around until they
            // either tap SHOW ROUTE for a new friend, start a meetup,
            // or cancel out via the map's dismiss control. Only the
            // Meet-tab solve state is cleared here.
            withAnimation(.easeInOut(duration: 0.15)) {
                flow.selectedFriendId = nil
                flow.fullMeetingResult = nil
                flow.solveErrorMessage = nil
                flow.selectedOptionIndex = nil
                flow.currentCardPage = 0
                flow.requestSent = false
                flow.lastSolvedMyKey = nil
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            flow.selectedFriendId = friend.id
            // Same reasoning — don't nuke the pinned map route when the
            // user is just comparing options for a different friend.
            // The map keeps whatever was last pushed via SHOW ROUTE.
            flow.fullMeetingResult = nil
            flow.solveErrorMessage = nil
            flow.selectedOptionIndex = nil
            flow.currentCardPage = 0
            flow.requestSent = false
            flow.lastSolvedMyKey = nil
        }
        // Cancel any in-flight prefetch so the foreground solve has
        // CPU to itself. The static cache the prefetch was priming
        // (or any prior prefetch already finished) is what makes the
        // tap-time `solveMeeting` fast.
        prefetcher.cancel()
        // No `solveDebouncer.schedule` wrap here: with the prefetched
        // cache primed, the tap-time `solveMeeting` is usually a
        // ~5 ms cache hit. The detached + gen-guarded solve keeps
        // mash-through-friends safe (each new tap bumps
        // `flow.solveGeneration`, prior solves drop their results
        // before render). The 100 ms debounce was dead latency.
        Task { await solveMeeting(with: friend) }
    }

    private func selectOption(_ index: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            flow.selectedOptionIndex = index
            flow.currentCardPage = index
            flow.requestSent = false
        }
    }

    // MARK: - Friend Helpers

    /// Friends sorted: at-resort first, then absent (alphabetical
    /// within each group).
    private var sortedFriends: [UserProfile] {
        friendService.friends.sorted { a, b in
            let aAtResort = isFriendAtResort(a.id)
            let bAtResort = isFriendAtResort(b.id)
            if aAtResort != bAtResort { return aAtResort }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Per-row presentation data for the LiveFriendsDrawer. Filters to
    /// friends currently live at the same resort and pre-resolves the
    /// trail/lift label so the drawer view stays service-free.
    private var liveDrawerRows: [LiveFriendsDrawer.Row] {
        sortedFriends
            .filter { isFriendAtResort($0.id) }
            .map { friend in
                LiveFriendsDrawer.Row(
                    friend: friend,
                    isActive: flow.selectedFriendId == friend.id,
                    locationName: friendLocationName(friend.id),
                    resortLabel: friendResortLabel(friend)
                )
            }
    }

    /// True if a friend is at the same resort — checks DB field first,
    /// then realtime presence. Gates `friendLocations` on freshness
    /// because the SwiftData cold-start cache can carry a stale position
    /// from a prior session at a different resort.
    private func isFriendAtResort(_ friendId: UUID) -> Bool {
        if let myResort = resortManager.currentEntry?.id,
           let friend = friendService.friends.first(where: { $0.id == friendId }),
           friend.currentResortId == myResort {
            return true
        }
        if friendsPresent.contains(friendId) { return true }
        if let loc = friendLocations[friendId],
           Date.now.timeIntervalSince(loc.capturedAt) < 90 {
            return true
        }
        return false
    }

    /// Resolves a friend's position to a trail/lift name on the graph.
    /// Friend can be anywhere on a chain — uses `.canonical` (no
    /// TOP/BOTTOM suffix); the row card just wants the trail/lift name.
    private func friendLocationName(_ friendId: UUID) -> String? {
        guard let friendLoc = friendLocations[friendId],
              let graph = resortManager.currentGraph else { return nil }
        let naming = MountainNaming(graph)
        if let nodeId = friendLoc.nearestNodeId, graph.nodes[nodeId] != nil {
            return naming.nodeLabel(nodeId, style: .canonical)
        }
        let coord = CLLocationCoordinate2D(latitude: friendLoc.latitude, longitude: friendLoc.longitude)
        return naming.locationLabel(near: coord, style: .canonical)
    }

    /// Label for "AT RESORT" badge: shows the resort name when known.
    private func friendResortLabel(_ friend: UserProfile) -> String {
        if let resortId = friend.currentResortId,
           let entry = ResortEntry.catalog.first(where: { $0.id == resortId }) {
            return entry.name.uppercased()
        }
        return "AT RESORT"
    }

    // MARK: - Send Meet Request (POWDERMEET button action)

    private func sendMeetRequest() {
        guard let friend = selectedFriend,
              let result = flow.fullMeetingResult,
              let idx = flow.selectedOptionIndex,
              let resortId = resortManager.currentEntry?.id,
              activeMeetSession == nil else { return }

        let node: GraphNode
        if idx == 0 {
            node = result.meetingNode
        } else if idx - 1 < result.alternates.count {
            node = result.alternates[idx - 1].node
        } else { return }

        let graph = resortManager.currentGraph
        // Sender stamps the canonical label so the receiver renders the
        // same name the picker would for that node id on its own graph.
        let displayName = graph.map { MountainNaming($0).meetingNodeLabel(node.id) }

        let myNodeId: String? = {
            // Same priority as ContentCoordinator.resolveMyNodeId — live
            // GPS wins over tester pick when GPS is at this resort.
            if let sticky = locationManager.gpsStickyGraphNodeId, graph?.nodes[sticky] != nil {
                return sticky
            }
            if let coord = locationManager.currentLocation, let n = graph?.nearestNode(to: coord) { return n.id }
            if let testId = testMyNodeId, graph?.nodes[testId] != nil { return testId }
            return nil
        }()
        let friendNodeId: String? = {
            if let reportedId = friendLocations[friend.id]?.nearestNodeId,
               graph?.nodes[reportedId] != nil {
                return reportedId
            }
            if let loc = friendLocations[friend.id] {
                let coord = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                return graph?.nearestNode(to: coord)?.id
            }
            return nil
        }()

        let senderEta: Double?
        let receiverEta: Double?
        let senderPath: [GraphEdge]
        let receiverPath: [GraphEdge]
        if idx == 0 {
            senderEta = result.timeA
            receiverEta = result.timeB
            senderPath = result.pathA
            receiverPath = result.pathB
        } else if idx - 1 < result.alternates.count {
            let alt = result.alternates[idx - 1]
            senderEta = alt.timeA
            receiverEta = alt.timeB
            senderPath = alt.pathA
            receiverPath = alt.pathB
        } else {
            senderEta = nil
            receiverEta = nil
            senderPath = []
            receiverPath = []
        }

        let senderPathIds = senderPath.isEmpty ? nil : senderPath.map { $0.id }
        let receiverPathIds = receiverPath.isEmpty ? nil : receiverPath.map { $0.id }

        Task {
            do {
                let result = try await meetRequestService.sendRequest(
                    to: friend.id,
                    resortId: resortId,
                    meetingNodeId: node.id,
                    meetingNodeElevation: node.elevation,
                    meetingNodeDisplayName: displayName,
                    senderPositionNodeId: myNodeId,
                    receiverPositionNodeId: friendNodeId,
                    senderEtaSeconds: senderEta,
                    receiverEtaSeconds: receiverEta,
                    senderPathEdgeIds: senderPathIds,
                    receiverPathEdgeIds: receiverPathIds,
                    // Stamp the graph snapshot we solved against, so the
                    // receiver can detect when their loaded graph is at a
                    // different version (different app build's pinned
                    // date, stale cache, etc.) and surface the mismatch
                    // instead of silently resolving meeting_node_id
                    // against a divergent topology.
                    graphSnapshotDate: resortManager.currentSnapshotDate,
                    // Canonical pipeline determinism: stamp the manifest
                    // version we solved against. When non-nil, the
                    // receiver force-fetches that exact manifest before
                    // re-solving, so both devices route on byte-identical
                    // graphs. Null = legacy meet (sender on pre-canonical
                    // pipeline); the existing graphSnapshotDate fallback
                    // applies.
                    manifestVersion: resortManager.currentManifestVersion
                )

                switch result {
                case .sent:
                    applySelectedRoute()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        flow.requestSent = true
                    }
                case .autoAcceptedIncoming(let accepted):
                    // We just promoted the friend's incoming request to
                    // accepted — skip the "waiting for them to accept"
                    // state and activate directly on our side. The same
                    // callback the `IncomingMeetRequestCard` uses kicks
                    // off `activateRouteAsReceiver` in `ContentView`.
                    onMeetAccepted?(accepted)
                }
            } catch let timeoutError as MeetRequestSendError {
                AppLog.meet.error("send meet request timed out: \(timeoutError.localizedDescription)")
                flow.sendError = timeoutError.localizedDescription
            } catch {
                AppLog.meet.error("send meet request failed: \(error)")
                flow.sendError = "Couldn't send — please try again."
            }
        }
    }

    // MARK: - Apply Selected Route (SHOW ROUTE ON MAP)

    /// Commit the user's selected option to the map. Driven by the
    /// explicit SHOW ROUTE ON MAP tap and by `sendMeetRequest()` on
    /// successful send. Reads `flow.selectedOptionIndex` because
    /// THAT'S the user's committed choice — distinct from
    /// `currentCardPage`, which is just "what's visible right now".
    /// Implementation defers to `previewSelectedRouteOnMap` so the
    /// commit and preview paths produce identical `meetingResult`
    /// values for the same option index.
    private func applySelectedRoute() {
        guard let idx = flow.selectedOptionIndex else { return }
        previewSelectedRouteOnMap(index: idx)
    }

    /// Push the option at `index` to the map's `meetingResult`
    /// binding WITHOUT touching `flow.selectedOptionIndex`. Driven by
    /// card paging (`onChange(of: currentCardPage)`) and by the
    /// solve-landed watcher (`onChange(of: fullMeetingResult)`) so
    /// the map always tracks what the user is currently viewing on
    /// the cards. The commit version (`applySelectedRoute`) calls
    /// through here so the two paths render the same geometry.
    ///
    /// Index semantics match the cards: `0` = TOP MATCH (the primary
    /// `MeetingResult`); `1..` = `alternates[index - 1]`. An invalid
    /// index (no result yet, or out of range) clears the map binding
    /// so the prior preview doesn't linger past the source data.
    private func previewSelectedRouteOnMap(index: Int) {
        guard let result = flow.fullMeetingResult else {
            // Solve cleared (e.g. failed re-solve or friend deselected
            // before a new result landed). Don't strand the prior
            // preview on the map — clear it so the route lines and
            // pin fall away alongside the cards.
            if meetingResult != nil {
                meetingResult = nil
            }
            return
        }

        if index == 0 {
            if meetingResult != result {
                meetingResult = result
            }
            return
        }

        let altIdx = index - 1
        guard altIdx < result.alternates.count else { return }
        let alt = result.alternates[altIdx]

        let next = MeetingResult(
            meetingNode: alt.node,
            pathA: alt.pathA,
            pathB: alt.pathB,
            timeA: alt.timeA,
            timeB: alt.timeB,
            alternates: []
        )
        if meetingResult != next {
            meetingResult = next
        }
    }

    // MARK: - Solve Meeting

    /// Build the `MeetSolver.Inputs` snapshot used by both the
    /// foreground tap-time `solveMeeting` and the background
    /// `MeetPrefetcher`. Returns nil when the resort gate, position
    /// snap, or friend position is missing. When `setUserVisibleErrors`
    /// is true, sets `flow.solveErrorMessage` on each failure path —
    /// the prefetcher passes false because a missing-position prefetch
    /// is silent (no card is showing yet).
    private func makeSolverInputs(
        for friend: UserProfile,
        setUserVisibleErrors: Bool
    ) async -> MeetSolver.Inputs? {
        guard let myProfile = supabase.currentUserProfile else { return nil }
        guard let graph = resortManager.currentGraph else { return nil }

        // ── Resort gate: refuse to solve unless the friend is at your
        // resort. friendLocations may carry a stale SwiftData hydrate
        // from a prior session, which would otherwise snap an off-mountain
        // friend onto your current graph and produce a phantom route.
        if let myResortId = resortManager.currentEntry?.id,
           friend.currentResortId != myResortId {
            if setUserVisibleErrors {
                flow.solveErrorMessage = "\(friend.displayName.uppercased()) IS NOT AT YOUR RESORT"
            }
            return nil
        }

        // ── My position: live GPS first, tester fallback — NO fake fallback ──
        // Priority matches ContentCoordinator.resolveMyNodeId: GPS at the
        // resort always wins over a stale tester pick.
        let myNodeId: String
        if let myCoord = locationManager.currentLocation,
           let myNode = graph.nearestNode(to: myCoord) {
            myNodeId = myNode.id
        } else if let testId = testMyNodeId, graph.nodes[testId] != nil {
            myNodeId = testId
        } else {
            if setUserVisibleErrors {
                flow.solveErrorMessage = "Your location is unknown — pick a test location in your profile or enable GPS"
            }
            return nil
        }

        // ── Friend position: broadcast node ID or broadcast GPS — NO
        // fake fallback ──
        let friendNodeId: String
        if let reportedNodeId = friendLocations[friend.id]?.nearestNodeId,
           graph.nodes[reportedNodeId] != nil {
            friendNodeId = reportedNodeId
        } else if let friendLoc = friendLocations[friend.id] {
            let friendCoord = CLLocationCoordinate2D(latitude: friendLoc.latitude, longitude: friendLoc.longitude)
            if let friendNode = graph.nearestNode(to: friendCoord) {
                friendNodeId = friendNode.id
            } else {
                if setUserVisibleErrors {
                    flow.solveErrorMessage = "Cannot place \(friend.displayName.uppercased()) on the trail map — waiting for their location"
                }
                return nil
            }
        } else {
            if setUserVisibleErrors {
                flow.solveErrorMessage = "WAITING FOR \(friend.displayName.uppercased())'S LOCATION — they need to be at the resort with the app open"
            }
            return nil
        }

        // Pull the friend's per-edge rolling speeds (friends-only RLS;
        // empty when they have no calibration history or aren't an
        // accepted friend yet — solver degrades to bucket physics in
        // that case). Cached after first fetch on `SupabaseManager`,
        // so this is a single network round-trip per friend per
        // session whether triggered from tap or prefetch.
        let friendEdgeSpeeds = await supabase.loadFriendEdgeSpeeds(for: friend.id)

        return MeetSolver.Inputs(
            myProfile:        myProfile,
            friend:           friend,
            graph:            graph,
            myNodeId:         myNodeId,
            friendNodeId:     friendNodeId,
            entry:            resortManager.currentEntry,
            conditions:       resortConditions,
            edgeSpeeds:       supabase.currentEdgeSpeeds,
            friendEdgeSpeeds: friendEdgeSpeeds
        )
    }

    private func solveMeeting(with friend: UserProfile) async {
        flow.solveGeneration &+= 1
        let gen = flow.solveGeneration
        // Only show the "CALCULATING ROUTES" spinner on the FIRST solve
        // for this friend (no existing cards visible yet). For every
        // subsequent re-solve — friend moved, GPS shifted, skill axes
        // updated — keep the existing cards on screen until the new
        // result swaps in. The previous code flipped `isSolving = true`
        // on every re-solve, which made `MeetingOptionsSection` switch
        // to its spinner placeholder for 5-200ms per friend-position
        // broadcast (~120ms cadence when they're moving), reading to
        // the user as "options glitch every second" — and worse,
        // making it impossible to keep a finger on OPTION 3 because
        // the card stack was being torn down and rebuilt mid-swipe.
        let hadResult = flow.fullMeetingResult != nil
        if !hadResult { flow.isSolving = true }
        // Do NOT reset `flow.currentCardPage` here. The previous
        // unconditional `flow.currentCardPage = 0` was the second leg
        // of the "options glitch" — even with the spinner removed,
        // every re-solve was yanking the user back to TOP MATCH so
        // they could never page to OPTION 2/3 without it being reset
        // by the next friend broadcast. The out-of-range safety check
        // below (after the result lands) handles the case where the
        // new result has fewer alternates than the user's current
        // page.
        flow.solveErrorMessage = nil
        defer { flow.isSolving = false }

        guard let inputs = await makeSolverInputs(for: friend, setUserVisibleErrors: true) else {
            AppLog.meet.debug("solveMeeting: skipped (preconditions not met)")
            return
        }

        AppLog.meet.debug("═══ SOLVE INPUT DUMP ═══")
        AppLog.meet.debug("My user: \(inputs.myProfile.id) \"\(inputs.myProfile.displayName)\" node=\(inputs.myNodeId)")
        AppLog.meet.debug("Friend:  \(inputs.friend.id) \"\(inputs.friend.displayName)\" node=\(inputs.friendNodeId)")
        AppLog.meet.debug("Graph: \(inputs.graph.nodes.count) nodes, \(inputs.graph.edges.count) edges (\(inputs.graph.edges.filter { $0.attributes.isOpen }.count) open)")
        if let c = inputs.conditions {
            AppLog.meet.debug("Conditions: temp=\(c.temperatureC)°C wind=\(c.windSpeedKph)km/h snow24h=\(c.snowfallLast24hCm)cm snowing=\(c.isSnowing)")
        }
        AppLog.meet.debug("═══════════════════════")

        // Run the 3-attempt fallback chain on a detached userInitiated
        // task so Dijkstra doesn't hitch the main actor on big resorts.
        // The c5e47b3 revert moved this back inline because of "ghost
        // meet point" regressions; the `solveGeneration` guard on
        // return makes detached safe again — a stale solve's result
        // is dropped before it can paint over the current one.
        let output = await Task.detached(priority: .userInitiated) {
            await MeetSolver.solve(inputs)
        }.value
        guard gen == flow.solveGeneration else {
            AppLog.meet.debug("solveMeeting: stale gen=\(gen) (now=\(flow.solveGeneration)) — discarding")
            return
        }
        let result = output.result

        if result == nil {
            AppLog.meet.info("Solver returned nil — no path found between \(inputs.myNodeId) and \(inputs.friendNodeId)")
            if let reason = output.failureReason {
                flow.solveErrorMessage = reason.userMessage
            } else {
                flow.solveErrorMessage = "Try selecting different locations — these positions are not connected by any trails"
            }
        } else {
            AppLog.meet.debug("Solver found meeting point: \(result!.meetingNode.id) with \(result!.alternates.count) alternates")
            flow.solveErrorMessage = nil
        }
        guard flow.selectedFriendId == friend.id else {
            AppLog.meet.debug("Solver finished but friend was deselected — discarding result")
            return
        }

        // Populate Meet-tab cards only. The map's `meetingResult`
        // binding is updated exclusively by `applySelectedRoute()` when
        // the user taps SHOW ROUTE ON MAP — keeps a previously-shown
        // route pinned while they browse alternates for a new friend.
        flow.fullMeetingResult = result
        // A solver re-run can return fewer alternates than the previous
        // result. If the user was paged past the new last card, the
        // index is out of range — snap back to 0 so the cards render
        // valid data.
        let newCount = (result?.alternates.count ?? 0) + (result == nil ? 0 : 1)
        if flow.currentCardPage >= newCount {
            flow.currentCardPage = 0
        }

        // Log turn-by-turn instructions for future UI integration.
        // Reuse the solver's canonical context factory so the
        // narrative consults the SAME bucketed weather + per-skier
        // edge history as the solve.
        if let result, let finalSolver = output.solver {
            let naming = MountainNaming(inputs.graph)
            let contextA = finalSolver.makeContext(for: inputs.myProfile.id.uuidString)
            let contextB = finalSolver.makeContext(for: friend.id.uuidString)
            let instructions = RouteInstructionBuilder.build(from: result.pathA, profile: inputs.myProfile, context: contextA, naming: naming)
            AppLog.meet.debug("Route instructions: \(instructions.map { $0.displayText }.joined(separator: " → "))")

            // Populate routeReason A/B so the route card can explain
            // the choice — each side reads its own physics.
            var annotated = result
            annotated.routeReasonA = RouteInstructionBuilder.reason(for: result.pathA, profile: inputs.myProfile)
            annotated.routeReasonB = RouteInstructionBuilder.reason(for: result.pathB, profile: friend)
            // Per-edge time breakdown so the meeting-option card can
            // show "LIFT 6: 8 min · FRONTSIDE: 3 min" instead of just
            // the aggregate. Threading the cumulative offset matches
            // the time-dependent wait the solver computed (so the
            // displayed sum equals `timeA`/`timeB`).
            annotated.legTimesA = legTimes(
                path: result.pathA,
                profile: inputs.myProfile,
                context: contextA,
                targetTotal: result.timeA
            )
            annotated.legTimesB = legTimes(
                path: result.pathB,
                profile: friend,
                context: contextB,
                targetTotal: result.timeB
            )
            // Same per-leg breakdown for every alternate, so OPTION 2/3/N
            // cards show the same per-step times as TOP MATCH instead of
            // a blank surface.
            annotated.alternates = result.alternates.map { alt in
                var copy = alt
                copy.legTimesA = legTimes(
                    path: alt.pathA,
                    profile: inputs.myProfile,
                    context: contextA,
                    targetTotal: alt.timeA
                )
                copy.legTimesB = legTimes(
                    path: alt.pathB,
                    profile: friend,
                    context: contextB,
                    targetTotal: alt.timeB
                )
                return copy
            }
            // `etaStdSecondsA/B` are populated by the solver directly
            // from `DijkstraEntry.varianceTime` accumulated during
            // relaxation, so no post-hoc compute is needed here. The
            // same variance also drove the candidate scoring (CVaR
            // term in the score formula), so the displayed range is
            // consistent with the recommendation rather than a
            // separate uncertainty estimate.
            flow.fullMeetingResult = annotated
        }
    }

    /// Per-edge traverse times along `path` whose sum is GUARANTEED to
    /// equal `targetTotal` (the headline ETA the solver reported).
    ///
    /// Two fallbacks fix the "1 second green run" problem:
    ///   1. The solver's Dijkstra may have succeeded by relaxing
    ///      constraints (forcedOpen / ignoreSkillGates / neighbor-
    ///      substitution). Post-hoc `traverseTime` doesn't know to
    ///      relax — it returns nil for those edges, the old code
    ///      substituted 0, and the displayed total drifted far from
    ///      the headline ETA (sometimes only 1-2 seconds).
    ///   2. After computing whatever times we can, scale them so
    ///      they sum to `targetTotal`. If raw values are all 0
    ///      (every edge nil'd), distribute by edge length so a
    ///      Whistler peak run doesn't read as 0s.
    ///
    /// The headline ETA is authoritative — it's the Dijkstra distance
    /// the solver actually returned. The breakdown is just a
    /// presentation of how that total splits across the path; if our
    /// post-hoc per-edge math disagrees, the post-hoc math is the one
    /// that's wrong, not the solver.
    private func legTimes(
        path: [GraphEdge],
        profile: UserProfile,
        context: TraversalContext,
        targetTotal: Double
    ) -> [Double] {
        guard !path.isEmpty, targetTotal > 0 else {
            return Array(repeating: 0, count: path.count)
        }
        // Step 1: best-effort raw per-edge times.
        var cumulative: Double = 0
        var raw: [Double] = []
        raw.reserveCapacity(path.count)
        for edge in path {
            let t = profile.traverseTime(
                for: edge, context: context, arrivalTimeOffsetSeconds: cumulative
            ) ?? 0
            raw.append(t)
            cumulative += t
        }
        let rawSum = raw.reduce(0, +)

        // Step 2: scale so the sum matches the headline ETA. Tolerate
        // small FP noise (solver-vs-recompute drift well under 1 s).
        if rawSum > 0.5 {
            let scale = targetTotal / rawSum
            return raw.map { $0 * scale }
        }

        // Step 3: every edge nil'd to 0 — distribute by edge length so
        // a 1500 m green run gets ~10 of the total, not all-or-nothing.
        let totalLen = path.reduce(0.0) { $0 + max($1.attributes.lengthMeters, 0) }
        if totalLen > 0 {
            return path.map { edge in
                let frac = max(edge.attributes.lengthMeters, 0) / totalLen
                return targetTotal * frac
            }
        }
        // Last resort: even split.
        let even = targetTotal / Double(path.count)
        return Array(repeating: even, count: path.count)
    }


    // MARK: - Pending Profile Loading

    private func loadPendingProfiles() async {
        let idsToFetch = friendService.pendingReceived
            .map(\.requesterId)
            .filter { flow.pendingProfiles[$0] == nil }
        guard !idsToFetch.isEmpty else { return }
        await withTaskGroup(of: (UUID, UserProfile?).self) { group in
            for id in idsToFetch {
                group.addTask { await (id, friendService.loadProfile(id: id)) }
            }
            for await (id, profile) in group {
                if let profile { flow.pendingProfiles[id] = profile }
            }
        }
    }
}

#Preview {
    MeetView(
        meetingResult: .constant(nil),
        friendLocations: [:],
        friendsPresent: [],
        resortConditions: nil,
        activeMeetSession: nil,
        onSwitchToMap: nil,
        onMeetAccepted: nil,
        onEndMeetup: nil,
        testMyNodeId: .constant(nil)
    )
}
