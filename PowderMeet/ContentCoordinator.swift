//
//  ContentCoordinator.swift
//  PowderMeet
//
//  Owns the resort-entry / realtime / conditions / meetup lifecycle that
//  used to live as ~30 @State vars + a dozen onChange watchers in
//  ContentView. ContentView now does pure routing (tabs, sheets) and
//  binds to this coordinator.
//
//  The coordinator is the *single owner* of:
//    - resort selection / change pipeline
//    - conditions fetch sequencing (current → debounced hourly)
//    - presence coordinator wiring + realtime channel start/stop
//    - friend cache eviction triggers
//    - active meetup session + nav-layer services
//    - ghost-positions cache for the timeline scrubber
//
//  Threading. `@MainActor` — every method is main-thread; long work goes
//  through `Task` and either yields or hits other actors. The owned
//  services (`FriendService`, `MeetRequestService`, etc.) are also
//  `@MainActor`, so cross-method calls compose without hops.
//

import SwiftUI
import CoreLocation
import Auth

@MainActor @Observable
final class ContentCoordinator {

    // MARK: - Owned services

    let friendService = FriendService()
    let locationManager = LocationManager()
    let meetRequestService = MeetRequestService()
    let locationHistory = LocationHistoryStore()
    let friendQualityStore = FriendQualityStore()
    let mapBridge = MapBridge()

    /// Built lazily in `bind(resortManager:)` once we have the resort
    /// manager handle — the recorder needs both Supabase and the
    /// resort manager to flush a matched run.
    private(set) var liveRunRecorder: LiveRunRecorder?

    /// Owns the lazy `RealtimeLocationService` + `PresenceCoordinator`.
    /// See `RealtimeBootstrapper.swift` for the lifecycle contract.
    let realtime: RealtimeBootstrapper

    /// Owns activate-route / reroute / sync-navigation-services and the
    /// four navigation-layer services. See `MeetupSessionController.swift`.
    let meetup: MeetupSessionController

    /// Pass-through to `realtime.location`. Kept on the coordinator so
    /// SwiftUI call sites (`ContentView` reads
    /// `coordinator.realtimeLocation?.friendLocations`) don't have to
    /// learn the new path. The bootstrapper is `@Observable`, so changes
    /// to the underlying property still drive SwiftUI invalidation
    /// through the computed accessor.
    var realtimeLocation: RealtimeLocationService? { realtime.location }
    var presenceCoordinator: PresenceCoordinator? { realtime.presence }

    /// Pass-throughs to `meetup` — same SwiftUI-binding rationale as
    /// `realtimeLocation`. ContentView reads `coordinator.navigationViewModel`;
    /// the actual storage lives on the controller.
    var navigationDirector: NavigationDirector? { meetup.navigationDirector }
    var navigationViewModel: NavigationViewModel? { meetup.navigationViewModel }
    var routeChoreographer: RouteChoreographer? { meetup.routeChoreographer }
    var etaEstimator: BlendedETAEstimator? { meetup.etaEstimator }

    // MARK: - Observed state

    var selectedEntry: ResortEntry?
    var resortConditions: ResortConditions?
    var meetingResult: MeetingResult?
    var activeMeetSession: ActiveMeetSession?
    var selectedTime: Date = .now

    /// Test-location override (`ProfileView` "test as node X" debug button).
    /// Kept on the coordinator because every node-resolution path consults
    /// it before falling back to GPS sticky / nearest-node.
    var testMyNodeId: String?

    /// Bumps every time the user taps "Show Route on Map" — forces
    /// `MountainMapView` to replay the camera-frame + line-trim animation
    /// even when the same route is already displayed.
    var routeAnimationTrigger: Int = 0

    /// Transient banner shown over the map (or wherever the host renders
    /// it). Set by the coordinator on conditions the user should see but
    /// that don't warrant a blocking alert — e.g. graph-drift on route
    /// activation. Auto-clears after `transientMessageDurationSeconds`
    /// via `clearTransientMessageAfterDelay()` so callers don't have to
    /// schedule the dismiss themselves.
    var transientMessage: String?
    @ObservationIgnored private var transientMessageClearTask: Task<Void, Never>?
    private let transientMessageDurationSeconds: Double = 4.0

