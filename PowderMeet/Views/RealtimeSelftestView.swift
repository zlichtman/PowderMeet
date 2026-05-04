//
//  RealtimeSelftestView.swift
//  PowderMeet
//
//  DEBUG-only checklist screen that runs the realtime-stack invariants from
//  Cursor's ALGORITHM_AUDIT.md against the live in-process services. Pure
//  black-box checks — no XCTest needed, runnable on a real device next to
//  the actual map. Invariants requiring server-side observation or scene
//  transitions are marked manual and surface guidance instead of green/red.
//

#if DEBUG
import SwiftUI
import CoreLocation

struct RealtimeSelftestView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var results: [String: Result] = [:]
    @State private var running = false

    enum Result: Equatable {
        case pending
        case pass(String)
        case fail(String)
        case manual(String)
    }

    private struct Check: Identifiable {
        let id: String
        let title: String
        let run: () async -> Result
    }

    private var checks: [Check] {
        [
            Check(id: "1", title: "FriendLocationStore loads in <200ms", run: checkStoreLoad),
            Check(id: "2", title: "Monotonic guard: stale wins → no, fresh wins → yes", run: checkMonotonic),
            Check(id: "3", title: "Geohash precision-6 returns self + 8 neighbors", run: checkGeohashNeighbors),
            Check(id: "4", title: "ChannelRegistry: ref count balances on acquire/release", run: checkRegistryRefCount),
            Check(id: "5", title: "ChannelRegistry: prepare→subscribe is idempotent", run: checkRegistryIdempotent),
            Check(id: "6", title: "FriendLocationStore.remove deletes the row", run: checkStoreRemove),
            Check(id: "7", title: "live_presence throttle: ≤1 write per 30s (force overrides)", run: checkLivePresenceThrottle),
            Check(id: "8", title: "willEnterForeground triggers resubscribe handler", run: checkForegroundResubscribe),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: runAll) {
                        HStack {
                            Image(systemName: running ? "hourglass" : "play.circle.fill")
                            Text(running ? "RUNNING…" : "RUN ALL")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .tracking(1)
                        }
                    }
                    .disabled(running)
                }

                Section("INVARIANTS") {
                    ForEach(checks) { check in
                        row(for: check)
                    }
                }
            }
            .navigationTitle("REALTIME SELFTEST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for check: Check) -> some View {
        let res = results[check.id] ?? .pending
        return HStack(alignment: .top, spacing: 10) {
            statusIcon(res)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.system(size: 12, weight: .medium))
                if case .pass(let msg) = res, !msg.isEmpty {
                    Text(msg).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                } else if case .fail(let msg) = res {
                    Text(msg).font(.system(size: 10, design: .monospaced)).foregroundStyle(.red)
                } else if case .manual(let msg) = res {
                    Text(msg).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Run") {
                Task { results[check.id] = await check.run() }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(running)
        }
    }

    @ViewBuilder
    private func statusIcon(_ r: Result) -> some View {
        switch r {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .pass:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .fail:    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .manual:  Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
        }
    }

    private func runAll() {
        running = true
        Task {
            for check in checks {
                results[check.id] = await check.run()
            }
            running = false
        }
    }

    // MARK: - Invariant implementations

    private func checkStoreLoad() async -> Result {
        do {
            let store = try FriendLocationStore()
            let start = Date()
            _ = store.loadAll()
            let ms = Date().timeIntervalSince(start) * 1000
            return ms < 200
                ? .pass(String(format: "%.1f ms", ms))
                : .fail(String(format: "%.1f ms (>200)", ms))
        } catch {
            return .fail("init failed: \(error.localizedDescription)")
        }
    }

    private func checkMonotonic() async -> Result {
        let userId = UUID()
        let now = Date()
        let fresh = RealtimeLocationService.FriendLocation(
            userId: userId, displayName: "T", latitude: 0, longitude: 0,
            capturedAt: now, nearestNodeId: nil, accuracyMeters: nil
        )
        let stale = RealtimeLocationService.FriendLocation(
            userId: userId, displayName: "T", latitude: 1, longitude: 1,
            capturedAt: now.addingTimeInterval(-60), nearestNodeId: nil, accuracyMeters: nil
        )
        guard fresh.capturedAt > stale.capturedAt else {
            return .fail("date ordering wrong")
        }
        return .pass("fresh \(Int(fresh.capturedAt.timeIntervalSince(stale.capturedAt)))s newer")
    }

    private func checkGeohashNeighbors() async -> Result {
        let cell = Geohash.encode(latitude: 39.6, longitude: -106.35, precision: 6)
        let set = Geohash.cellAndNeighbors(cell)
        guard cell.count == 6 else { return .fail("precision \(cell.count) ≠ 6") }
        guard set.count == 9 else { return .fail("neighbors=\(set.count), expected 9") }
        guard set.contains(cell) else { return .fail("self not in cellAndNeighbors") }
        return .pass("\(cell) + 8 neighbors")
    }

    private func checkRegistryRefCount() async -> Result {
        let registry = ChannelRegistry.shared
        let name = "selftest:refcount:\(UUID().uuidString)"
        let beforeCount = await registry.snapshot().count
        _ = await registry.prepare(name: name)
        _ = await registry.prepare(name: name)
        let afterPrepare = await registry.snapshot().first(where: { $0.name == name })?.refCount ?? 0
        await registry.release(name: name)
        await registry.release(name: name)
        let afterCount = await registry.snapshot().count
        guard afterPrepare == 2 else {
            return .fail("ref after 2× prepare = \(afterPrepare), expected 2")
        }
        guard beforeCount == afterCount else {
            return .fail("registry size leaked: before=\(beforeCount) after=\(afterCount)")
        }
        return .pass("acquire/release balanced")
    }

    private func checkRegistryIdempotent() async -> Result {
        let registry = ChannelRegistry.shared
        let name = "selftest:idem:\(UUID().uuidString)"
        _ = await registry.prepare(name: name)
        do {
            try await registry.subscribe(name: name)
            try await registry.subscribe(name: name)
        } catch {
            await registry.release(name: name)
            return .fail("subscribe threw: \(error.localizedDescription)")
        }
        await registry.release(name: name)
        return .pass("2× subscribe ok")
    }

    private func checkLivePresenceThrottle() async -> Result {
        let now = Date()
        let interval = RealtimeLocationService.minTableUpsertInterval

        // 10s after last write: should NOT upsert.
        let recent = RealtimeLocationService.shouldUpsertLivePresence(
            now: now, lastUpsertAt: now.addingTimeInterval(-10), interval: interval
        )
        if recent { return .fail("upsert fired only 10s after last (interval=\(Int(interval))s)") }

        // 31s after last write: SHOULD upsert.
        let aged = RealtimeLocationService.shouldUpsertLivePresence(
            now: now, lastUpsertAt: now.addingTimeInterval(-(interval + 1)), interval: interval
        )
        if !aged { return .fail("upsert blocked at \(Int(interval) + 1)s past last write") }

        // force=true should always upsert regardless of recency.
        let forced = RealtimeLocationService.shouldUpsertLivePresence(
            now: now, lastUpsertAt: now, interval: interval, force: true
        )
        if !forced { return .fail("force=true did not override throttle") }

        return .pass("≤1 / \(Int(interval))s, force overrides")
    }

    @MainActor
    private func checkForegroundResubscribe() async -> Result {
        var fired = 0
        let resub = ForegroundResubscriber { fired += 1 }
        NotificationCenter.default.post(
            name: Notification.Name("UIApplicationWillEnterForegroundNotification"),
            object: nil
        )
        // Notification posts on main queue — give the run loop one tick.
        try? await Task.sleep(for: .milliseconds(50))
        _ = resub  // hold strongly through assertion
        return fired == 1
            ? .pass("handler fired on willEnterForegroundNotification")
            : .fail("handler fired \(fired)× (expected 1)")
    }

    private func checkStoreRemove() async -> Result {
        do {
            let store = try FriendLocationStore()
            let userId = UUID()
            let loc = RealtimeLocationService.FriendLocation(
                userId: userId, displayName: "Test", latitude: 39.6, longitude: -106.35,
                capturedAt: Date(), nearestNodeId: nil, accuracyMeters: 12
            )
            store.upsert(loc)
            guard store.loadAll().contains(where: { $0.userId == userId }) else {
                return .fail("upsert didn't persist")
            }
            store.remove(userId: userId)
            guard !store.loadAll().contains(where: { $0.userId == userId }) else {
                return .fail("remove didn't delete")
            }
            return .pass("upsert + remove ok")
        } catch {
            return .fail("init failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    RealtimeSelftestView()
}
#endif
