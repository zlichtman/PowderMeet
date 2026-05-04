//
//  ChannelRegistry.swift
//  PowderMeet
//
//  Single owner of Supabase Realtime channels. Today RealtimeLocationService,
//  FriendService, and MeetRequestService each open their own channel — three
//  WebSockets per device, each with its own heartbeat. The registry collapses
//  that to one channel per (resort, geohash6) key with multiplexed handlers.
//
//  Two acquisition modes:
//
//  1. **One-shot acquire** (`acquire`): subscribe immediately, single owner —
//     used by the per-cell pos:cell:{hash} broadcast channels which only ever
//     have one handler set per channel.
//
//  2. **Prepare → subscribe** (`prepare` + `subscribe`): used when multiple
//     callers want to attach postgres_changes filters to the *same* channel.
//     Supabase requires all `postgresChange()` registrations to land before
//     `subscribeWithError()`, so each service calls `prepare(name:)`, adds
//     its filters to the returned channel, then calls `subscribe(name:)`.
//     The first subscribe does the SDK call; subsequent ones are no-ops.
//
//  Either way, `release(name:)` decrements the ref count and tears down the
//  channel only when it hits zero — so two services sharing `"user:{id}"`
//  share the same WebSocket and the channel only closes when both release.
//

import Foundation
import Supabase