    /// Set to `true` the first time the user picks a resort from the sheet.
    /// While true, GPS-based auto-snap won't override their choice — without
    /// this, driving past another resort en route to the one you picked
    /// could yank the map out from under you.
    var userManuallyPickedResort = false

    /// Tracks whether we've already auto-presented the resort picker this
    /// cold launch, so we don't re-open it every time the user dismisses.
    var didAutoPresentResortPicker = false

    /// Bumps every 60s on the Map tab so friend dots/labels refresh for the
    /// 3h visibility cutoff and age pills without waiting for a new peer
    /// location update. Driven from the view's `Timer.publish` since the
    /// publisher only fires while the view is on-screen.
    var mapFriendLayerClock: Int = 0

    /// Cached projected positions for the scrubbed instant during an
    /// active meetup. Recomputed by `refreshGhostCache(force:)` only when
    /// the 30s scrub bucket or session ID changes — without this cache,
    /// `ghostPositionsForScrub` ran hundreds of `traverseTime` calls on
    /// every unrelated state change.
    var cachedGhostPositions: [UUID: [(coordinate: CLLocationCoordinate2D, label: String)]] = [:]

    // MARK: - Internal (not observed by UI)

    /// Set by `bind(resortManager:)` once, from the view's `.task`
    /// closure, before any onChange/method invocation that touches
    /// the graph. Wrapped by the `resortManager` accessor below.
    @ObservationIgnored private var resortManagerRef: ResortDataManager?

    var resortManager: ResortDataManager {
        guard let r = resortManagerRef else {
            // The view's `.task` calls `bind(resortManager:)` before
            // bootstrap, and onChange handlers don't fire before the
            // first .task runs. Hitting this path means the
            // ContentView lifecycle changed shape — fail loud rather
            // than silently no-op (which would produce a "frozen
            // resort" UI bug that's hard to track down).
            fatalError("ContentCoordinator: resortManager accessed before bind(resortManager:)")
        }
        return r
    }

    /// Held so a resort switch can cancel an in-flight `currentConditions +
    /// mergeHourly` fetch for the previous resort. Without this, rapid
    /// resort-hopping fanned out concurrent tasks whose late results would
    /// stomp on the new resort's weather.
    @ObservationIgnored var conditionsTask: Task<Void, Never>?

    /// Historical-archive fetch debounce — avoids spamming archive
    /// requests while the user is mid-drag on the scrubber.
    @ObservationIgnored var historicalTask: Task<Void, Never>?

    /// Stamped on each `scenePhase != .active` transition; used to decide
    /// whether an `.inactive → .active` hop has been long enough to warrant
    /// a full realtime + weather refresh.
    @ObservationIgnored var lastActiveAt: Date?

    /// Snapshot of the friend ID set — used to detect unfriends so we can
    /// evict their last-known location from the realtime cache + on-disk
    /// store. Without this, an unfriended user's dot would reappear at the
    /// next cold launch when the store rehydrates.
    @ObservationIgnored private var knownFriendIds: Set<UUID> = []

    @ObservationIgnored var cachedGhostBucket: Int = 0
    @ObservationIgnored var cachedGhostSessionId: UUID?

    static let ghostCacheBucketSeconds: TimeInterval = 30

