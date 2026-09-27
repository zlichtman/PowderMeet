//
//  ContentCoordinator+Bootstrap.swift
//  PowderMeet
//
//  Extension of ContentCoordinator — cold-launch bootstrap fan-out.
//  Split out of ContentCoordinator.swift (behavior-preserving), matching the
//  existing +Conditions / +Ghosts extension pattern. @MainActor inherited.
//

import SwiftUI
import CoreLocation
import Supabase

extension ContentCoordinator {

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
            if let coord = locationManager.currentLocation,
               RoutingFixPolicy.isUsable(
                    horizontalAccuracyMeters: locationManager.currentAccuracy,
                    capturedAt: locationManager.currentFixTimestamp
               ) {
                let candidates = ResortEntry.catalog.filter { $0.bounds.contains(coord) }
                let sorted = candidates.sorted { a, b in
                    let ax = a.coordinate.latitude  - coord.latitude
                    let ay = a.coordinate.longitude - coord.longitude
                    let bx = b.coordinate.latitude  - coord.latitude
                    let by = b.coordinate.longitude - coord.longitude
                    return (ax * ax + ay * ay) < (bx * bx + by * by)
                }
                if sorted.count == 1 {
                    // Unambiguous — auto-select.
                    selectedEntry = sorted[0]
                } else if sorted.count >= 2 {
                    // Multiple catalog bboxes contain this GPS point
                    // (Vail/Beaver Creek, Park City/Deer Valley, etc.).
                    // Don't silently pick — the wrong choice would load
                    // a graph the user's friend isn't on, leaving each
                    // one wondering why the other never appears. Stash
                    // the candidates and let the picker auto-present
                    // below; the user resolves with one tap.
                    pendingResortChoices = sorted
                }
                // 0 candidates → fall through, `selectedEntry` stays nil,
                // existing "PICK A MOUNTAIN" overlay surfaces.
            }
        }

        // [weak self]: the coordinator owns `meetRequestService`, which
        // retains these callbacks — without weak we'd loop
        // coordinator → service → callback → coordinator.
        meetRequestService.onEvent = { [weak self] event in
            switch event {
            case .accepted(let request):
                Task { await self?.activateRoute(for: request) }
            case .expired(let request):
                self?.handleMeetupCancelledByOther(requestId: request.id)
            case .etaUpdated(let request):
                self?.meetup.handleRemoteETAUpdate(request)
            case .received, .declined:
                break
            }
        }
        // Flush durable offline "End Meetup" intent before recovery. If the
        // network write still fails, the local tombstone below excludes that
        // accepted row so explicit user intent cannot be resurrected.
        await meetRequestService.flushPendingTerminations()

        // Load sent + incoming in parallel before starting listener so the
        // realtime handler can match requests even if the app was restarted.
        async let sentLoad: () = meetRequestService.loadSent()
        async let incomingLoad: () = meetRequestService.loadIncoming()
        async let acceptedRecoveryLoad: MeetRequest? = meetRequestService
            .loadRecoverableAccepted()
        let (_, _, recoverableAccepted) = await (
            sentLoad,
            incomingLoad,
            acceptedRecoveryLoad
        )

        // An accepted meetup owns the resort context on recovery. The bounded
        // policy above already rejects stale/legacy rows; selecting its resort
        // before the parallel graph/social load lets activation validate the
        // exact dataset instead of briefly loading an unrelated saved resort.
        if let recoverableAccepted,
           let recoveryEntry = ResortEntry.catalog.first(where: {
               $0.id == recoverableAccepted.resortId
           }) {
            selectedEntry = recoveryEntry
        }
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
        // loadPending. See AGENTS.md — social snapshot gate.
        async let snapshotLoad: () = {
            _ = await self.friendService.loadSocialSnapshot(resortId: entryToLoad?.id)
        }()
        _ = await (resortLoad, snapshotLoad)

        if let request = recoverableAccepted,
           activeMeetSession == nil,
           let currentUserID = SupabaseManager.shared.currentSession?.user.id {
            if request.senderId == currentUserID {
                await activateRoute(for: request)
            } else if request.receiverId == currentUserID {
                await activateRouteAsReceiver(for: request)
            }
            if activeMeetSession?.id == request.id {
                setTransientMessage("MEETUP RESTORED")
            }
        }

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
    func runFriendProfilePollingLoop() async {
        while !Task.isCancelled {
            let interval: Duration = friendService.pendingSent.isEmpty ? .seconds(30) : .seconds(2)
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { break }
            _ = await friendService.loadSocialSnapshot(resortId: selectedEntry?.id)
        }
    }

}
