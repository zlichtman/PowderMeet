//
//  MeetPrefetcher.swift
//  PowderMeet
//
//  Background route warmer for the friend list. Pre-runs the meet
//  solver for friends visible in `LiveFriendsDrawer` whenever their
//  location updates, so a subsequent tap finds the result already
//  in `MeetingPointSolver.solutionCache` (capacity-128 LRU,
//  cross-call) and renders effectively instantly.
//
//  Why detached is safe: ghost-result concern that motivated the
//  c5e47b3 inline-solve revert only matters when a stale solve's
//  `MeetingResult` is rendered to the cards. Prefetch never reads
//  the return value; it only side-effects the static cache. No
//  ghost surface.
//
//  Throttling shape:
//    - per-friend: at most one prefetch every 5 seconds
//    - global: at most one prefetch in flight at a time
//      (cancelled when a newer prefetch is scheduled OR when the
//      user taps a friend so the foreground solve has CPU to itself)
//    - skip when an active meetup is in progress (the user is
//      already engaged on a route; pre-warming alternates is noise)
//
//  Cost model: with 10 visible friends and the 850 ms idle broadcast
//  cadence, the per-friend 5 s throttle bounds aggregate prefetches
//  to ≤ 2 / s. Each ~200 ms of background-thread Dijkstra at
//  `userInitiated` priority. UI is unaffected; the avatar prefetch
//  in ContentCoordinator is the same shape and shipped without
//  battery complaints.
//

import Foundation
import Observation

@MainActor
@Observable
final class MeetPrefetcher {
    /// Last-prefetch timestamp per friend, for the per-friend throttle.
    /// Cleared when the solver inputs key changes (skill / edge-speed
    /// history shifts) so cached entries that were primed against the
    /// old physics get re-warmed promptly.
    @ObservationIgnored private var lastPrefetchAt: [UUID: Date] = [:]

    /// One prefetch task at a time. Cancelled when a newer prefetch
    /// is scheduled or when the user taps a friend (so the foreground
    /// solve isn't fighting for CPU).
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// Per-friend rate limit. 5 s is the sweet spot: short enough that
    /// a friend who just moved on the map gets re-primed before the
    /// user looks at them; long enough that 10 visible friends each
    /// idling at 850 ms broadcasts don't burn CPU on redundant solves.
    private let minPrefetchInterval: TimeInterval = 5.0

    /// Schedule a background solve for `friend`. Returns immediately;
    /// the solve runs on a detached userInitiated task. Result is
    /// discarded — the static `MeetingPointSolver.solutionCache` is
    /// what consumers (the foreground tap-time `solveMeeting`) read.
    ///
    /// - Parameters:
    ///   - friend: the friend whose meet route should be pre-warmed.
    ///   - inputs: the same `MeetSolver.Inputs` the foreground solve
    ///     would build at tap time. Caller is responsible for the
    ///     resort gate / position-snap / edge-speed-load steps so
    ///     the prefetch primes a key the foreground solve will hit.
    ///   - hasActiveMeetup: when true, skip — the user is already
    ///     engaged on a different concern.
    func prefetch(
        for friend: UserProfile,
        inputs: MeetSolver.Inputs,
        hasActiveMeetup: Bool
    ) {
        if hasActiveMeetup {
            AppLog.meet.debug("prefetch skipped:reason=active-meetup friend=\(friend.id)")
            return
        }
        if let last = lastPrefetchAt[friend.id],
           Date.now.timeIntervalSince(last) < minPrefetchInterval {
            return
        }
        lastPrefetchAt[friend.id] = .now

        inFlight?.cancel()
        let friendId = friend.id
        inFlight = Task.detached(priority: .userInitiated) {
            // Result is discarded — the side-effect we want is the
            // entry it leaves in `MeetingPointSolver.solutionCache`.
            _ = await MeetSolver.solve(inputs)
            await MainActor.run {
                AppLog.meet.debug("prefetch completed friend=\(friendId)")
            }
        }
        AppLog.meet.debug("prefetch scheduled friend=\(friendId)")
    }

    /// Cancel any in-flight prefetch. Invoked from `handleFriendTap`
    /// so the foreground solve doesn't fight a background task for
    /// CPU on big resorts where Dijkstra is the dominant cost.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }

    /// Drop the per-friend rate-limit history. Called when the
    /// solver inputs key changes (skill slider moved, activity
    /// imported) — cached entries primed against the old physics
    /// are stale, so the next visible-friend update should re-warm
    /// immediately rather than wait out the 5 s window.
    func resetThrottle() {
        lastPrefetchAt.removeAll(keepingCapacity: true)
    }
}
