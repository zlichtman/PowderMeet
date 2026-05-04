//
//  PresenceCoordinator.swift
//  PowderMeet
//
//  Single state machine that orders the cold-launch and resort-switch pipeline:
//
//      idle
//        ↓ enter(resortId:)
//      hydratingSocial      -- await FriendService.loadSocialSnapshot()
//        ↓
//      subscribingChannels  -- await RealtimeLocationService.start(resortId:)
//        ↓
//      live                 -- broadcasts now permitted
//        ↓ stop() / enter(different resortId)
//      tearingDown          -- cancels pending broadcast + releases channels
//        ↓
//      idle
//
//  **Why this exists.** Before the coordinator, three lifecycles ran concurrently:
//  (a) `FriendService.loadSocialSnapshot`, (b) `RealtimeLocationService.start`,
//  (c) `broadcastNow` fired by `LocationManager.onFirstFix` / the 5 s heartbeat.
//  Any interleaving of (a)/(b)/(c) could publish our position to peers before
//  the `friendIdsProvider` closure over our social snapshot had been wired up
//  on the receiving side — the exact "accept-everyone-during-cold-launch"
//  window `CLAUDE.md` (social snapshot gate + PresenceCoordinator) calls out.
//
//  **What it doesn't do.** The coordinator is a *pure orchestrator*. It
//  doesn't own channels (`ChannelRegistry` does), doesn't own broadcasts
//  (`RealtimeLocationService` does), doesn't own the snapshot
//  (`FriendService` does). It just sequences them and gates `broadcastNow`
//  on `phase == .live`.
//
//  **Rapid resort switch.** Calling `enter(resortId:)` while a previous
//  enter is still in flight cancels the in-flight enter (via a generation
//  counter re-check), tears the old resort down, and re-enters. Callers
//  never need to `await stop()` before `enter()`.
//

import Foundation
import Observation

@MainActor @Observable
final class PresenceCoordinator {
    enum Phase: String, Sendable {
        case idle
        case hydratingSocial
        case subscribingChannels
        case live
        case tearingDown
    }

    private(set) var phase: Phase = .idle
    private(set) var resortId: String? = nil
    /// `FriendService.socialGeneration` captured at the moment we transitioned
    /// to `.live`. Lets callers detect "social state replaced under me" without
    /// plumbing through the current generation on every access.
    private(set) var socialGenerationAtLive: UInt64 = 0

    private let friendService: FriendService
    private let realtimeLocation: RealtimeLocationService

    /// Generation counter so a rapid re-enter can detect that an earlier
    /// enter task is now stale and abandon its transitions.
    private var enterGeneration: UInt64 = 0
    private var currentEnterTask: Task<Void, Never>?

    init(friendService: FriendService, realtimeLocation: RealtimeLocationService) {
        self.friendService = friendService
        self.realtimeLocation = realtimeLocation
    }

    /// Kick the pipeline for a resort. Idempotent for the same resort when
    /// already `.live`. Cancels any in-flight enter before starting.
    func enter(resortId newResort: String) {
        if phase == .live, resortId == newResort { return }

        enterGeneration &+= 1
        let gen = enterGeneration
        currentEnterTask?.cancel()

        currentEnterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runEnterPipeline(resortId: newResort, gen: gen)
        }
    }

    private func runEnterPipeline(resortId newResort: String, gen: UInt64) async {
        // If something else is already up, tear it down first so the old
        // channels / broadcasts don't overlap with the new ones.
        if phase != .idle, phase != .tearingDown {
            await teardown(gen: gen)
            if gen != enterGeneration { return }
        }
        guard !Task.isCancelled else { return }

        resortId = newResort
        phase = .hydratingSocial

        _ = await friendService.loadSocialSnapshot(resortId: newResort)
        if gen != enterGeneration || Task.isCancelled { return }

        phase = .subscribingChannels
        await realtimeLocation.start(resortId: newResort)
        if gen != enterGeneration || Task.isCancelled { return }

        socialGenerationAtLive = friendService.socialGeneration
        phase = .live
        print("[PresenceCoordinator] live resort=\(newResort) socialGen=\(socialGenerationAtLive)")
    }

    /// Fire a position broadcast iff we're in `.live`. Silently drops when
    /// not — the 5 s heartbeat in `RealtimeLocationService` will re-fire
    /// once we reach `.live`, so there's no loss of liveness from gating here.
    func broadcastNow(force: Bool = false) async {
        guard phase == .live else {
            // One log line per drop would be noisy in the cooldown-hot path.
            // The heartbeat will pick us up within 5 s of going live.
            return
        }
        await realtimeLocation.broadcastNow(force: force)
    }

    /// Re-subscribes `pos:cell` + `pos:resort` listeners. `RealtimeLocationService`
    /// no-ops until it has a `currentResortId`; call after `enter` / `waitForEnter`
    /// when resuming from background.
    func reconnectLiveTransport(resortId activeResortId: String) async {
        guard resortId == activeResortId else { return }
        await realtimeLocation.reconnectPositionChannelsIfActive()
    }

    /// Synchronous stop. The underlying realtime service tears channels down
    /// off-main; await `waitForStop()` on the service if you need sequencing.
    func stop() {
        enterGeneration &+= 1
        currentEnterTask?.cancel()
        currentEnterTask = nil
        phase = .tearingDown
        realtimeLocation.stop()
        resortId = nil
        socialGenerationAtLive = 0
        phase = .idle
    }

    private func teardown(gen: UInt64) async {
        phase = .tearingDown
        realtimeLocation.stop()
        await realtimeLocation.waitForStop()
        if gen != enterGeneration { return }
        resortId = nil
        socialGenerationAtLive = 0
        phase = .idle
    }

    /// Wait for any in-flight `enter()` to reach a terminal state.
    /// Callers generally don't need this — it exists for tests and for
    /// sequencing sign-out teardown.
    func waitForEnter() async {
        await currentEnterTask?.value
    }
}
