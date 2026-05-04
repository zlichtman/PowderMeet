//
//  RealtimeLocationService.swift
//  PowderMeet
//
//  Phase B transport: per-user position rides over Supabase Realtime *broadcast*
//  events on a geohash-6 cell channel (≈1.2km × 0.6km tiles), not per-resort
//  Presence. Why: at 300+ users on the same resort, Presence creates a join
//  + leave event per fix and fans out the full member list to every device.
//  Broadcast is fire-and-forget and per-cell, so ride traffic is bounded by
//  who's literally on your lift, not the whole mountain.
//
//  Persistence: every accepted broadcast also upserts into the `live_presence`
//  table (throttled to ≤1/30s) so a freshly-launched friend can hydrate from
//  REST without waiting for the next broadcast tick. The on-disk
//  `FriendLocationStore` is a third tier for the same reason: it survives app
//  kill, the table doesn't.
//
//  Backwards compatibility: the public surface (`start(resortId:)`,
//  `friendLocations`, `friendsPresent`, `broadcastNow()`, `stop()`) is
//  unchanged so existing callers don't move. The transport underneath is new.
//

import Foundation
import CoreLocation
import Observation
import Supabase
import UIKit

/// Holds a `NotificationCenter` token and removes it on deinit so
/// `RealtimeLocationService` does not need a `deinit` that reads MainActor state.
private final class NotificationCenterObservationLifetime {
    private let token: NSObjectProtocol

