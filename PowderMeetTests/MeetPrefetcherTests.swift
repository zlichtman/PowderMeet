//
//  MeetPrefetcherTests.swift
//  PowderMeetTests
//
//  Lifecycle smoke coverage for the background route warmer.
//  Validating the actual cache-priming behaviour requires a built
//  `MountainGraph` + UserProfile + MeetSolver.Inputs which is too
//  heavyweight for a unit test bundle without fixtures (tracked in
//  CLAUDE.md → "Per-resort golden graph fixtures (capture step
//  only)"). This file pins the prefetcher's lightweight invariants:
//  default state, idempotent cancel, idempotent throttle reset.
//

import XCTest
@testable import PowderMeet

@MainActor
final class MeetPrefetcherTests: XCTestCase {

    func testDefaultsAreIdle() {
        // No solve in flight, no per-friend timestamps. A freshly-built
        // prefetcher should be a clean slate so MeetView's `@State`
        // initialiser doesn't accidentally pick up stale state from
        // a hot-reload scenario.
        let prefetcher = MeetPrefetcher()
        // Public API is fire-and-forget; we just need to confirm the
        // value-type can construct without crash. Side-effects are
        // verified manually per the plan.
        prefetcher.cancel()
        prefetcher.resetThrottle()
    }

    func testCancelIsIdempotent() {
        // The teardown path on `MeetView.handleFriendTap` calls
        // `prefetcher.cancel()` even when no prefetch is in flight
        // (typical case — the user tapped before any prefetch fired).
        // Calling cancel repeatedly must not crash or leak state.
        let prefetcher = MeetPrefetcher()
        prefetcher.cancel()
        prefetcher.cancel()
        prefetcher.cancel()
    }

    func testResetThrottleIsIdempotent() {
        // `MeetView.onChange(of: supabase.solverInputsKey)` calls
        // `resetThrottle()` whenever the user's skill / edge-speed
        // history changes. The first call clears the dict; subsequent
        // calls before any prefetch ran must be no-ops.
        let prefetcher = MeetPrefetcher()
        prefetcher.resetThrottle()
        prefetcher.resetThrottle()
        prefetcher.cancel()
        prefetcher.resetThrottle()
    }
}
