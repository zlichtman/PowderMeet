//
//  FriendSignalClassifier.swift
//  PowderMeet
//
//  Pure classification of a friend's signal quality based on how recently
//  their position was updated. `FriendQualityStore` wraps this with an
//  observable ticker so views can bind to it without each view owning a
//  timer.
//

import Foundation
import Observation

enum FriendSignalQuality: Hashable {
    case live
    case stale(minutesAgo: Int)
    case cold(minutesAgo: Int)

    nonisolated var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

/// UI-neutral presentation policy shared by every active-meet surface. Views
/// still choose colors, but copy and live/unavailable semantics must not drift
/// between the Map and Meet tabs.
nonisolated struct FriendSignalPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case live
        case stale
        case unavailable
    }

    let statusText: String?
    let tone: Tone
    let isLive: Bool

    init(quality: FriendSignalQuality?) {
        switch quality {
        case .live:
            statusText = nil
            tone = .live
            isLive = true
        case .stale(let minutes):
            statusText = "\(max(1, minutes))M AGO"
            tone = .stale
            isLive = false
        case .cold:
            statusText = "OFFLINE"
            tone = .unavailable
            isLive = false
        case .none:
            statusText = "NO SIGNAL"
            tone = .unavailable
            isLive = false
        }
    }
}

enum FriendSignalClassifier {
    /// Friend dots are omitted from the map when the last fix is older than this
    /// (avoids a “thousands of minutes ago” pill from a stale SwiftData hydrate).
    nonisolated static let mapVisibilityMaxAge: TimeInterval = 3 * 60 * 60

    /// `nonisolated` because this is a pure date-arithmetic helper and is
    /// called from `MapFriendLayerState.FriendLocationKey.init` — itself a
    /// `nonisolated` value-type initializer (no actor state). Without
    /// `nonisolated` it inherits the project's MainActor default and the
    /// init can't reach it.
    nonisolated static func isVisibleOnMap(lastSeen: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(lastSeen)
        return age >= -RoutingFixPolicy.maximumFutureSkewSeconds
            && age <= mapVisibilityMaxAge
    }

    /// Classify based on how long ago the fix was seen.
    ///   < 75s   → live
    ///   75s–<6m → stale (whole-minute labels 1–5)
    ///   >= 6m   → cold
    /// Live window is 75s (not 60s) because cell-tower handoffs on chairlifts
    /// regularly drop a single broadcast cycle without the friend actually
    /// being offline; flicking to stale in that window made dots blink. The
    /// app-close → "go offline" path is closed by the willTerminate fire-and-
    /// forget DELETE in `RealtimeLocationService`, not by tightening this.
    /// Pure function, `nonisolated` for the same reason as `isVisibleOnMap`.
    nonisolated static func classify(lastSeen: Date, now: Date) -> FriendSignalQuality {
        let elapsed = now.timeIntervalSince(lastSeen)
        guard elapsed.isFinite else { return .cold(minutesAgo: 0) }
        if elapsed < -RoutingFixPolicy.maximumFutureSkewSeconds {
            return .cold(minutesAgo: 0)
        }
        if elapsed < RoutingFixPolicy.maximumFixAgeSeconds { return .live }
        let minutes = Int(exactly: (elapsed / 60).rounded(.down)) ?? Int.max
        if minutes <= 5 { return .stale(minutesAgo: minutes) }
        return .cold(minutesAgo: minutes)
    }

    /// Reclassify at freshness/minute boundaries instead of leaving a live
    /// badge visible for up to another polling period. Scheduling remains
    /// subject to normal app suspension and task-execution latency.
    nonisolated static func nextClassificationDelay(lastSeen: Date, now: Date) -> TimeInterval {
        let elapsed = now.timeIntervalSince(lastSeen)
        guard elapsed.isFinite, elapsed >= -RoutingFixPolicy.maximumFutureSkewSeconds else { return 30 }
        let boundary: TimeInterval
        if elapsed < RoutingFixPolicy.maximumFixAgeSeconds {
            boundary = RoutingFixPolicy.maximumFixAgeSeconds - elapsed
        } else if elapsed < 360 {
            boundary = 60 - elapsed.truncatingRemainder(dividingBy: 60)
        } else {
            boundary = 30
        }
        return min(30, max(0.1, boundary))
    }

