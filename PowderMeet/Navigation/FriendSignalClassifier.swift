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

    var isLive: Bool {
        if case .live = self { return true }
        return false
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
        now.timeIntervalSince(lastSeen) <= mapVisibilityMaxAge
    }

    /// Classify based on how long ago the fix was seen.
    ///   < 60s   → live
    ///   60s–5m  → stale
    ///   > 5m    → cold
    /// Pure function, `nonisolated` for the same reason as `isVisibleOnMap`.
    nonisolated static func classify(lastSeen: Date, now: Date) -> FriendSignalQuality {
        let elapsed = now.timeIntervalSince(lastSeen)
        if elapsed < 60 { return .live }
        let minutes = Int(elapsed / 60)
        if minutes <= 5 { return .stale(minutesAgo: minutes) }
        return .cold(minutesAgo: minutes)
    }
}

@MainActor @Observable
final class FriendQualityStore {
    var qualities: [UUID: FriendSignalQuality] = [:]

    private var task: Task<Void, Never>?
    private var locationSource: (@MainActor () -> [UUID: RealtimeLocationService.FriendLocation])?

    /// Starts a 30s ticker that reclassifies every known friend.
    /// Cadence chosen because stale threshold is 60s — 30s worst-case
    /// visual latency keeps the "2M AGO" label honest.
    func start(locationSource: @escaping @MainActor () -> [UUID: RealtimeLocationService.FriendLocation]) {
        self.locationSource = locationSource
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        qualities.removeAll()
    }

    private func tick() {
        guard let source = locationSource else { return }
        let now = Date()
        var next: [UUID: FriendSignalQuality] = [:]
        for (id, loc) in source() {
            next[id] = FriendSignalClassifier.classify(lastSeen: loc.capturedAt, now: now)
        }
        qualities = next
    }
}