    init(name: Notification.Name, handler: @escaping (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main,
            using: handler
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor @Observable
final class RealtimeLocationService {
    private let supabase: SupabaseManager
    private let locationManager: LocationManager
    private let registry: ChannelRegistry

    private var heartbeatTask: Task<Void, Never>?
    private var isConnecting = false

    /// Resort scope this service is currently broadcasting under. Used to
    /// short-circuit duplicate `start(resortId:)` and to compute the cell.
    private(set) var currentResortId: String?

    /// After a real `didEnterBackground`, the next `willEnterForeground` rewires
    /// `pos:*` broadcast listeners — the socket can come back without deliveries.
    private var shouldReconnectPositionChannelsAfterBackground = false
    /// Background notification observer; unregistered when this reference drops.
    private var backgroundLifecycleObserver: NotificationCenterObservationLifetime?

    /// The geohash-6 cell + 8 neighbors we're subscribed to right now. We
    /// resubscribe only when our own cell changes (rare during a ski day —
    /// roughly once per lift to summit), not per fix.
    private var subscribedCells: Set<String> = []
    /// Resort-wide fallback channel we're holding (if any). Name is
    /// `pos:resort:{resortId}`. Used in addition to the per-cell geohash
    /// channels so two friends at the same mountain always see each other
    /// even when they're further apart than the 9-cell cell neighborhood
    /// covers (the test picker's cross-mountain jumps are the obvious case).
    private var subscribedResortChannel: String?

    /// Re-entry guard for `ensureSubscribedToCell`. MainActor re-entrancy lets
    /// two broadcast ticks interleave across the `await registry.acquire(...)`
    /// suspension, so both see `subscribedCells` empty and each subscribe all
    /// 9 cells. Serialize the ensure-subscription work instead.
    private var pendingCellSubscription: Task<Void, Never>?
    private var cellSubscriptionGeneration: UInt64 = 0

    /// Optional location history store for timeline replay.
    var locationHistory: LocationHistoryStore?

    /// On-disk last-known cache. Hydrated into `friendLocations` on init so the
    /// map is never empty at cold launch when there's prior knowledge.
    private let persistentStore: FriendLocationStore?

    /// Friend ID → latest known position. Combines: (1) hydrated from disk on
    /// init, (2) live broadcast updates, (3) REST hydration from live_presence
    /// on first subscribe.
    var friendLocations: [UUID: FriendLocation] = [:]

    /// Friends seen on broadcast within the last `presenceTTL`. Replaces the
    /// old Presence-derived set — derived locally from broadcast freshness.
    var friendsPresent: Set<UUID> = []
    private let presenceTTL: TimeInterval = 90  // seconds without a packet → drop from "present"

    struct FriendLocation: Sendable {
        let userId: UUID
        let displayName: String
        let latitude: Double
        let longitude: Double
        /// Sender-stamped capture time. Receivers compare against stored value
        /// to drop out-of-order deliveries — never overwrite fresh with stale.
        let capturedAt: Date
        /// Graph node ID resolved by the friend from their own local GPS.
        /// Using this instead of re-resolving from broadcast GPS ensures both
        /// users share identical node IDs → identical meeting point results.
        let nearestNodeId: String?
        /// GPS horizontal accuracy in meters. Receivers render this as a halo
        /// around the dot rather than gating low-accuracy fixes out entirely.
        let accuracyMeters: Double?

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Slim broadcast payload (~80 bytes JSON). Identity (displayName) lives
    /// in the `profiles` table; clients cache it, so no need to ship it on
    /// every position packet. We do include it as a fallback for first contact
    /// before the cache hydrates.
    struct PositionPayload: Codable, Sendable {
        let u: String       // userId uuid
        let n: String?      // displayName (optional — receiver may already cache it)
        let lat: Double
        let lon: Double
        let at: Double      // captured_at unix epoch seconds
        let node: String?   // nearest graph node id (sender-resolved)
        let acc: Double?    // accuracy meters
        let r: String       // resort id (so cross-cell leakage is filterable)
    }

    /// Resolves a coordinate to the nearest graph node ID.
    /// Set by the parent view when the resort graph is loaded.
    var nodeResolver: (@MainActor (CLLocationCoordinate2D) -> String?)?

    /// Returns the set of accepted-friend user IDs. Broadcasts from non-friends
    /// are dropped (the geohash cell channel is shared by everyone nearby, not
    /// just friends — RLS protects the `live_presence` table read path, but
    /// broadcast is unauthenticated). Set by ContentView from `FriendService`.
    ///
    /// Contract:
    /// - `friendIdsProvider == nil`: provider never wired (legacy / tests) —
    ///   no friend filtering. **Do not rely on this in production paths.**
    /// - `provider() == nil`: social snapshot has not applied yet
    ///   (`socialGeneration == 0`). Payload is **rejected** — closes the
    ///   "accept-everyone-during-cold-launch" window per `CLAUDE.md`
    ///   (social snapshot gate).
    /// - `provider() == some(set)`: snapshot applied. Payload accepted only
    ///   when `set.contains(friendId)`. Empty set → reject all (user has
    ///   zero friends).
    var friendIdsProvider: (@MainActor () -> Set<UUID>?)?

    /// When set (by `ContentView` after `PresenceCoordinator` exists), position
    /// sends are allowed only while `phase == .live`. This closes the hole where
    /// `onFirstFix` / the heartbeat / foreground hooks call `broadcastNow()`
    /// directly on this service and could publish before social hydrate +
    /// channel subscribe finish. When `nil` (DEBUG selftests, legacy wiring),
    /// broadcasts are not gated here.
    weak var presenceGateCoordinator: PresenceCoordinator?

    /// Maps friend UUIDs → display names. Used to back-fill names on hydrated
    /// rows (the `live_presence` table doesn't store names) and on broadcasts
    /// that omit the `n` field to save bandwidth. Without this, the friend
    /// dot renders "?" initials until a full-payload broadcast arrives.
    var friendNameProvider: (@MainActor (UUID) -> String?)?

    /// Override for testing: when set, broadcasts this coordinate + node ID
    /// instead of real GPS. Ensures friends see the same test position.
    /// `force: true` on the broadcast so a rapid test-picker change isn't
    /// swallowed by the 500 ms debounce in `broadcastNow`.
    /// Assign from UI; does **not** auto-broadcast — `ContentView` calls
    /// `PresenceCoordinator.broadcastNow(force:)` so sends respect `.live` gating.
    var testLocationOverride: (coordinate: CLLocationCoordinate2D, nodeId: String)?

    /// Broadcast cadence + double-write throttle. Broadcast is a
    /// **trailing-edge coalescer** — a caller firing within the min-interval
    /// never gets silently dropped. Instead, we schedule exactly one pending
    /// task that fires when the cooldown expires and reads the **latest**
    /// GPS state at that moment. This guarantees peers always see our most
    /// recent position within `minBroadcastInterval` of the fix, even under
    /// bursty input (chairlift jitter, rapid re-renders, etc).
    ///
    /// The base interval is 250 ms at speed; when the user is sitting still
    /// we stretch to `idleBroadcastInterval` (2 s) to save battery. See
    /// `currentBroadcastInterval()` for the speed-adaptive rule.
    private var lastBroadcastAt: Date = .distantPast
    private let minBroadcastInterval: TimeInterval = 0.12
    private let idleBroadcastInterval: TimeInterval = 0.85
    /// Speed (m/s) at or above which we use the tight 250 ms cadence. Below
    /// this we assume the user is on a chairlift or stationary and drop to
    /// `idleBroadcastInterval`. 1.5 m/s ≈ brisk walk; comfortably above GPS
    /// idle noise so a stationary user doesn't flip-flop between rates.
    private let movingSpeedThreshold: CLLocationSpeed = 1.0
    /// Pending trailing-edge broadcast task. Held so a second broadcast
    /// request during the cooldown reuses this task instead of stacking.
    private var pendingBroadcastTask: Task<Void, Never>?
    /// If a broadcast request comes in during cooldown we flip this flag —
    /// the pending task reads it when it fires and, if set, honours the
    /// newer request with a fresh GPS snapshot.
    private var pendingBroadcastNeedsFlush = false
    private var lastTableUpsertAt: Date = .distantPast
    nonisolated static let minTableUpsertInterval: TimeInterval = 30

    /// Pure decision function for the live_presence write throttle. Exposed so
    /// the DEBUG selftest can verify the rule without touching live state.
    nonisolated static func shouldUpsertLivePresence(
        now: Date,
        lastUpsertAt: Date,
        interval: TimeInterval = minTableUpsertInterval,
        force: Bool = false
    ) -> Bool {
        force || now.timeIntervalSince(lastUpsertAt) >= interval
    }

    /// Listens for `UIApplication.willEnterForegroundNotification` and triggers
    /// a forced rebroadcast so a returning user re-establishes liveness within
    /// one tick rather than waiting for the 5-second heartbeat. Held as a
    /// separate object so the DEBUG selftest can build one in isolation and
    /// verify the wiring.
    private var foregroundResubscriber: ForegroundResubscriber?

    init(supabase: SupabaseManager? = nil,
         locationManager: LocationManager,
         persistentStore: FriendLocationStore? = nil,
         registry: ChannelRegistry? = nil) {
        self.supabase = supabase ?? .shared
        self.locationManager = locationManager
        self.persistentStore = persistentStore
        self.registry = registry ?? ChannelRegistry.shared
        // Hydrate from disk so the map shows the last-known set within
        // milliseconds of cold launch, even before a network connection.
        if let stored = persistentStore?.loadAll() {
            for loc in stored {
                self.friendLocations[loc.userId] = loc
            }
        }
        // Wire first-fix → immediate broadcast so peers see us within ~ms of
        // GPS arrival, not up to 5s later when the periodic re-track ticks.
        locationManager.onFirstFix = { [weak self] in
            Task { @MainActor in await self?.broadcastNow(force: true) }
        }
        // Background → foreground: re-subscribe broadcast channels (socket can
        // reconnect without per-channel listeners), then force-send.
        backgroundLifecycleObserver = NotificationCenterObservationLifetime(
            name: UIApplication.didEnterBackgroundNotification
        ) { [weak self] _ in
            Task { @MainActor in
                self?.shouldReconnectPositionChannelsAfterBackground = true
            }
        }
        foregroundResubscriber = ForegroundResubscriber { [weak self] in
            Task { @MainActor in
                guard let this = self else { return }
                if this.shouldReconnectPositionChannelsAfterBackground,
                   this.currentResortId != nil {
                    this.shouldReconnectPositionChannelsAfterBackground = false
                    await this.reconnectPositionChannelsIfActive()
                }
                await this.broadcastNow(force: true)
            }
        }
    }

    // MARK: - Start / Stop

    /// Join the geohash-6 cell channel for the user's current location and
    /// begin publishing position broadcasts. Idempotent for the same resort.
    func start(resortId: String) async {
        guard let userId = supabase.currentSession?.user.id,
              supabase.currentUserProfile != nil else { return }

        let needResortChannel = Self.resortChannelName(for: resortId)
        if currentResortId == resortId,
           !subscribedCells.isEmpty,
           subscribedResortChannel == needResortChannel {
            AppLog.realtime.debug("already started for resort \(resortId)")
            return
        }
        guard !isConnecting else {
            AppLog.realtime.debug("already connecting, skipping duplicate start")
            return
        }
        isConnecting = true
        defer { isConnecting = false }

        await stopAsync()
        currentResortId = resortId

        // Clear stale cross-resort friend entries from the in-memory cache.
        // `stopAsync` intentionally retains `friendLocations` for last-known
        // display, but when we switch resorts those entries are from the
        // *previous* mountain — keeping them would render friend dots in the
        // wrong place on the new map. `hydrateFromTable` below repopulates
        // from `live_presence` filtered to the new resort.
        friendLocations.removeAll()
        // Also clear the on-disk store. Without this, an app kill mid-switch
        // followed by cold launch would re-hydrate friends from the previous
        // resort and render their dots at the new resort's coordinates.
        persistentStore?.clear()

        // Ski session → background location + Always escalation prompt.
        locationManager.startSession()
        locationManager.requestAlwaysPermission()

        // Hydrate friends from `live_presence` table immediately so the map
        // populates before our first broadcast arrives. This is the cold-launch
        // primary signal — disk is the secondary, broadcast is for liveness.
        await hydrateFromTable(userId: userId, resortId: resortId)

        // Subscribe to the cell channel based on whatever location we have
        // right now (real GPS, test override, or — fallback — the resort
        // centroid via nodeResolver hint). If GPS hasn't arrived, we'll
        // resubscribe on first fix via the broadcastNow path's cell check.
        if let coord = currentCoordinate() {
            await ensureSubscribedToCell(of: coord, resortId: resortId)
        }

        // Resort-wide fallback channel. The per-cell geohash channels cap
        // traffic at chairlift density, but they also mean two friends on
        // the same mountain more than ~1.2 km apart won't see each other
        // — each one's 9-cell neighborhood misses the other. We additionally
        // broadcast + subscribe on `pos:resort:{resortId}` so cross-cell
        // friends (and test-picker jumps to distant nodes) still propagate.
        await ensureSubscribedToResortChannel(resortId: resortId)

        // Heartbeat: tight liveness tick so stationary skiers still push age
        // badges + cell boundary checks without waiting on GPS distanceFilter.
        // Channel rewiring runs **off** the critical path so it never delays a send.
        heartbeatTask = Task { @MainActor [weak self] in
            var tick: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let this = self else { return }
                tick += 1
                if tick % 15 == 0, this.currentResortId != nil {
                    await this.reconnectPositionChannelsIfActive()
                }
                await this.broadcastNow(force: true)
                this.prunePresence()
            }
        }
    }

    /// Drops and re-acquires `pos:cell:*` + `pos:resort:*` channels while
    /// keeping `currentResortId`, the heartbeat loop, and in-memory friend
    /// dots. After a long background, Supabase Realtime can reconnect at the
    /// socket level while per-channel broadcast listeners stop delivering;
    /// switching resort "fixed" this because `start` re-subscribed. Call from
    /// `PresenceCoordinator` only while the presence pipeline is `.live`.
    func reconnectPositionChannelsIfActive() async {
        guard let userId = supabase.currentSession?.user.id,
              let resortId = currentResortId else { return }

        pendingCellSubscription?.cancel()
        pendingCellSubscription = nil
        for cell in subscribedCells {
            await registry.release(name: Self.channelName(for: cell))
        }
        subscribedCells.removeAll()
        if let resortChannel = subscribedResortChannel {
            await registry.release(name: resortChannel)
            subscribedResortChannel = nil
        }

        await hydrateFromTable(userId: userId, resortId: resortId)
        if let coord = currentCoordinate() {
            await ensureSubscribedToCell(of: coord, resortId: resortId)
        }
        await ensureSubscribedToResortChannel(resortId: resortId)
        AppLog.realtime.info("reconnected position broadcast channels resort=\(resortId)")
    }

    /// Send the current position to peers.
    ///
    /// **Never drops silently.** If called inside the cadence cooldown window,
    /// a trailing-edge task is scheduled that fires the moment the window
    /// expires and re-reads the latest GPS state. The public contract is:
    /// "your most recent `broadcastNow()` will hit the wire within one
    /// `currentBroadcastInterval()` of returning, unless a newer call
    /// supersedes it."
    ///
    /// `force: true` bypasses the cooldown and sends immediately. Used for
    /// first-fix, app-foreground, and heartbeat ticks where liveness is
    /// more important than cadence.
    func broadcastNow(force: Bool = false) async {
        guard supabase.currentSession?.user.id != nil,
              supabase.currentUserProfile != nil,
              currentResortId != nil,
              currentCoordinate() != nil else { return }
        guard broadcastsAllowedForCurrentPolicy() else { return }

        let now = Date()
        let interval = currentBroadcastInterval()
        let elapsed = now.timeIntervalSince(lastBroadcastAt)

        if force || elapsed >= interval {
            // Either the caller demanded immediate liveness (force) or the
            // last send is older than the current cadence window — send now
            // and clear any pending trailing task, which is now obsolete.
            pendingBroadcastTask?.cancel()
            pendingBroadcastTask = nil
            pendingBroadcastNeedsFlush = false
            await performBroadcast(force: force)
            return
        }

        // We're inside the cooldown. Mark that a newer request exists — the
        // trailing-edge task (existing or about-to-be-scheduled) will honour
        // it when the window expires. The key property: we never stack
        // multiple tasks, and the task always reads the **latest** GPS
        // state at fire time, so bursts collapse into one send per window.
        pendingBroadcastNeedsFlush = true
        if pendingBroadcastTask != nil { return }

        let delay = max(0, interval - elapsed)
        pendingBroadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let this = self else { return }
            this.pendingBroadcastTask = nil
            guard this.pendingBroadcastNeedsFlush else { return }
            this.pendingBroadcastNeedsFlush = false
            await this.performBroadcast(force: false)
        }
    }

    /// Speed-adaptive cadence rule: tight 250 ms window when the user is
    /// moving (>1.5 m/s, i.e. off a lift / skiing), stretched 2 s window
    /// when stationary. The `onFirstFix` path and the 5 s heartbeat both
    /// use `force: true` so liveness is preserved even when idle.
    private func currentBroadcastInterval() -> TimeInterval {
        let speed = locationManager.currentSpeed
        return speed >= movingSpeedThreshold ? minBroadcastInterval : idleBroadcastInterval
    }

    /// The actual send path. Called by `broadcastNow` and the trailing-edge
    /// task. Always reads the **current** GPS state — never cached — so
    /// coalesced bursts deliver whatever is freshest at fire time.
    private func performBroadcast(force: Bool) async {
        guard broadcastsAllowedForCurrentPolicy() else { return }
        guard let userId = supabase.currentSession?.user.id,
              let profile = supabase.currentUserProfile,
              let resortId = currentResortId,
              let coord = currentCoordinate() else { return }

        let now = Date()
        await ensureSubscribedToCell(of: coord, resortId: resortId)

        let nodeId = resolveNodeId(for: coord)
        let accuracy = locationManager.currentAccuracy >= 0 ? locationManager.currentAccuracy : nil
        let payload = PositionPayload(
            u: userId.uuidString,
            n: profile.displayName,
            lat: coord.latitude,
            lon: coord.longitude,
            at: now.timeIntervalSince1970,
            node: nodeId,
            acc: accuracy,
            r: resortId
        )
        lastBroadcastAt = now

        let cell = Geohash.encode(coordinate: coord, precision: 6)
        let channelName = Self.channelName(for: cell)

        let json: JSONObject
        do {
            let data = try JSONEncoder().encode(payload)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let asJSONObject = try? Self.toJSONObject(obj) else { return }
            json = asJSONObject
        } catch {
            AppLog.realtime.error("payload encode failed: \(error)")
            return
        }

        await registry.sendBroadcast(channelName: channelName, event: "pos", payload: json)

        if let resortChannel = subscribedResortChannel {
            await registry.sendBroadcast(channelName: resortChannel, event: "pos", payload: json)
        }

        if Self.shouldUpsertLivePresence(now: now, lastUpsertAt: lastTableUpsertAt, force: force) {
            lastTableUpsertAt = now
            // Detached because the broadcast already shipped above; the
            // table upsert is a slower durability backup that mustn't
            // block the next position broadcast (which fires every few
            // seconds on a chairlift). Captures a strong reference to
            // `supabase` (a class) so the task is independent of `self`'s
            // lifetime — by the time the upsert completes, the user may
            // have torn down the realtime service for a resort switch,
            // and we still want the row written for cold-launch hydrate.
            // Ordering safety: the next call to `broadcastPosition` (and
            // therefore the next eligible upsert) is gated by
            // `lastTableUpsertAt`, set above on the main actor BEFORE the
            // detach — so we never queue two upserts for the same window.
            // SupabaseManager is `@MainActor` but `client` is Sendable;
            // upsertLivePresence does not touch sessionGeneration, so a
            // late upsert during teardown is harmless.
            Task.detached { [supabase] in
                await Self.upsertLivePresence(
                    supabase: supabase,
                    userId: userId,
                    resortId: resortId,
                    coord: coord,
                    capturedAt: now,
                    accuracy: accuracy
                )
            }
        }
    }

    /// Re-fetch friend rows from `live_presence` for the active resort (e.g.
    /// after the friends list gains a new accepted friend) so their dot appears
    /// from the table before the next broadcast tick.
    func refreshPeersFromLivePresenceTable() async {
        guard let userId = supabase.currentSession?.user.id,
              let resortId = currentResortId else { return }
        await hydrateFromTable(userId: userId, resortId: resortId)
    }

    private func broadcastsAllowedForCurrentPolicy() -> Bool {
        guard let coord = presenceGateCoordinator else { return true }
        return coord.phase == .live
    }

    /// Pull friends' last-known positions from the live_presence table. This is
    /// the hydration path for cold launch — disk gives us last session's data,
    /// the table gives us "what they were doing 30 seconds before I opened."
    ///
    /// Filters by `resort_id` so friends at other mountains don't leak into
    /// our current-resort map. The row set is already friend-only via the
    /// `live_presence_friend_read` RLS policy. We also defensively re-check
    /// each row against the local `friendIdsProvider`:
    ///
    ///   - provider == nil       → no provider wired (legacy / tests), accept
    ///   - provider() == nil     → snapshot not yet loaded (cold launch),
    ///                              accept — this is the deliberate exception:
    ///                              dropping rows during the snapshot-load
    ///                              window would invisibly hide friends and
    ///                              make this path useless on cold start
    ///   - provider() == set     → keep iff the set contains the user_id
    ///
    /// Defense-in-depth: RLS remains the authoritative guard. This catches
    /// the failure mode where RLS regresses (e.g. a future migration loosens
    /// the policy or accidentally includes a stale friendship row) by
    /// matching the `friendIdsProvider`'s in-memory accepted set.
    private func hydrateFromTable(userId: UUID, resortId: String) async {
        do {
            struct Row: Decodable {
                let user_id: UUID
                let lat: Double
                let lon: Double
                let captured_at: Date
                let accuracy_m: Double?
            }
            let rows: [Row] = try await supabase.client
                .from("live_presence")
                .select("user_id, lat, lon, captured_at, accuracy_m")
                .eq("resort_id", value: resortId)
                .neq("user_id", value: userId.uuidString)
                .execute()
                .value

            // Snapshot the provider set once for the loop — calling per-row
            // would round-trip to MainActor for every row.
            let acceptedFriendIds: Set<UUID>? = friendIdsProvider?()

            var kept = 0
            for row in rows {
                // Defensive friend-id check (see method doc).
                if let acceptedFriendIds, !acceptedFriendIds.contains(row.user_id) {
                    continue
                }
                // Monotonic guard against the disk-hydrated entry.
                if let existing = friendLocations[row.user_id], existing.capturedAt >= row.captured_at {
                    continue
                }
                let cached = friendLocations[row.user_id]?.displayName
                let displayName = (cached?.isEmpty == false ? cached : nil)
                    ?? friendNameProvider?(row.user_id)
                    ?? ""
                let loc = FriendLocation(
                    userId: row.user_id,
                    displayName: displayName,
                    latitude: row.lat,
                    longitude: row.lon,
                    capturedAt: row.captured_at,
                    nearestNodeId: nil,
                    accuracyMeters: row.accuracy_m
                )
                friendLocations[row.user_id] = loc
                persistentStore?.upsert(loc)
                kept += 1
            }
            AppLog.realtime.debug("hydrated \(kept) friends from live_presence (resort=\(resortId))")
        } catch {
            // RLS may deny the query before the migration lands — that's fine,
            // we degrade to disk + broadcast hydration only.
            AppLog.realtime.error("live_presence hydrate skipped: \(error.localizedDescription)")
        }
    }

    private static func upsertLivePresence(
        supabase: SupabaseManager,
        userId: UUID,
        resortId: String,
        coord: CLLocationCoordinate2D,
        capturedAt: Date,
        accuracy: Double?
    ) async {
        struct Upsert: Encodable {
            let user_id: String
            let resort_id: String
            let lat: Double
            let lon: Double
            let captured_at: Date
            let accuracy_m: Double?
            // geohash6 + last_seen filled by trigger
        }
        let row = Upsert(
            user_id: userId.uuidString,
            resort_id: resortId,
            lat: coord.latitude,
            lon: coord.longitude,
            captured_at: capturedAt,
            accuracy_m: accuracy
        )
        do {
            try await supabase.client
                .from("live_presence")
                .upsert(row, onConflict: "user_id")
                .execute()
        } catch {
            AppLog.realtime.error("live_presence upsert failed: \(error.localizedDescription)")
        }
    }

    /// Subscribe to a cell + its 8 neighbors. Idempotent on the cell set —
    /// resubscribing to the same set is a no-op via ref counting in the registry.
    /// Serialized via `pendingCellSubscription` so concurrent callers can't each
    /// observe stale `subscribedCells` across the registry await suspension.
    private func ensureSubscribedToCell(of coord: CLLocationCoordinate2D, resortId: String) async {
        let cell = Geohash.encode(coordinate: coord, precision: 6)
        let needed = Set(Geohash.cellAndNeighbors(cell))
        if needed == subscribedCells { return }

        if let pending = pendingCellSubscription {
            await pending.value
            if needed == subscribedCells { return }
        }

        let generation = cellSubscriptionGeneration &+ 1
        cellSubscriptionGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let this = self else { return }
            await this.performCellSubscription(needed: needed, resortId: resortId)
        }
        pendingCellSubscription = task
        await task.value
        if cellSubscriptionGeneration == generation {
            pendingCellSubscription = nil
        }
    }

    private func performCellSubscription(needed: Set<String>, resortId: String) async {
        // Re-check under the serialized task — a prior task may have already
        // moved us to this exact set.
        if needed == subscribedCells { return }

        // Release old cells we no longer need.
        for old in subscribedCells.subtracting(needed) {
            await registry.release(name: Self.channelName(for: old))
        }

        // Track which overlap cells survive — start from the overlap; add
        // newly-acquired cells on success so partial failures don't leave us
        // believing we subscribed to cells we don't actually hold.
        var acquired: Set<String> = subscribedCells.intersection(needed)

        for cellId in needed.subtracting(subscribedCells) {
            let channelName = Self.channelName(for: cellId)
            do {
                _ = try await registry.acquire(name: channelName)
                await registry.listenBroadcast(channelName: channelName, event: "pos") { [weak self] message in
                    await self?.handleIncomingBroadcast(message: message, resortId: resortId)
                }
                acquired.insert(cellId)
            } catch {
                AppLog.realtime.error("failed to subscribe to cell \(cellId): \(error)")
            }
        }

        subscribedCells = acquired
        AppLog.realtime.debug("subscribed to cells: \(acquired.sorted().joined(separator: ","))")
    }

    /// Idempotently subscribe to the resort-wide fallback channel. Ref-counted
    /// via `ChannelRegistry`, so re-entering `start(resortId:)` for the same
    /// resort is a no-op.
    private func ensureSubscribedToResortChannel(resortId: String) async {
        let name = Self.resortChannelName(for: resortId)
        if subscribedResortChannel == name { return }
        // If we previously held a different resort's channel, release it first.
        if let old = subscribedResortChannel {
            await registry.release(name: old)
            subscribedResortChannel = nil
        }
        do {
            _ = try await registry.acquire(name: name)
            await registry.listenBroadcast(channelName: name, event: "pos") { [weak self] message in
                await self?.handleIncomingBroadcast(message: message, resortId: resortId)
            }
            subscribedResortChannel = name
            AppLog.realtime.debug("subscribed to resort channel: \(name)")
        } catch {
            AppLog.realtime.error("failed to subscribe to resort channel \(name): \(error)")
        }
    }

    /// Apply an inbound broadcast. Drops anything from non-friends (cell-level
    /// filtering can't enforce friendship — the channel is shared by everyone
    /// in that geohash) and anything older than what we already know.
    private func handleIncomingBroadcast(message: JSONObject, resortId: String) async {
        guard let myUserId = supabase.currentSession?.user.id else { return }

        let payload: PositionPayload
        do {
            let data = try JSONSerialization.data(withJSONObject: Self.fromJSONObject(message))
            payload = try JSONDecoder().decode(PositionPayload.self, from: data)
        } catch {
            return
        }

        guard let friendId = UUID(uuidString: payload.u), friendId != myUserId else { return }
        guard payload.r == resortId else { return }  // stale cross-resort traffic

        // Friend-only gate: the geohash channel is shared by every device in
        // the cell, so we must reject payloads from users who aren't in our
        // friends list. See `friendIdsProvider` contract:
        //   - nil provider        → legacy / tests, pass through
        //   - provider() == nil   → snapshot not applied yet, REJECT (closes
        //                           the "accept-everyone-during-cold-launch"
        //                           window; peer comes back on the next
        //                           broadcast once the snapshot lands)
        //   - provider() == set   → accept iff set contains friendId
        if let provider = friendIdsProvider {
            guard let friendIds = provider() else { return }
            guard friendIds.contains(friendId) else { return }
        }

        // Monotonic guard.
        let captured = Date(timeIntervalSince1970: payload.at)
        if let existing = friendLocations[friendId], existing.capturedAt >= captured { return }

        let payloadName = payload.n?.isEmpty == false ? payload.n : nil
        let cachedName = friendLocations[friendId]?.displayName
        let cached = cachedName?.isEmpty == false ? cachedName : nil
        let displayName = payloadName
            ?? cached
            ?? friendNameProvider?(friendId)
            ?? ""
        let loc = FriendLocation(
            userId: friendId,
            displayName: displayName,
            latitude: payload.lat,
            longitude: payload.lon,
            capturedAt: captured,
            nearestNodeId: payload.node,
            accuracyMeters: payload.acc
        )
        friendLocations[friendId] = loc
        friendsPresent.insert(friendId)
        locationHistory?.append(userId: friendId, coordinate: loc.coordinate)
        persistentStore?.upsert(loc)
        prunePresence()
    }

    /// Evict a specific friend from the in-memory cache AND the on-disk
    /// persistent store. Called from `ContentView` when `FriendService.friends`
    /// loses an entry (unfriend / account delete) — without this, the unfriended
    /// user's last-known dot would resurface on the map at the next cold launch
    /// when the disk store rehydrates.
    func removeFriend(_ userId: UUID) {
        friendLocations.removeValue(forKey: userId)
        friendsPresent.remove(userId)
        persistentStore?.remove(userId: userId)
    }

    /// Drop friends from `friendsPresent` whose last broadcast is older than
    /// `presenceTTL`. Their `friendLocations` entry stays — we still want to
    /// render the dim "last seen" dot.
    private func prunePresence() {
        let cutoff = Date().addingTimeInterval(-presenceTTL)
        friendsPresent = friendsPresent.filter { id in
            (friendLocations[id]?.capturedAt ?? .distantPast) >= cutoff
        }
    }

    private func currentCoordinate() -> CLLocationCoordinate2D? {
        if let test = testLocationOverride { return test.coordinate }
        return locationManager.currentLocation
    }

    private func resolveNodeId(for coord: CLLocationCoordinate2D) -> String? {
        if let test = testLocationOverride { return test.nodeId }
        return nodeResolver?(coord)
    }

    private static func channelName(for cell: String) -> String {
        "pos:cell:\(cell)"
    }

    /// Resort-wide fallback channel. Everyone at the resort subscribes; the
    /// per-cell channels stay for low-latency friend proximity, but this one
    /// guarantees cross-cell friends still get each other's broadcasts.
    private static func resortChannelName(for resortId: String) -> String {
        "pos:resort:\(resortId)"
    }

    /// Coerce Foundation JSON dictionary → Supabase JSONObject. Keeps payload
    /// build self-contained so callers don't import AnyJSON directly.
    private static func toJSONObject(_ dict: [String: Any]) throws -> JSONObject {
        var out: JSONObject = [:]
        for (k, v) in dict {
            out[k] = try anyToJSON(v)
        }
        return out
    }

    private static func anyToJSON(_ v: Any) throws -> AnyJSON {
        if v is NSNull { return .null }
        if let b = v as? Bool { return .bool(b) }
        if let d = v as? Double { return .double(d) }
        if let i = v as? Int { return .double(Double(i)) }
        if let s = v as? String { return .string(s) }
        if let arr = v as? [Any] { return .array(try arr.map(anyToJSON)) }
        if let dict = v as? [String: Any] {
            var inner: [String: AnyJSON] = [:]
            for (k, val) in dict { inner[k] = try anyToJSON(val) }
            return .object(inner)
        }
        return .null
    }

    private static func fromJSONObject(_ obj: JSONObject) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in obj {
            out[k] = jsonToAny(v)
        }
        return out
    }

