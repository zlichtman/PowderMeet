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
            pageHeader
                .background(HUDTheme.headerBackground)

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
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = 0 }
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

            // ── Tab bar ──
            tabBar
                .background(HUDTheme.headerBackground)
        }
        .overlay(alignment: .top) {
            // Transient banner (e.g. graph-drift on route activation).
            // Sits below the page header but above the rest of the
            // chrome so the user catches it without dismissing.
            if let message = coordinator.transientMessage {
                Text(message)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
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
            ResortPickerSheet(selectedEntry: $coordinator.selectedEntry)
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
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            guard selectedTab == 0, coordinator.selectedEntry != nil else { return }
            coordinator.mapFriendLayerClock &+= 1
        }
        .onChange(of: coordinator.activeMeetSession?.id) { _, _ in
            coordinator.syncNavigationServices()
            coordinator.refreshGhostCache(force: true)
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
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(2)
                    Text("PICK A RESORT TO LOAD THE MAP AND START\nMEETING UP WITH FRIENDS ON THE SNOW")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
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
                .font(.system(size: 15, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1.5)
                    .lineLimit(1)

                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.accent.opacity(0.5))

                Spacer()

                if resortManager.currentGraph != nil {
                    Text("\(resortManager.runCount) RUNS · \(resortManager.liftCount) LIFTS")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
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
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tag }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
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
