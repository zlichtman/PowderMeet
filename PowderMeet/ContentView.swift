//
//  ContentView.swift
//  PowderMeet
//
//  Pure routing layer — tabs, sheets, and the page header. All
//  state and lifecycle live on `ContentCoordinator`. The pre-extraction
//  version was ~1500 lines with 30+ @State vars and a dozen .onChange
//  watchers; that whole pile moved to ContentCoordinator.
//

import SwiftUI
import CoreLocation
import Combine

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ResortDataManager.self) private var resortManager

    @State private var coordinator = ContentCoordinator()

    // Pure UI state (everything that's about how the view looks, not
    // about the app session). Routing & sheet visibility belong here;
    // resort selection / meet session / realtime do not.
    @State private var selectedTab = 0
    @State private var showResortPicker = false
    @State private var selectedTrailEdgeId: String?
    @State private var isScrubbingTimeline = false

    // Map-first — app identity is "FATMAP merged with Find My," so the 3D
    // satellite view is the default landing tab. Meet (1) and Profile (2)
    // stay one tap away on the bottom tab bar.

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 0) {
            // ── Shared page header ──
            // The topo watermark surfaces faintly from the top edge
            // behind the title — the same brand motif as auth /
            // onboarding, now a whisper in the main-app chrome. It
            // lives inside `.background`, so it's clipped to the
            // header's bounds and can never bleed onto page content.
            pageHeader
                .background(
                    ZStack {
                        HUDTheme.headerBackground
                        MountainLinesTexture(placement: .headerBand)
                    }
                )

            // ── Offline indicator ──
            // Sits between the header and the page content so it never
            // covers the resort bar / tab bar (those need to stay tappable
            // — picking the right resort or switching tabs is the
            // *recovery* action when the user is offline). Only renders
            // when NWPathMonitor reports unreachable; otherwise zero
            // height. Auto-dismisses on reconnect via the @Observable
            // status binding.
            if !Reachability.shared.isReachable {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 11))
                    Text("OFFLINE — friends won't update")
                        .hudType(.label)
                        .tracking(0.8)
                }
                .foregroundColor(HUDTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(HUDTheme.accent.opacity(0.10))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(HUDTheme.accent.opacity(0.35)),
                    alignment: .bottom
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Gated on `selectedEntry != nil` because the resort-picker
            // overlay covers the chrome when no resort is chosen — no
            // point nagging about background location until the user is
            // actually skiing.
            if coordinator.selectedEntry != nil
                && coordinator.locationManager.authorizationStatus == .authorizedWhenInUse {
                PermissionBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Page content ──
            // All tabs stay in the hierarchy so @State is preserved across tab switches.
            ZStack {
                HUDTheme.mapBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Compact route summary (during active meetup) ──
                    if let session = coordinator.activeMeetSession {
                        CompactRouteSummary(
                            session: session,
                            graph: resortManager.currentGraph,
                            navigationVM: coordinator.navigationViewModel
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                coordinator.endActiveMeetup()
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // ── Map ──
                    // The "no resort picked" prompt no longer hangs off
                    // .overlay here. With it nested in this VStack it
                    // inherited the parent's tab-fade opacity, and during
                    // the 0.15s tab-switch animation the overlay went
                    // translucent — letting the fallback map flash
                    // through underneath. The prompt now sits at the
                    // ZStack level (sibling to tab views) so it stays at
                    // full opacity regardless of tab transitions.
                    mapScreen
                        .frame(maxHeight: .infinity)

                    // ── Bottom cards ──
                    if let session = coordinator.activeMeetSession,
                       let tracker = session.routeTracker,
                       let navEdge = tracker.currentEdge {
                        // Active-meetup nav card — intentionally omits conditions so
                        // the weather strip (resort-wide snowfall/temp/wind) is hidden.
                        EdgeInfoCard(edge: navEdge) {}
                        .id(navEdge.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let edgeId = selectedTrailEdgeId,
                              let graph = resortManager.currentGraph,
                              let edge = graph.representativeEdge(for: edgeId) {
                        EdgeInfoCard(
                            edge: edge,
                            trailGroup: graph.edgesInGroup(edgeId),
                            conditions: coordinator.resortConditions
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTrailEdgeId = nil
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Compact friends-near-me strip — sorted closest →
                    // farthest, name + straight-line distance only. No
                    // arrow / bearing — the map dots already encode
                    // direction. Renders nothing when empty.
                    FriendDistanceBar(items: friendDistanceItems)

                    TimelineView(
                        selectedDate: $coordinator.selectedTime,
                        // Extend the scrubber window into the future when an
                        // active meetup has an ETA — otherwise the user can't
                        // scrub past "now" to preview where each skier will
                        // be on-route at arrival time.
                        futureRangeMax: coordinator.activeMeetupFutureRangeMax,
                        // Supply live weather so the scrubber's conditions
                        // HUD leaves "LIVE WEATHER LOADING…" the moment
                        // `loadConditions` commits.
                        conditions: coordinator.resortConditions,
                        onDraggingChanged: { dragging in
                            isScrubbingTimeline = dragging
                        }
                    )
                    .background(HUDTheme.headerBackground)

                    resortBar
                        .background(HUDTheme.headerBackground)
                }
                .animation(.easeInOut(duration: 0.2), value: selectedTrailEdgeId)
                .animation(.easeInOut(duration: 0.2), value: coordinator.activeMeetSession?.routeTracker?.currentEdgeIndex)
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)

                MeetView(
                    meetingResult: $coordinator.meetingResult,
                    friendLocations: coordinator.realtimeLocation?.friendLocations ?? [:],
                    friendsPresent: coordinator.realtimeLocation?.friendsPresent ?? [],
                    resortConditions: coordinator.resortConditions,
                    activeMeetSession: coordinator.activeMeetSession,
                    onSwitchToMap: {
                        coordinator.routeAnimationTrigger += 1
                        // Instant flip — see `tabButton` for why we don't
                        // animate `selectedTab` (avoids the underlying
                        // Map flashing through the fading-in tab).
                        selectedTab = 0
                    },
                    onMeetAccepted: { request in
                        Task { await coordinator.activateRouteAsReceiver(for: request) }
                    },
                    onEndMeetup: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            coordinator.endActiveMeetup()
                        }
                    },
                    testMyNodeId: $coordinator.testMyNodeId
                )
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)

                ProfileView(testMyNodeId: $coordinator.testMyNodeId)
                    .opacity(selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 2)

                // "Choose your mountain" gate. Sits at ZStack-sibling
                // level (not inside any tab's VStack) so the overlay
                // doesn't inherit the tab-fade opacity animation. Renders
                // only on the map tab and only before a resort is picked.
                if selectedTab == 0 && coordinator.selectedEntry == nil {
                    pickResortOverlay
                        .allowsHitTesting(true)
                }
            }
            .frame(maxHeight: .infinity)
            // Clip the tab content's vertical bounds so a tab whose
            // intrinsic content exceeds the available height (e.g.
            // dense settings panels in Profile) overflows internally
            // rather than pushing the tab bar to compress.
            .clipped()

            // ── Tab bar ──
            // Mathematically pinned via explicit `.frame(height: 49)`.
            // Earlier attempts (`.layoutPriority(1)` + `.clipped()`,
            // then `.safeAreaInset(edge: .bottom)`) still let dense
            // sub-tabs (notably Account) shift the bar's vertical
            // extent — SwiftUI was re-evaluating intrinsic height
            // against the active tab's content. A fixed frame
            // removes the recompute path entirely. 49pt matches
            // UIKit's standard tab-bar height.
            //
            // Old-height bar (buttons stay in the 49pt band): the
            // background ZStack ignores the bottom safe area so the
            // fill AND the mountain-line skin BLEED down through the
            // home-indicator zone. That fills what used to be a dead
            // strip below the buttons with the brand skin instead of
            // physically dragging the glyphs onto the indicator.
            tabBar
                .frame(height: 49)
                .background(
                    ZStack {
                        HUDTheme.headerBackground
                        // Same brand motif as the page header, kept a
                        // whisper (.panel) so it sits BEHIND the tab
                        // glyphs without competing — the buttons have
                        // no fill of their own, so a louder texture
                        // would fight the icons/labels.
                        MountainLinesTexture(placement: .panel)
                    }
                    // Bleed fill + skin to the physical screen edge so
                    // the home-indicator zone reads as bar, not a dead
                    // gap. Buttons stay in the 49pt band above it.
                    .ignoresSafeArea(edges: .bottom)
                )
        }
        .overlay(alignment: .top) {
            // Transient banner (e.g. graph-drift on route activation).
            // Sits below the page header but above the rest of the
            // chrome so the user catches it without dismissing.
            if let message = coordinator.transientMessage {
                Text(message)
                    .hudType(.label)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(HUDTheme.cardBackground.opacity(0.95))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(HUDTheme.accent.opacity(0.5), lineWidth: 0.5)
                            )
                    )
                    .padding(.top, 56)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(message)  // re-trigger transition on message change
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.transientMessage)
        .ignoresSafeArea(.keyboard)
        .environment(resortManager)
        .environment(coordinator.friendService)
        .environment(coordinator.locationManager)
        .environment(coordinator.meetRequestService)
        .preferredColorScheme(.dark)
        .onDisappear {
            // ContentView disappears when the user signs out or deletes
            // their account (RootView switches from ContentView → AuthView).
            coordinator.teardown()
        }
        .sheet(isPresented: $showResortPicker) {
            ResortPickerSheet(
                selectedEntry: $coordinator.selectedEntry,
                atYourLocationCandidates: coordinator.pendingResortChoices
            )
        }
        .onChange(of: showResortPicker) { _, isShowing in
            // When the user closes the picker, any selection they made is
            // treated as deliberate — disable GPS auto-snap from here on.
            if !isShowing, coordinator.selectedEntry != nil {
                coordinator.userManuallyPickedResort = true
            }
        }
        .onChange(of: coordinator.selectedEntry) { _, entry in
            selectedTrailEdgeId = nil
            coordinator.handleSelectedEntryChange(to: entry)
        }
        .onChange(of: selectedTab) { _, _ in
            selectedTrailEdgeId = nil
        }
        // Push-tap deep-link router. Notify posts a `.powderMeetDeepLink`
        // event when the user taps a remote-notification banner; we
        // switch to the target tab so they land on the relevant
        // section (incoming meet card, friends list, etc.) rather
        // than wherever they last were.
        .onReceive(NotificationCenter.default.publisher(for: .powderMeetDeepLink)) { note in
            guard let link = note.object as? DeepLink else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = link.targetTab
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            guard selectedTab == 0, coordinator.selectedEntry != nil else { return }
            coordinator.mapFriendLayerClock &+= 1
        }
        .onChange(of: coordinator.activeMeetSession?.id) { _, newId in
            coordinator.syncNavigationServices()
            coordinator.refreshGhostCache(force: true)
            // Both sides — sender and receiver — auto-navigate to the
            // Map tab the moment a meetup activates. The two activation
            // paths (`activateRoute` for the sender on `meets:` accept,
            // `activateRouteAsReceiver` for the receiver on Accept tap)
            // both set `coord.activeMeetSession` to non-nil before
            // returning, so a single watcher on this id covers both.
            // Without this the user who sent (or who tapped Accept)
            // sat in MeetView staring at the request card while their
            // route animated onto a map they couldn't see.
            if newId != nil, selectedTab != 0 {
                selectedTab = 0
            }
        }
        // Reroutes replace `session.routeTracker` with a fresh instance
        // while keeping `session.id` constant — see `reroute()` where the
        // coordinator explicitly calls `syncNavigationServices()` after
        // the swap, rather than adding another `.onChange` here.
        .onChange(of: resortManager.currentGraph?.fingerprint) { _, _ in
            // Graph was replaced (resort swap or background enrichment) —
            // if the selected edge no longer exists in the new graph, drop
            // the selection so we don't leave a dangling highlight.
            if coordinator.graphChangedShouldDropEdgeSelection(selectedTrailEdgeId) {
                selectedTrailEdgeId = nil
            }
            // While a meetup is active, a graph mutation can mean a
            // previously-closed run/lift just opened up. Ask the
            // session controller whether the new topology offers a
            // meaningfully faster path to the same meeting node and
            // swap the route in if so. Throttled + threshold-gated
            // inside `evaluateFasterRerouteIfNeeded` so this isn't
            // a per-fingerprint thrash.
            coordinator.meetup.evaluateFasterRerouteIfNeeded()
        }
        .onChange(of: coordinator.friendService.friends.map(\.id)) { _, newIds in
            coordinator.handleFriendIdsChange(newIds: newIds)
        }
        .onChange(of: coordinator.selectedTime) { _, newTime in
            coordinator.handleSelectedTimeChange(newTime)
        }
        .onChange(of: coordinator.testMyNodeId) { _, newId in
            coordinator.handleTestMyNodeIdChange(newId: newId)
        }
        .onChange(of: coordinator.locationManager.fixGeneration) { _, _ in
            // `fixGeneration` increments on every accepted fix — this
            // replaces the old `currentLocation?.latitude` trigger, which
            // missed pure-longitude moves and quantised duplicates that
            // produced the same Double bit-pattern twice.
            coordinator.handleLocationChange()
        }
        .task {
            coordinator.bind(resortManager: resortManager)
            await coordinator.bootstrap(onAutoPresentResortPicker: {
                showResortPicker = true
            })
        }
        .onChange(of: scenePhase) { oldPhase, phase in
            coordinator.handleScenePhaseChange(oldPhase: oldPhase, newPhase: phase)
        }
    }

    // MARK: - Map Screen (factored out to keep `body` type-checkable)

    /// Hosting the 20+-parameter `ResortMapScreen` inline in `body` pushes
    /// the SwiftUI type-checker past its expression-inference budget —
    /// unrelated expressions in the same closure start failing with "unable
    /// Friends-on-resort distance items, sorted closest → farthest.
    /// Filters to friends in the same-resort presence set so we don't
    /// render distance for someone half a country away. Empty when
    /// either the user has no GPS fix or no friends are present.
    private var friendDistanceItems: [FriendDistanceBar.Item] {
        guard let myCoord = coordinator.locationManager.currentLocation else { return [] }
        let presentIds = coordinator.realtimeLocation?.friendsPresent ?? []
        let me = CLLocation(latitude: myCoord.latitude, longitude: myCoord.longitude)
        let locations = coordinator.realtimeLocation?.friendLocations ?? [:]
        return presentIds.compactMap { id -> FriendDistanceBar.Item? in
            guard let friend = locations[id] else { return nil }
            let f = CLLocation(latitude: friend.latitude, longitude: friend.longitude)
            return FriendDistanceBar.Item(
                id: id,
                name: friend.displayName,
                distanceMeters: me.distance(from: f)
            )
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// to type-check this expression in reasonable time". Extracting the
    /// view construction isolates the type-checker's work on this one spot.
    @ViewBuilder
    private var mapScreen: some View {
        ResortMapScreen(
            selectedTrailEdgeId: $selectedTrailEdgeId,
            meetingResult: coordinator.meetingResult ?? coordinator.activeMeetSession?.meetingResult,
            userLocation: coordinator.snappedUserLocation,
            friendLocations: coordinator.realtimeLocation?.friendLocations ?? [:],
            replayPositions: coordinator.isShowingReplay ? coordinator.locationHistory.positions(at: coordinator.selectedTime) : [:],
            replayTrails: coordinator.isShowingReplay ? coordinator.replayTrails(upTo: coordinator.selectedTime) : [:],
            routeAnimationTrigger: coordinator.routeAnimationTrigger,
            isActiveMeetup: coordinator.activeMeetSession != nil,
            meetupPartnerId: coordinator.activeMeetSession?.friendProfile.id,
            ghostPositions: coordinator.cachedGhostPositions,
            selectedTime: coordinator.selectedTime,
            isScrubbingTimeline: isScrubbingTimeline,
            resortLatitude: resortManager.currentEntry.map { ($0.bounds.minLat + $0.bounds.maxLat) / 2 },
            resortLongitude: resortManager.currentEntry.map { ($0.bounds.minLon + $0.bounds.maxLon) / 2 },
            temperatureC: coordinator.resortConditions?.temperatureC ?? -2,
            cloudCoverPercent: coordinator.resortConditions?.cloudCoverPercent ?? 0,
            snowfallCmPerHour: coordinator.resortConditions?.atTime(coordinator.selectedTime)?.snowfallCm ?? 0,
            mapBridge: coordinator.mapBridge,
            isMapVisible: selectedTab == 0 && coordinator.selectedEntry != nil,
            mapFriendLayerClock: coordinator.mapFriendLayerClock,
            friendSignalQualities: coordinator.friendQualityStore.qualities
        )
    }

    // MARK: - No-Resort Overlay

    /// Shown on the map tab before the user picks a resort (and GPS hasn't
    /// auto-resolved one). Previously the map silently centered on a random
    /// catalog entry; this overlay turns the empty state into a clear prompt.
    @ViewBuilder
    private var pickResortOverlay: some View {
        ZStack {
            // Fully opaque backdrop so the arbitrary satellite imagery
            // underneath never shows through.
            HUDTheme.mapBackground
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(HUDTheme.accent, HUDTheme.accent.opacity(0.3))

                VStack(spacing: 8) {
                    Text("CHOOSE YOUR MOUNTAIN")
                        .hudType(.title)
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(2)
                    Text("PICK A RESORT TO LOAD THE MAP AND START\nMEETING UP WITH FRIENDS ON THE SNOW")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .tracking(0.5)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 32)

                Button {
                    showResortPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                        Text("PICK A RESORT")
                            .hudType(.bodyEmph)
                            .tracking(2)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(HUDTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Page Header

    private var pageTitle: String {
        switch selectedTab {
        case 0:  "MAP"
        case 1:  "POWDERMEET"
        case 2:  "PROFILE"
        default: ""
        }
    }

    private var pageHeader: some View {
        HStack {
            Text(pageTitle)
                .hudType(.title)
                .foregroundColor(HUDTheme.accent)
                .tracking(3)
            Spacer()

        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Resort Bar

    private var resortBar: some View {
        Button { showResortPicker = true } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(resortManager.isLoading ? HUDTheme.accentAmber : HUDTheme.accent)
                    .frame(width: 6, height: 6)

                Text((coordinator.selectedEntry?.name ?? "SELECT RESORT").uppercased())
                    .hudType(.bodyEmph)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1.5)
                    .lineLimit(1)

                Image(systemName: "chevron.up")
                    .hudType(.caption)
                    .foregroundColor(HUDTheme.accent.opacity(0.5))

                Spacer()

                if resortManager.currentGraph != nil {
                    Text("\(resortManager.runCount) RUNS · \(resortManager.liftCount) LIFTS")
                        .hudType(.label)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                } else if resortManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(HUDTheme.spinnerDataLoad)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(
                Rectangle()
                    .fill(HUDTheme.cardBorder)
                    .frame(height: 0.5),
                alignment: .top
            )
            .overlay(
                Rectangle()
                    .fill(HUDTheme.cardBorder)
                    .frame(height: 0.5),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Map", icon: "map.fill", tag: 0)
            tabButton(title: "PowderMeet", icon: "person.2.fill", tag: 1)
            tabButton(title: "Profile", icon: "person.circle.fill", tag: 2)
        }
        // Old-height padding: the glyph group sits in the 49pt band;
        // everything below is the bled-down brand skin, not dead air.
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button {
            // Instant opacity flip — no `withAnimation`. With the stacked-
            // opacity ZStack, animating `selectedTab` over 150ms means
            // the outgoing tab fades 1→0 while the incoming fades 0→1;
            // at the midpoint both are at 0.5 and the bottommost
            // layer (Map) shows through the incoming tab's translucent
            // area, producing a visible Map flash on every Map→Meet
            // and Map→Profile switch. Same root cause as the earlier
            // pickResortOverlay flash documented above the mapScreen
            // VStack — that one was solved by lifting the overlay out
            // of the fade scope; this one is solved by removing the
            // fade entirely. Native iOS tab bars switch instantly too.
            selectedTab = tag
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title.uppercased())
                    .hudType(.label)
                    .tracking(1)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(
                selectedTab == tag ? HUDTheme.accent
                : HUDTheme.secondaryText.opacity(0.6)
            )
        }
        .buttonStyle(.plain)
    }

}

#Preview {
    ContentView()
}