actor ChannelRegistry {
    /// Singleton with no cross-actor capture: the registry doesn't store the
    /// MainActor-isolated `SupabaseManager`. Instead it lazily caches the
    /// `SupabaseClient` (Sendable per the SDK) on first use. This sidesteps
    /// the Swift 6 strict-concurrency error that `@MainActor static let`
    /// initializers can hit when their autoclosure captures another isolated
    /// singleton.
    static let shared = ChannelRegistry()

    private struct Entry {
        var channel: RealtimeChannelV2
        var refCount: Int
        var subscribed: Bool
        var broadcastTasks: [String: Task<Void, Never>]
        var streamTasks: [Task<Void, Never>]
    }
    private var entries: [String: Entry] = [:]
    private var cachedClient: SupabaseClient?

    private init() {}

    private func realtime() async -> RealtimeClientV2 {
        if let cached = cachedClient { return cached.realtimeV2 }
        let c = await MainActor.run { SupabaseManager.shared.client }
        cachedClient = c
        return c.realtimeV2
    }

    // MARK: - One-shot acquire (broadcast channels)

    /// Acquire (or reuse) a channel by name and subscribe it immediately. Used
    /// for broadcast-only channels with a single owner per channel name.
    @discardableResult
    func acquire(name: String) async throws -> RealtimeChannelV2 {
        if var existing = entries[name] {
            existing.refCount += 1
            entries[name] = existing
            return existing.channel
        }
        let ch = await realtime().channel(name)
        try await ch.subscribeWithError()
        entries[name] = Entry(
            channel: ch, refCount: 1, subscribed: true,
            broadcastTasks: [:], streamTasks: []
        )
        return ch
    }

    // MARK: - Prepare → subscribe (multi-owner postgres_changes)

    /// Get or create a channel without subscribing yet. Caller must register
    /// any `postgresChange()` filters before calling `subscribe(name:)`.
    /// Bumps the ref count regardless — pair with a matching `release`.
    func prepare(name: String) async -> RealtimeChannelV2 {
        if var existing = entries[name] {
            existing.refCount += 1
            entries[name] = existing
            return existing.channel
        }
        let ch = await realtime().channel(name)
        entries[name] = Entry(
            channel: ch, refCount: 1, subscribed: false,
            broadcastTasks: [:], streamTasks: []
        )
        return ch
    }

    /// Subscribe a previously-prepared channel. Idempotent — second and later
    /// callers are no-ops, so it's safe for both services sharing the channel
    /// to call this independently after they've added their filters.
    ///
    /// Mid-subscribe suspension: the await on `subscribeWithError()` yields
    /// the actor, so a concurrent caller used to see `subscribed == false`
    /// and fire a second SDK subscribe (which the server rejects and the
    /// SDK logs as a `postgresChange-after-joining` warning). We now flip
    /// the flag to `true` *before* the await and await a shared inflight
    /// task so simultaneous callers fan in.
    private var subscribeInflight: [String: Task<Void, Error>] = [:]

    func subscribe(name: String) async throws {
        guard var entry = entries[name] else { return }
        if entry.subscribed { return }

        if let existing = subscribeInflight[name] {
            try await existing.value
            return
        }

        entry.subscribed = true
        entries[name] = entry
        let channel = entry.channel
        let task = Task<Void, Error> { try await channel.subscribeWithError() }
        subscribeInflight[name] = task
        do {
            try await task.value
            subscribeInflight[name] = nil
        } catch {
            // Subscribe failed — roll back the optimistic flag so a retry
            // can proceed. Without this the entry is stuck in a permanent
            // "supposedly subscribed but not actually listening" state.
            subscribeInflight[name] = nil
            if var e = entries[name] {
                e.subscribed = false
                entries[name] = e
            }
            throw error
        }
    }

    /// Track an `AsyncSequence` consumer so the registry can cancel it when
    /// the channel is finally released. Use for postgres_changes streams that
    /// the caller doesn't otherwise hold a Task handle for.
    func trackStream(channelName: String, _ task: Task<Void, Never>) {
        guard var entry = entries[channelName] else { task.cancel(); return }
        entry.streamTasks.append(task)
        entries[channelName] = entry
    }

    // MARK: - Release

    /// Decrement the ref count; tear down the channel when it hits zero.
    /// Defends against double-release (underflow) by clamping at 0 and
    /// surfacing a log so the callsite can be fixed rather than silently
    /// skipping the teardown.
    func release(name: String) async {
        guard var entry = entries[name] else {
            print("[ChannelRegistry] release(\(name)) — no such entry (double-release?)")
            return
        }
        if entry.refCount <= 0 {
            print("[ChannelRegistry] release(\(name)) — refCount already \(entry.refCount); tearing down")
        }
        entry.refCount -= 1
        if entry.refCount <= 0 {
            for (_, task) in entry.broadcastTasks { task.cancel() }
            for task in entry.streamTasks { task.cancel() }
            subscribeInflight[name]?.cancel()
            subscribeInflight[name] = nil
            await realtime().removeChannel(entry.channel)
            entries.removeValue(forKey: name)
        } else {
            entries[name] = entry
        }
    }

    // MARK: - Broadcast helpers

    /// Listen for a broadcast event on a channel. The returned task is cancelled
    /// automatically when the channel's ref count hits zero. Re-listening for
    /// the same event replaces the handler and cancels the previous consumer
    /// task so we don't leak a running stream reader.
    func listenBroadcast(channelName: String,
                         event: String,
                         handler: @escaping @Sendable (JSONObject) async -> Void) async {
        guard var entry = entries[channelName] else { return }
        // Cancel any existing consumer for this event so we don't leak a task
        // that keeps draining the old stream.
        entry.broadcastTasks[event]?.cancel()
        let stream = entry.channel.broadcastStream(event: event)
        let task = Task {
            for await message in stream {
                if Task.isCancelled { return }
                await handler(message)
            }
        }
        entry.broadcastTasks[event] = task
        entries[channelName] = entry
    }

    /// Send a broadcast. Caller must already hold the channel via `acquire`.
    ///
    /// If the channel is held but the SDK hasn't yet flipped
    /// `channel.status` to `.subscribed` (race between our `acquire` returning
    /// and the socket ACK landing), wait up to 500 ms for the status to
    /// settle before either sending or giving up. This closes the silent-drop
    /// window that could otherwise eat the first broadcast right after a cell
    /// boundary crossing.
    ///
    /// If the entry doesn't exist at all, the caller never held the channel —
    /// drop without retry (this is caller error, not a transient race).
    func sendBroadcast(channelName: String,
                       event: String,
                       payload: JSONObject) async {
        guard let entry = entries[channelName] else { return }

        if entry.subscribed, entry.channel.status == .subscribed {
            await entry.channel.broadcast(event: event, message: payload)
            return
        }

        // Bounded wait-for-subscribed. 500 ms total, poll at 25 ms — long
        // enough to absorb realistic subscribe ACK latency on a cell
        // crossing, short enough that a stuck channel doesn't wedge a
        // broadcast caller for a full heartbeat window.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard let current = entries[channelName] else { return }
            if current.subscribed, current.channel.status == .subscribed {
                await current.channel.broadcast(event: event, message: payload)
                return
            }
        }
        // Timed out — channel truly isn't up. The caller's next heartbeat
        // will retry; dropping here is the correct liveness semantic.
    }

    // MARK: - Diagnostic

    func snapshot() -> [(name: String, refCount: Int, subscribed: Bool)] {
        entries.map { ($0.key, $0.value.refCount, $0.value.subscribed) }
            .sorted { $0.name < $1.name }
    }
}
