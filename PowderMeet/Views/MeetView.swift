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

    /// Coalesces rapid re-solve triggers (friend tap spam, test-location
    /// toggles) into one Dijkstra run; the solver's static cache covers
    /// repeat inputs.
    @State private var solveDebouncer = Debouncer(milliseconds: 100)

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
        // The Debouncer collapses bursts, and the solver's static cache
        // absorbs repeat inputs, so re-firing here is cheap.
        .onChange(of: selectedFriendLocationKey) { _, newKey in
            guard newKey != nil, let friend = selectedFriend else { return }
            solveDebouncer.schedule { await solveMeeting(with: friend) }
        }
        // Re-solve when MY position meaningfully shifts too — same
        // rationale. Rounded to ~11 m so jitter doesn't thrash, driven
        // by the monotonic fixGeneration so the watcher fires on every
        // accepted fix.
        .onChange(of: locationManager.fixGeneration) { _, _ in
            guard let friend = selectedFriend,
                  let coord = locationManager.currentLocation else { return }
            let lat = (coord.latitude * 10_000).rounded() / 10_000
            let lon = (coord.longitude * 10_000).rounded() / 10_000
            let key = "\(lat),\(lon)"
            guard key != flow.lastSolvedMyKey else { return }
            flow.lastSolvedMyKey = key
            solveDebouncer.schedule { await solveMeeting(with: friend) }
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
            sectionDivider("ACTIVE MEETUP")
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
            sectionDivider("MEETING OPTIONS")
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
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                sectionDivider("INCOMING MEET REQUESTS")
                    .padding(.bottom, 10)
                IncomingMeetRequestsSection(
                    incoming: othersIncoming,
                    onMeetAccepted: onMeetAccepted
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if !friendService.pendingReceived.isEmpty {
                sectionDivider("PENDING FRIEND REQUESTS")
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1.5)
            Text("MEET INVITES AND FRIEND REQUESTS LAND HERE")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isActive ? .white : HUDTheme.secondaryText.opacity(0.5))
                    .tracking(1.5)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
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

    // MARK: - Section Divider

    private func sectionDivider(_ label: String) -> some View {
        HStack {
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                .tracking(2)
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
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
        solveDebouncer.schedule { await solveMeeting(with: friend) }
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
                    receiverPathEdgeIds: receiverPathIds
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
            } catch {
                AppLog.meet.error("send meet request failed: \(error)")
            }
        }
    }

    // MARK: - Apply Selected Route (SHOW ROUTE ON MAP)

    private func applySelectedRoute() {
        guard let result = flow.fullMeetingResult,
              let idx = flow.selectedOptionIndex else { return }

        if idx == 0 {
            meetingResult = result
            return
        }

        let altIdx = idx - 1
        guard altIdx < result.alternates.count else { return }
        let alt = result.alternates[altIdx]

        meetingResult = MeetingResult(
            meetingNode: alt.node,
            pathA: alt.pathA,
            pathB: alt.pathB,
            timeA: alt.timeA,
            timeB: alt.timeB,
            alternates: []
        )
    }

    // MARK: - Solve Meeting

    private func solveMeeting(with friend: UserProfile) async {
        guard let myProfile = supabase.currentUserProfile else { return }
        guard let graph = resortManager.currentGraph else { return }

        flow.isSolving = true
        flow.currentCardPage = 0
        flow.solveErrorMessage = nil
        defer { flow.isSolving = false }

        // ── Resort gate: refuse to solve unless the friend is at your
        // resort. friendLocations may carry a stale SwiftData hydrate
        // from a prior session, which would otherwise snap an off-mountain
        // friend onto your current graph and produce a phantom route.
        if let myResortId = resortManager.currentEntry?.id,
           friend.currentResortId != myResortId {
            flow.solveErrorMessage = "\(friend.displayName.uppercased()) IS NOT AT YOUR RESORT"
            AppLog.meet.debug("solveMeeting: friend resort mismatch (mine=\(myResortId), friend=\(friend.currentResortId ?? "nil"))")
            return
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
            flow.solveErrorMessage = "Your location is unknown — pick a test location in your profile or enable GPS"
            AppLog.meet.debug("solveMeeting: no location for self")
            return
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
                flow.solveErrorMessage = "Cannot place \(friend.displayName.uppercased()) on the trail map — waiting for their location"
                AppLog.meet.debug("solveMeeting: friend GPS doesn't map to a graph node")
                return
            }
        } else {
            flow.solveErrorMessage = "WAITING FOR \(friend.displayName.uppercased())'S LOCATION — they need to be at the resort with the app open"
            AppLog.meet.debug("solveMeeting: no location for friend \(friend.id)")
            return
        }

        AppLog.meet.debug("═══ SOLVE INPUT DUMP ═══")
        AppLog.meet.debug("My user: \(myProfile.id) \"\(myProfile.displayName)\" node=\(myNodeId)")
        AppLog.meet.debug("Friend:  \(friend.id) \"\(friend.displayName)\" node=\(friendNodeId)")
        AppLog.meet.debug("Graph: \(graph.nodes.count) nodes, \(graph.edges.count) edges (\(graph.edges.filter { $0.attributes.isOpen }.count) open)")
        AppLog.meet.debug("My skill: \(myProfile.skillLevel)")
        AppLog.meet.debug("Friend skill: \(friend.skillLevel)")
        if let c = resortConditions {
            AppLog.meet.debug("Conditions: temp=\(c.temperatureC)°C wind=\(c.windSpeedKph)km/h snow24h=\(c.snowfallLast24hCm)cm snowing=\(c.isSnowing)")
        } else {
            AppLog.meet.debug("Conditions: nil (using defaults)")
        }
        AppLog.meet.debug("═══════════════════════")

        // Hand the 3-attempt fallback chain off to MeetSolver — pure
        // compute, runs on a detached userInitiated task so Dijkstra
        // doesn't hitch the cards UI when the user pages friends.
        let output = await MeetSolver.solve(MeetSolver.Inputs(
            myProfile:    myProfile,
            friend:       friend,
            graph:        graph,
            myNodeId:     myNodeId,
            friendNodeId: friendNodeId,
            entry:        resortManager.currentEntry,
            conditions:   resortConditions,
            edgeSpeeds:   supabase.currentEdgeSpeeds
        ))
        let result = output.result

        if result == nil {
            AppLog.meet.info("Solver returned nil — no path found between \(myNodeId) and \(friendNodeId)")
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
            let naming = MountainNaming(graph)
            let contextA = finalSolver.makeContext(for: myProfile.id.uuidString)
            let instructions = RouteInstructionBuilder.build(from: result.pathA, profile: myProfile, context: contextA, naming: naming)
            AppLog.meet.debug("Route instructions: \(instructions.map { $0.displayText }.joined(separator: " → "))")

            // Populate routeReason A/B so the route card can explain
            // the choice — each side reads its own physics.
            var annotated = result
            annotated.routeReasonA = RouteInstructionBuilder.reason(for: result.pathA, profile: myProfile)
            annotated.routeReasonB = RouteInstructionBuilder.reason(for: result.pathB, profile: friend)
            flow.fullMeetingResult = annotated
        }
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
