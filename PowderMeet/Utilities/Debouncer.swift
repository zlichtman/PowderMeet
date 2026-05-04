//
//  Debouncer.swift
//  PowderMeet
//
//  Simple async debouncer. Scheduling again before the interval elapses
//  cancels the previous pending closure — only the most-recent call fires.
//
//  Intended use: coalesce solver re-runs during a rapid timeline scrub or
//  slider drag so the expensive async work (Dijkstra, route projection) is
//  only paid for the final value.
//

import Foundation

@MainActor
final class Debouncer {
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(interval: Duration) {
        self.interval = interval
    }

    convenience init(milliseconds: Int) {
        self.init(interval: .milliseconds(milliseconds))
    }

    /// Cancels any pending work and schedules a new closure to run after
    /// `interval` has elapsed. If the closure throws `CancellationError`
    /// mid-run (because it awaited and got cancelled), that's expected.
    func schedule(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let interval = self.interval
        task = Task { @MainActor in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    /// Cancel any pending work without scheduling a replacement.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
