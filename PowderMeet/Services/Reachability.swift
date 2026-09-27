//
//  Reachability.swift
//  PowderMeet
//
//  NWPathMonitor wrapper exposing the network state as @Observable so
//  views can render an "offline" banner without owning their own
//  monitor, and services can react to reconnect transitions to flush
//  queued state. Only one monitor instance per process — the singleton
//  is started once at cold launch (from `RealtimeLocationService.init`)
//  and runs for the lifetime of the app.
//
//  Why this exists: PowderMeet is used on chairlifts and lift sheds
//  where cell signal blinks in and out. Without a reachability signal:
//    - There's no UI affordance to distinguish "no friends online" from
//      "you're offline."
//    - Position broadcasts dropped during a tunnel are gone — there's
//      no "flush last known position when signal returns" hop, so
//      friends see the user frozen for ≥ 30s after reconnect.
//
//  Both problems are addressed by exposing `isReachable` for the
//  banner and posting `.networkBecameReachable` for the flush hop.
//

import Foundation
import Network
import Observation

@MainActor @Observable
final class Reachability {
    static let shared = Reachability()

    /// Latest path status. `.satisfied` = some path is usable. The
    /// monitor coalesces transient blips, so brief lift-shed drops
    /// won't flap this.
    private(set) var status: NWPath.Status = .satisfied

    /// Convenience for views.
    var isReachable: Bool { status == .satisfied }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.powdermeet.reachability")
    private var didStart = false

    private init() {}

    /// Idempotent. Safe to call from multiple cold-launch sites; the
    /// second call is a no-op. Posts `.networkBecameReachable` on
    /// `unsatisfied → satisfied` transitions so any service that
    /// queued state during the outage can flush.
    func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            // pathUpdateHandler fires on the monitor's queue; bounce
            // to MainActor for the @Observable property write. Capture
            // self weakly *outside* the Task so the closure body has a
            // local strong reference (the Task closure can't capture
            // the outer `self` directly under Swift 6 strict concurrency).
            let nextStatus = path.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.status
                self.status = nextStatus
                if was != .satisfied, nextStatus == .satisfied {
                    NotificationCenter.default.post(
                        name: .powderMeetNetworkBecameReachable, object: nil
                    )
                }
            }
        }
        monitor.start(queue: queue)
    }
}

extension Notification.Name {
    /// Fires once on every `unsatisfied → satisfied` transition.
    /// `RealtimeLocationService` listens and force-broadcasts the
    /// last known position so friends see a fresh dot the moment
    /// signal returns, rather than waiting for the next 2 s heartbeat.
    static let powderMeetNetworkBecameReachable = Notification.Name("PowderMeetNetworkBecameReachable")
}