    /// Defense-in-depth for every external location tier (broadcast, REST,
    /// disk). A far-future timestamp would otherwise win the monotonic guard
    /// indefinitely, while invalid coordinates could poison map/history state.
    nonisolated static func isAcceptableLocationPayload(
        latitude: Double,
        longitude: Double,
        capturedAt: Date,
        now: Date
    ) -> Bool {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age >= -RoutingFixPolicy.maximumFutureSkewSeconds
            && age <= mapVisibilityMaxAge
    }

    /// Rerouting changes an active route and ETA, so it has a stricter input
    /// contract than merely drawing a last-known dot. Only a live fix may move
    /// the friend's route origin; stale/cold fixes stay visible but read-only.
    nonisolated static func isEligibleForReroute(
        lastSeen: Date,
        accuracyMeters: Double? = nil,
        now: Date
    ) -> Bool {
        let elapsed = now.timeIntervalSince(lastSeen)
        guard elapsed >= -30, classify(lastSeen: lastSeen, now: now).isLive else {
            return false
        }
        return RoutingFixPolicy.isUsable(horizontalAccuracyMeters: accuracyMeters)
    }

    /// Full route-origin contract for a live friend packet. Resort identity is
    /// taken from the packet being routed—not the eventually-consistent profile
    /// row—then freshness and accuracy use the same gates as active rerouting.
    nonisolated static func isEligibleForRouting(
        locationResortID: String,
        selectedResortID: String?,
        lastSeen: Date,
        accuracyMeters: Double? = nil,
        now: Date
    ) -> Bool {
        guard let selectedResortID,
              locationResortID == selectedResortID else { return false }
        return isEligibleForReroute(
            lastSeen: lastSeen,
            accuracyMeters: accuracyMeters,
            now: now
        )
    }

    /// A cached coordinate may only establish same-resort presence when it was
    /// captured for the resort currently selected by the local skier. Recency
    /// alone is insufficient: a fresh row from a resort switch would otherwise
    /// make a friend appear available on the wrong mountain.
    nonisolated static func establishesSameResortPresence(
        locationResortID: String,
        selectedResortID: String?,
        lastSeen: Date,
        now: Date
    ) -> Bool {
        guard let selectedResortID,
              locationResortID == selectedResortID else { return false }
        let elapsed = now.timeIntervalSince(lastSeen)
        return elapsed >= -30 && elapsed < 90
    }
}

@MainActor @Observable
final class FriendQualityStore {
    var qualities: [UUID: FriendSignalQuality] = [:]

    private var task: Task<Void, Never>?
    private var locationSource: (@MainActor () -> [UUID: RealtimeLocationService.FriendLocation])?

    /// Poll at most every 30s, waking sooner at the nearest freshness or
    /// minute boundary so active arrival/signal copy expires promptly.
    func start(locationSource: @escaping @MainActor () -> [UUID: RealtimeLocationService.FriendLocation]) {
        self.locationSource = locationSource
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.tick() else { break }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        qualities.removeAll()
    }

    private func tick() -> TimeInterval {
        guard let source = locationSource else { return 30 }
        let now = Date()
        var next: [UUID: FriendSignalQuality] = [:]
        var delay: TimeInterval = 30
        for (id, loc) in source() {
            next[id] = FriendSignalClassifier.classify(lastSeen: loc.capturedAt, now: now)
            delay = min(delay, FriendSignalClassifier.nextClassificationDelay(lastSeen: loc.capturedAt, now: now))
        }
        qualities = next
        return delay
    }
}