    private static func jsonToAny(_ v: AnyJSON) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .double(let d): return d
        case .integer(let i): return i
        case .string(let s): return s
        case .array(let a): return a.map(jsonToAny)
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, val) in o { out[k] = jsonToAny(val) }
            return out
        }
    }

    /// Fully tear down the channels held by this service. Keeps friendLocations
    /// populated — they're last-known cache, not live state.
    private func stopAsync() async {
        heartbeatTask?.cancel(); heartbeatTask = nil
        // Cancel any in-flight cell subscribe so it can't finish and repopulate
        // `subscribedCells` after we've cleared it.
        pendingCellSubscription?.cancel()
        pendingCellSubscription = nil
        for cell in subscribedCells {
            await registry.release(name: Self.channelName(for: cell))
        }
        subscribedCells.removeAll()
        if let resortChannel = subscribedResortChannel {
            await registry.release(name: resortChannel)
            subscribedResortChannel = nil
        }
        locationManager.endSession()
        friendsPresent.removeAll()
        currentResortId = nil
        // friendLocations intentionally retained for last-known display.
    }

    /// Handle to the most recent channel-release task scheduled by `stop()`.
    /// Exposed so callers can `await` it when teardown order matters — for
    /// example when the same user signs in again immediately after sign-out
    /// and we don't want two overlapping lifecycles touching the registry.
    private(set) var pendingStopTask: Task<Void, Never>?

    /// Synchronous stop. Schedules the async teardown; callers that need to
    /// observe the channel-released state should `await waitForStop()` (or
    /// `await pendingStopTask?.value`).
    func stop() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        // Cancel any in-flight cell subscribe so it can't finish and repopulate
        // `subscribedCells` after we've cleared it.
        pendingCellSubscription?.cancel()
        pendingCellSubscription = nil
        let cells = subscribedCells
        subscribedCells.removeAll()
        let resortChannel = subscribedResortChannel
        subscribedResortChannel = nil
        let registry = self.registry
        pendingStopTask = Task {
            for cell in cells {
                await registry.release(name: Self.channelName(for: cell))
            }
            if let resortChannel {
                await registry.release(name: resortChannel)
            }
        }
        locationManager.endSession()
        friendsPresent.removeAll()
        currentResortId = nil
    }

    /// Wait for the detached teardown task scheduled by `stop()` to finish.
    /// Use when sequencing sign-out → sign-in so the old service's channels
    /// are provably gone before the new one subscribes.
    func waitForStop() async {
        await pendingStopTask?.value
    }
}

/// Listens for `UIApplication.willEnterForegroundNotification` and invokes the
/// supplied handler on the main queue. Held by `RealtimeLocationService` to
/// kick a forced broadcast on resume; broken out as a standalone class so the
/// DEBUG selftest can build one in isolation and verify the wiring fires.
final class ForegroundResubscriber {
    private(set) var fireCount = 0
    private var observer: NSObjectProtocol?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        let name = Notification.Name("UIApplicationWillEnterForegroundNotification")
        observer = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            self?.fireCount += 1
            self?.handler()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