    static let ghostTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        return f
    }()

    // MARK: - Init / binding

    init() {
        self.realtime = RealtimeBootstrapper(
            friendService: friendService,
            locationManager: locationManager,
            locationHistory: locationHistory
        )
        self.meetup = MeetupSessionController()
        // Back-pointer set after `self` is fully constructed.
        self.meetup.coordinator = self
    }

    /// Inject the environment-scoped `ResortDataManager`. Call once from
    /// the view's `.task` before invoking any other coordinator method
    /// that touches the graph.
    func bind(resortManager: ResortDataManager) {
        self.resortManagerRef = resortManager
        // Realtime bootstrapper resolves inbound-broadcast nodes against
        // whatever graph the resort manager has loaded. Closure form so
        // resort switches don't require re-wiring; a stale `MountainGraph`
        // reference would silently route friend dots to the previous
        // resort's nodes.
        realtime.resortGraphProvider = { [weak self] in self?.resortManagerRef?.currentGraph }
        // Live recorder owns its own state machine; we just hand it
        // the three things it needs and `start()` once we know the
        // user has the feature on. The fix-pump comes through
        // `handleLocationChange` (`onChange(of: fixGeneration)`).
        if liveRunRecorder == nil {
            liveRunRecorder = LiveRunRecorder(
                supabase: SupabaseManager.shared,
                resortManager: resortManager,
                locationManager: locationManager
            )
        }
        // Audit Phase 2.1 — feed live conditions into the recorder so
        // each persisted run carries an authoritative bucketed
        // fingerprint. Closure form so no resort-switch reseating is
        // needed; the recorder reads through it at flush time.
        liveRunRecorder?.conditionsProvider = { [weak self] in self?.resortConditions }
        startLiveRecordingIfEnabled()
    }

    /// Gate on the user-level toggle. Idempotent: safe to call from
    /// `bind`, scenePhase resume, and the toggle row in the Profile
    /// tab — `LiveRunRecorder.start()` is itself idempotent.
    func startLiveRecordingIfEnabled() {
        guard let recorder = liveRunRecorder else { return }
        let enabled = SupabaseManager.shared.currentUserProfile?.liveRecordingEnabled ?? true
        if enabled {
            recorder.start()
        } else {
            recorder.stop()
        }
    }

    /// Stop the recorder — flushes any in-progress run before
    /// shutting down. Used on scenePhase background and on teardown.
    func stopLiveRecording() {
        liveRunRecorder?.stop()
    }

    // MARK: - Lazy lifecycle services

    /// Pass-through to `realtime.ensureLocation()`. Kept so the rest of
    /// the coordinator and any future caller can use a familiar name.
    @discardableResult
    func ensureRealtimeLocationService() -> RealtimeLocationService {
        realtime.ensureLocation()
    }

    /// Pass-through to `realtime.ensurePresence(using:)`.
    @discardableResult
    func ensurePresenceCoordinator(using rtl: RealtimeLocationService) -> PresenceCoordinator {
        realtime.ensurePresence(using: rtl)
    }

    // Conditions pipeline lives in ContentCoordinator+Conditions.swift.

    // MARK: - Resort change pipeline

    /// Run the full pipeline on `selectedEntry` change — clears
    /// per-resort UI state, cancels in-flight fetches, kicks the resort
    /// load + presence coordinator + conditions fetch.
    func handleSelectedEntryChange(to entry: ResortEntry?) {
        resortConditions = nil
        meetingResult = nil
        // Test location is keyed to the previous resort's graph — clear it
        // so the LOCATION card doesn't display a raw cross-resort node id.
        testMyNodeId = nil
        locationManager.gpsStickyGraphNodeId = nil
        // Snap the timeline scrubber back to "now" on every resort change.
        // Without this, switching from a resort the user was reviewing in
        // the past to a fresh resort would surface stale weather/sun for
        // the new mountain at whatever scrubbed instant. Live state is
        // the only sensible default for a freshly-loaded resort.
        // (`isScrubbingTimeline` lives on ContentView's @State; the
        // .onChange handler there has its own reset path.)
        selectedTime = Date.now
        // Clear active meetup when changing resort — routes are resort-specific.
        if let sessionId = activeMeetSession?.id {
            Task { try? await meetRequestService.cancelRequest(sessionId) }
        }
        activeMeetSession = nil
        // Cancel any in-flight weather fetch for the old resort — its
        // result is now irrelevant. `loadConditions(for:)` will start
        // a new task below if we have a new entry.
        conditionsTask?.cancel()
        conditionsTask = nil

        guard let entry else {
            presenceCoordinator?.stop()
            locationManager.gpsStickyGraphNodeId = nil
            // Clear current resort in DB
            Task { try? await SupabaseManager.shared.setCurrentResortId(nil) }
            return
        }

        Task { await resortManager.loadResort(entry) }
        loadConditions(for: entry)

        let rtl = ensureRealtimeLocationService()
        let coord = ensurePresenceCoordinator(using: rtl)
        // Fire-and-forget: coordinator sequences snapshot → subscribe →
        // `.live`, and suppresses `broadcastNow` until `.live` so peers
        // never see a pre-snapshot position. Rapid re-entry is safe —
        // the coordinator's enterGeneration cancels the prior pipeline.
        coord.enter(resortId: entry.id)

        // Start the friend signal-quality ticker (Phase 8.3). A 30s tick
        // reclassifies each friend as live / stale / cold based on their
        // last-seen timestamp.
        friendQualityStore.start { [weak rtl] in
            rtl?.friendLocations ?? [:]
        }
        // Persist current resort so friends can see we're here
        Task { try? await SupabaseManager.shared.setCurrentResortId(entry.id) }
    }

    /// Graph was replaced (resort swap or background enrichment). Re-locks
    /// sticky snap on the new graph so labels don't jump to a different
    /// trail at the same GPS coordinate. Returns `true` if the caller
    /// should drop a stale `selectedTrailEdgeId` (no graph entry for it
    /// in the new tree).
    func graphChangedShouldDropEdgeSelection(_ edgeId: String?) -> Bool {
        let drop = edgeId.map { resortManager.currentGraph?.representativeEdge(for: $0) == nil } ?? false
        locationManager.gpsStickyGraphNodeId = nil
        syncStickyGpsNodeWithLocationGraph()
        return drop
    }

    // MARK: - Friend ID change (unfriend eviction)

    /// Compares the new friend-id set to the cached `knownFriendIds` and
    /// evicts removed friends from the realtime cache + disk store. New
    /// friends trigger a `refreshPeersFromLivePresenceTable` so their
    /// last-known dot appears immediately.
    func handleFriendIdsChange(newIds: [UUID]) {
        let currentSet = Set(newIds)
        let removed = knownFriendIds.subtracting(currentSet)
        let added = currentSet.subtracting(knownFriendIds)
        for userId in removed {
            realtimeLocation?.removeFriend(userId)
        }
        if !added.isEmpty {
            Task { await realtimeLocation?.refreshPeersFromLivePresenceTable() }
        }
        knownFriendIds = currentSet
    }

    // MARK: - Test node override

    /// Reacts to a test-location pin being set/cleared. When set, GPS
    /// sticky snap is suspended so the test node doesn't fight live GPS;
    /// when cleared, sticky reattaches to the current graph. Then
    /// pushes the override into the realtime broadcast so friends see
    /// our test position immediately.
    func handleTestMyNodeIdChange(newId: String?) {
        if newId != nil {
            locationManager.gpsStickyGraphNodeId = nil
        } else {
            syncStickyGpsNodeWithLocationGraph()
        }
        if let nodeId = newId,
           let node = resortManager.currentGraph?.nodes[nodeId] {
            realtimeLocation?.testLocationOverride = (coordinate: node.coordinate, nodeId: nodeId)
        } else {
            realtimeLocation?.testLocationOverride = nil
        }
        Task { await presenceCoordinator?.broadcastNow(force: true) }
    }

    // MARK: - Selected time (timeline scrubber)

    /// Scrub-time changed — refresh the ghost cache (skips when the
    /// 30s bucket and session id are unchanged) and kick a historical
    /// archive fetch if we've scrolled into the far past.
    func handleSelectedTimeChange(_ newTime: Date) {
        refreshGhostCache(force: false)
        maybeLoadHistoricalConditions(for: newTime)
    }

    // MARK: - Location change

    /// Driven from the view's `onChange(of: locationManager.fixGeneration)`
    /// — `fixGeneration` increments on every accepted fix, so this fires
    /// even on pure-longitude moves and quantised duplicates that
    /// produce the same `Double` bit-pattern twice.
    func handleLocationChange() {
        guard let coord = locationManager.currentLocation else { return }

        syncStickyGpsNodeWithLocationGraph()

        // Live run recorder hook — passively segment runs/lifts from
        // every fix while the user is skiing with the app open. The
        // recorder gates internally on the profile's
        // `liveRecordingEnabled` flag, so calling unconditionally is
        // safe.
        liveRunRecorder?.ingestCurrentFix()

        // Every GPS fix should hit the wire immediately — non-forced
        // `broadcastNow` coalesces up to 2s when "idle", which feels broken
        // for a live friend-tracking product.
        Task { await presenceCoordinator?.broadcastNow(force: true) }

        // Only auto-snap to a nearby resort if the user hasn't deliberately
        // picked one yet. Driving past another resort on your way to the
        // one you picked should NOT yank you out of your selection.
        if !userManuallyPickedResort {
            let candidates = ResortEntry.catalog.filter { $0.bounds.contains(coord) }
            if let closest = candidates.min(by: { a, b in
                let ax = a.coordinate.latitude  - coord.latitude
                let ay = a.coordinate.longitude - coord.longitude
                let bx = b.coordinate.latitude  - coord.latitude
                let by = b.coordinate.longitude - coord.longitude
                return (ax * ax + ay * ay) < (bx * bx + by * by)
            }), closest.id != selectedEntry?.id {
                selectedEntry = closest
            }
        }

        if let myId = SupabaseManager.shared.currentSession?.user.id {
            locationHistory.append(userId: myId, coordinate: coord)
        }

        guard let session = activeMeetSession,
              let tracker = session.routeTracker else { return }

        if let event = tracker.update(location: coord) {
            navigationDirector?.handle(event, currentLocation: coord)
            switch event {
            case .advanced, .skippedAhead:
                navigationViewModel?.recompute()
            case .completed:
                routeChoreographer?.playArrival()
                let meetingNodeId = session.meetingNodeId
                let nodeLabel: String = {
                    if let graph = resortManagerRef?.currentGraph,
                       graph.nodes[meetingNodeId] != nil {
                        return MountainNaming(graph).nodeLabel(meetingNodeId, style: .canonical)
                    }
                    return "MEETING POINT"
                }()
                Task { @MainActor in
                    Notify.shared.post(.meetArrival(at: nodeLabel))
                }
            case .deviated:
                Task { await meetup.reroute() }
            }
        }

        guard let estimator = etaEstimator else { return }
        var remaining: Double = 0
        for edge in tracker.path[tracker.currentEdgeIndex...] {
            remaining += edge.attributes.lengthMeters
        }
        estimator.ingest(location: coord, timestamp: Date(), remainingMeters: remaining)
        let now = Date()
        if estimator.shouldBroadcast(now: now) {
            let sessionId = session.id
            let eta = estimator.smoothedETASeconds
            Task {
                // Commit the broadcast baseline ONLY on successful network
                // send. Previously we called `didBroadcast(now:)` eagerly,
                // which advanced the rate-limit state even if the request
                // failed — so the next fix was silenced for the 5s cooldown
                // and the partner could receive nothing for 15s+ after a
                // transient failure. `updateETAReportingSuccess` returns
                // `true` only when the server update landed.
                let ok = await meetRequestService.updateETAReportingSuccess(
                    requestId: sessionId,
                    newTimeA: eta,
                    newTimeB: nil
                )
                if ok {
                    await MainActor.run {
                        estimator.didBroadcast(now: now)
                    }
                }
            }
        }
    }

    // MARK: - Scene phase resume

    /// Decides whether an `.inactive → .active` hop has been long enough
    /// to warrant a full realtime + weather refresh. Short overlays
    /// (Siri, Face ID, Control Center) drop to `.inactive` for seconds;
    /// those don't need a reconnect. Long-aways (background, or > 15s
    /// inactive) re-run the social snapshot, re-seat the presence
    /// pipeline, force a broadcast, and re-subscribe meet/friend
    /// realtime channels.
    func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        if newPhase != .active {
            lastActiveAt = Date()
        }
        // Pause the live recorder on background — without an active
        // foreground we'd be storing fixes the user might never want
        // turned into runs (the lock-screen pocket-tap problem). On
        // resume below we re-start (idempotent) so a returning skier
        // picks back up where they left off.
        if newPhase == .background {
            stopLiveRecording()
        }
        guard newPhase == .active else { return }
        startLiveRecordingIfEnabled()

        let wasLongAway: Bool
        if oldPhase == .background {
            wasLongAway = true
        } else if let t = lastActiveAt {
            wasLongAway = Date().timeIntervalSince(t) > 15
        } else {
            wasLongAway = false
        }
        guard wasLongAway else { return }

        Task { [weak self] in
            guard let self else { return }
            // Atomic snapshot refresh on resume — replaces the old
            // parallel loadFriends + loadPending split.
            await self.friendService.loadSocialSnapshot(resortId: self.selectedEntry?.id)
            if let entry = self.selectedEntry {
                let rtl = self.ensureRealtimeLocationService()
                let coord = self.ensurePresenceCoordinator(using: rtl)
                if coord.phase != .live || rtl.currentResortId != entry.id {
                    coord.enter(resortId: entry.id)
                    await coord.waitForEnter()
                }
                await coord.reconnectLiveTransport(resortId: entry.id)
            }
            await self.presenceCoordinator?.broadcastNow(force: true)
            await self.meetRequestService.startListening(forceReconnect: true)
            await self.friendService.startRealtimeSubscription()
        }
        if let entry = selectedEntry {
            Task {
                let age = await ConditionsService.shared.cacheAgeSeconds(for: entry) ?? .infinity
                guard age > 30 * 60 else { return }
                await ConditionsService.shared.invalidateCache(for: entry)
                self.loadConditions(for: entry)
            }
        }
    }

    // MARK: - Bootstrap (cold launch)

    /// First-launch initialization. Runs inside the view's `.task` so it
    /// inherits cancellation when the view disappears. Order:
    ///   1. GPS auto-detect resort (only if no entry is set yet).
    ///   2. Wire `meetRequestService` callbacks for accept/cancel events.
    ///   3. Load sent + incoming requests (in parallel) BEFORE starting
    ///      the listener so the realtime handler can match request ids
    ///      even if the app was restarted mid-flow.
    ///   4. Start meet polling + listening.
    ///   5. Parallel: load resort graph (if entry already known) +
    ///      atomic social snapshot.
    ///   6. Subscribe friend realtime, prefetch avatars, auto-present
    ///      picker if still no entry after 1.2s.
    ///   7. Run friend-profile polling loop until cancellation.
    ///
    /// `onAutoPresentResortPicker` lets the view pop its picker sheet —
    /// `showResortPicker` is pure UI state and stays on the view.
    func bootstrap(onAutoPresentResortPicker: @escaping () -> Void) async {
        if selectedEntry == nil {
            // Auto-detect resort from GPS only if the user is actually at
            // one right now. No GPS match → leave `selectedEntry` nil so
            // the "PICK A MOUNTAIN" overlay surfaces instead of silently
            // loading an arbitrary catalog entry (which looked like the
            // app had opened to a random resort).
            if let coord = locationManager.currentLocation {
                let candidates = ResortEntry.catalog.filter { $0.bounds.contains(coord) }
                if let closest = candidates.min(by: { a, b in
                    let ax = a.coordinate.latitude  - coord.latitude
                    let ay = a.coordinate.longitude - coord.longitude
                    let bx = b.coordinate.latitude  - coord.latitude
                    let by = b.coordinate.longitude - coord.longitude
                    return (ax * ax + ay * ay) < (bx * bx + by * by)
                }) {
                    selectedEntry = closest
                }
            }
        }

        // [weak self]: the coordinator owns `meetRequestService`, which
        // retains these callbacks — without weak we'd loop
        // coordinator → service → callback → coordinator.
        meetRequestService.onRequestAccepted = { [weak self] request in
            Task { await self?.activateRoute(for: request) }
        }
        meetRequestService.onMeetupCancelled = { [weak self] requestId in
            self?.handleMeetupCancelledByOther(requestId: requestId)
        }
        // Load sent + incoming in parallel before starting listener so the
        // realtime handler can match requests even if the app was restarted.
        async let sentLoad: () = meetRequestService.loadSent()
        async let incomingLoad: () = meetRequestService.loadIncoming()
        _ = await (sentLoad, incomingLoad)
        meetRequestService.startPolling()
        await meetRequestService.startListening()

        let entryToLoad = selectedEntry
        async let resortLoad: () = {
            if let entry = entryToLoad {
                await self.resortManager.loadResort(entry)
            }
        }()
        // Atomic social snapshot (friends + both pending buckets in one
        // transaction) replaces the legacy parallel loadFriends +
        // loadPending. See CLAUDE.md — social snapshot gate.
        async let snapshotLoad: () = {
            _ = await self.friendService.loadSocialSnapshot(resortId: entryToLoad?.id)
        }()
        _ = await (resortLoad, snapshotLoad)

        await friendService.startRealtimeSubscription()

        prefetchAvatars()

        // NOTE: conditions are fetched via `handleSelectedEntryChange`
        // which fires when the GPS auto-detect above sets the entry, or
        // when the resort picker sheet dismisses. Triggering a second
        // `loadConditions` from here raced the first for the same resort
        // — wasteful and occasionally landed stale results on top of
        // fresher ones.

        // First-launch picker auto-present: if GPS still hasn't resolved
        // to a catalog resort after a ~1.2s grace period, pop the picker
        // once so the user has a clear call-to-action instead of staring
        // at the "PICK A MOUNTAIN" overlay.
        if selectedEntry == nil && !didAutoPresentResortPicker {
            try? await Task.sleep(for: .milliseconds(1200))
            if selectedEntry == nil && !didAutoPresentResortPicker {
                didAutoPresentResortPicker = true
                onAutoPresentResortPicker()
            }
        }

        // Same task as above — cancellation propagates when the view goes
        // away (unstructured Task { } would not).
        await runFriendProfilePollingLoop()
    }

    /// Friend profile refresh — runs inside `bootstrap` so it stops when
    /// the view (and so the coordinator's bootstrap task) is torn down.
    private func runFriendProfilePollingLoop() async {
        while !Task.isCancelled {
            let interval: Duration = friendService.pendingSent.isEmpty ? .seconds(30) : .seconds(2)
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { break }
            _ = await friendService.loadSocialSnapshot(resortId: selectedEntry?.id)
        }
    }

    // MARK: - Teardown (sign-out / account-delete)

    /// Called from `ContentView.onDisappear` when the user signs out or
    /// deletes their account. Tear down all realtime services so stale
    /// channels don't linger and conflict with a new account.
    ///
    /// Order matters:
    ///   1. Synchronously cancel anything that produces state (realtime
    ///      broadcasts, ticker) so no more writes land after we clear
    ///      local caches.
    ///   2. Inside an async Task (guarded by sessionGeneration so we
    ///      skip if the user signed back in already):
    ///        a. Await channel teardown (friendService, meetRequestService)
    ///           so channels are provably released before…
    ///        b. clear friendService's in-memory caches. Previously
    ///           `friendService.reset()` ran synchronously while realtime
    ///           tasks were still being cancelled, so a racing
    ///           postgres_changes event could repopulate `friends` /
    ///           `pendingReceived` after the reset.
    func teardown() {
        AppLog.meet.debug("teardown — tearing down realtime services")
        let teardownGen = SupabaseManager.shared.sessionGeneration
        conditionsTask?.cancel()
        conditionsTask = nil
        // Flush any in-progress run before we tear realtime services
        // down — sign-out should not silently lose the run that was
        // half in the buffer.
        stopLiveRecording()
        realtime.teardown()
        friendQualityStore.stop()
        Task { [weak self] in
            guard let self else { return }
            guard SupabaseManager.shared.sessionGeneration == teardownGen else {
                AppLog.meet.debug("teardown task stale (gen=\(teardownGen), now=\(SupabaseManager.shared.sessionGeneration)) — skipping")
                return
            }
            await self.friendService.stopRealtimeSubscription()
            await self.meetRequestService.reset()
            // Only reset local caches AFTER realtime channels are gone so
            // a late postgres_changes event can't re-populate the caches.
            self.friendService.reset()
        }
    }

    // MARK: - End meetup (pass-throughs to MeetupSessionController)

    func endActiveMeetup() {
        meetup.endActiveMeetup()
    }

    private func handleMeetupCancelledByOther(requestId: UUID) {
        meetup.handleMeetupCancelledByOther(requestId: requestId)
    }

    // MARK: - Avatar prefetch

    private func prefetchAvatars() {
        var urls: [URL] = []
        if let urlStr = SupabaseManager.shared.currentUserProfile?.avatarUrl,
           let url = URL(string: urlStr) {
            urls.append(url)
        }
        for friend in friendService.friends {
            if let urlStr = friend.avatarUrl, let url = URL(string: urlStr) {
                urls.append(url)
            }
        }
        for url in urls {
            Task.detached(priority: .background) {
                _ = try? await URLSession.shared.data(from: url)
            }
        }
    }

    // Ghost-position computation lives in ContentCoordinator+Ghosts.swift.

    // MARK: - Navigation services (pass-through to MeetupSessionController)

    func syncNavigationServices() {
        meetup.syncNavigationServices()
    }

    /// Updates `locationManager.gpsStickyGraphNodeId` from GPS + graph
    /// (no-op when a manual picker pin is active).
    func syncStickyGpsNodeWithLocationGraph() {
        if testMyNodeId != nil {
            locationManager.gpsStickyGraphNodeId = nil
            return
        }
        guard let coord = locationManager.currentLocation,
              let graph = resortManager.currentGraph else {
            locationManager.gpsStickyGraphNodeId = nil
            return
        }
        let next = graph.nearestNodeSticky(
            to: coord,
            previousNodeId: locationManager.gpsStickyGraphNodeId
        )
        locationManager.gpsStickyGraphNodeId = next?.id
    }

    // MARK: - Activate route (pass-throughs to MeetupSessionController)

    func activateRoute(for request: MeetRequest) async {
        await meetup.activateRoute(for: request)
    }

    func activateRouteAsReceiver(for request: MeetRequest) async {
        await meetup.activateRouteAsReceiver(for: request)
    }


    // MARK: - Computed view helpers

    /// User location snapped to the nearest graph node so the blue dot
    /// aligns with where the solver actually routes from.
    ///
    /// Priority matches `resolveMyNodeId`: live GPS at this resort wins
    /// over the tester pick. If GPS is far from the resort (nearestNode
    /// returns nil per its 1000m cap), we fall through to the tester pick;
    /// if neither is available, the dot is hidden — viewing the resort
    /// without being there is supported.
    var snappedUserLocation: CLLocationCoordinate2D? {
        if let sticky = locationManager.gpsStickyGraphNodeId,
           let node = resortManagerRef?.currentGraph?.nodes[sticky] {
            return node.coordinate
        }
        if let rawCoord = locationManager.currentLocation,
           let graph = resortManagerRef?.currentGraph,
           let node = graph.nearestNode(to: rawCoord) {
            return node.coordinate
        }
        if let testId = testMyNodeId,
           let node = resortManagerRef?.currentGraph?.nodes[testId] {
            return node.coordinate
        }
        // No GPS at resort, no tester pick — return nil so the map hides
        // the dot rather than placing it at the user's literal GPS coord
        // (which could be hundreds of km away from the displayed resort).
        return nil
    }

    /// True when the timeline is scrolled to a past time and we have
    /// history data.
    var isShowingReplay: Bool {
        selectedTime < Date() && locationHistory.timeRange != nil
    }

    /// Show a short banner. Caller can call again to overwrite — the prior
    /// auto-clear is cancelled and a new one starts. Pass `nil` to clear
    /// immediately.
    func setTransientMessage(_ message: String?) {
        transientMessageClearTask?.cancel()
        transientMessage = message
        guard message != nil else { return }
        transientMessageClearTask = Task { [weak self, transientMessageDurationSeconds] in
            try? await Task.sleep(for: .seconds(transientMessageDurationSeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Only clear if it's still the same message we set —
                // a newer setTransientMessage would have cancelled this
                // task, but be defensive in case the cancellation lost
                // the race with a subsequent set.
                if self.transientMessage == message { self.transientMessage = nil }
            }
        }
    }

    func replayTrails(upTo date: Date) -> [UUID: [CLLocationCoordinate2D]] {
        var result: [UUID: [CLLocationCoordinate2D]] = [:]
        for userId in locationHistory.trackedUserIds {
            let crumbs = locationHistory.trail(for: userId, since: nil)
                .filter { $0.timestamp <= date }
            if crumbs.count >= 2 {
                result[userId] = crumbs.map(\.coordinate)
            }
        }
        return result
    }

    /// Upper bound for the timeline scrubber when a meetup is running —
    /// `startedAt + max(ETA A, ETA B) + 5 min` so the user can scrub
    /// past "now" and see where each skier is expected to be at arrival
    /// time. `nil` when no meetup is active; `TimelineView` falls back
    /// to its default ±12h window.
    var activeMeetupFutureRangeMax: Date? {
        guard let session = activeMeetSession else { return nil }
        return session.startedAt.addingTimeInterval(session.meetingResult.maxTime + 5 * 60)
    }
}
