//
//  ContentCoordinator+Teardown.swift
//  PowderMeet
//
//  Extension of ContentCoordinator — sign-out / account-delete teardown (order-sensitive; kept verbatim).
//  Split out of ContentCoordinator.swift (behavior-preserving), matching the
//  existing +Conditions / +Ghosts extension pattern. @MainActor inherited.
//

import SwiftUI
import CoreLocation

extension ContentCoordinator {

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
        // Audited: `teardownGen` is captured pre-first-await and re-checked
        // after every await below; a fast sign-in flips the generation and
        // the next guard bails before mutating the new session's state.
        let teardownGen = SupabaseManager.shared.sessionGeneration
        conditionsTask?.cancel()
        conditionsTask = nil
        // Flush any in-progress run before we tear realtime services
        // down — sign-out should not silently lose the run that was
        // half in the buffer. Detach the fix pump first so a fix landing
        // during teardown cannot restart the recorder or broadcast.
        locationManager.onFix = nil
        stopLiveRecording()
        friendQualityStore.stop()
        // SYNC gate: set `phase = .idle` and kick the off-main channel
        // release immediately, before yielding to the Task below. The
        // async cleanup that follows still awaits provable channel
        // release via `realtime.teardown` → `presence.stopAndWait` →
        // `realtimeLocation.waitForStop`, but the sync stop here
        // closes a window where the heartbeat + LocationManager fixes
        // could fire one final broadcast in the brief Task-scheduling
        // gap on @MainActor. Idempotent — `RealtimeLocationService.stop`
        // de-dupes a second call so the `await` chain inside
        // `stopAndWait` still finds and waits on the original
        // `pendingStopTask`.
        realtime.presence?.stop()
        Task { [weak self] in
            guard let self else { return }
            // Re-check sessionGeneration between each await: a fast
            // sign-out → sign-in can flip it mid-cleanup, in which
            // case the new session owns its own services and the rest
            // of this Task is wasted work / risk of touching stale
            // captures. The bumping happens in
            // `SupabaseManager.observeAuthChanges` on every auth flip.
            guard SupabaseManager.shared.sessionGeneration == teardownGen else {
                AppLog.meet.debug("teardown task stale at entry (gen=\(teardownGen), now=\(SupabaseManager.shared.sessionGeneration)) — skipping")
                return
            }
            // Order matters: realtime channels first (so position
            // broadcasts can't outlive sign-out), then postgres_changes
            // subscriptions, then in-memory caches.
            await self.realtime.teardown()
            guard SupabaseManager.shared.sessionGeneration == teardownGen else {
                AppLog.meet.debug("teardown task stale after realtime.teardown — skipping rest")
                return
            }
            await self.friendService.stopRealtimeSubscription()
            guard SupabaseManager.shared.sessionGeneration == teardownGen else {
                AppLog.meet.debug("teardown task stale after friendService.stopRealtimeSubscription — skipping rest")
                return
            }
            await self.meetRequestService.reset()
            guard SupabaseManager.shared.sessionGeneration == teardownGen else {
                AppLog.meet.debug("teardown task stale after meetRequestService.reset — skipping cache wipe")
                return
            }
            // Only reset local caches AFTER realtime channels are gone so
            // a late postgres_changes event can't re-populate the caches.
            self.friendService.reset()
        }
    }

}
