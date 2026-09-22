//
//  SolverCache.swift
//  PowderMeet
//
//  Bounded LRU cache for successful 2-skier solves. Extracted from
//  MeetingPointSolver.swift; the locking contract below is load-bearing —
//  don't let mutation paths escape the NSLock.
//

import Foundation

// MARK: - Solution Cache

/// Bounded LRU cache for successful 2-skier solves. Shared across solver
/// instances because callers typically create a fresh solver per request —
/// cache-on-instance would be wasted. Cache key spans everything the result
/// depends on, so entries for stale graphs never collide with live ones.
///
/// **Concurrency contract.** `@unchecked Sendable` — all mutable state
/// (`order`, `store`) is guarded by an `NSLock`, so concurrent access from
/// multiple `Task.detached` solves is safe. `MeetingResult` itself is a
/// value type holding `Sendable` members. The cache lives as a static on
/// `MeetingPointSolver`, accessed from any actor; do not let mutation paths
/// escape outside the lock or eject the lock-and-defer pattern from
/// `value(for:)` / `set(_:for:)`. Long-term direction is `os.Mutex` (or an
/// actor wrapper) under Swift 6 strict-concurrency, but `@unchecked Sendable
/// + NSLock` is the production-safe interim — `Mutex` is iOS 18+ only and
/// the deployment target still includes 17.6.
nonisolated final class SolverCache: @unchecked Sendable {
    struct CacheKey: Hashable {
        let graphFingerprint: String
        let rendezvousFingerprint: String
        let positionA: String
        let positionB: String
        let profileA: String
        let profileB: String
        let contextSignature: String
        /// Hash of the per-edge skill memory the solver consulted. Must
        /// be in the key — `traverseTime` reads `edgeSpeedHistory` via
        /// `TraversalContext`, so importing a run (which mutates the
        /// dict) needs to invalidate prior cached paths for the same
        /// (positions, profiles, weather). Without this field, a re-solve
        /// after import returned the stale path and the user's calibration
        /// was silently ignored.
        let edgeSpeedHistoryFingerprint: String
    }

    private var order: [CacheKey] = []
    private var store: [CacheKey: MeetingResult] = [:]
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 128) {
        self.capacity = capacity
    }

    func value(for key: CacheKey) -> MeetingResult? {
        lock.lock(); defer { lock.unlock() }
        guard let result = store[key] else { return nil }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        return result
    }

    func set(_ result: MeetingResult, for key: CacheKey) {
        lock.lock(); defer { lock.unlock() }
        if store[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx); order.append(key)
        }
        store[key] = result
        while order.count > capacity {
            let evict = order.removeFirst()
            store.removeValue(forKey: evict)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        order.removeAll()
        store.removeAll()
    }
}
