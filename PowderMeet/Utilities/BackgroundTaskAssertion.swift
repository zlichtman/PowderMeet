//
//  BackgroundTaskAssertion.swift
//  PowderMeet
//
//  Asks iOS for a short grace period so a network write started just
//  before suspension (a run saved as the phone locks) can finish.
//

import UIKit

@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    /// Idempotent; also called by the system expiration handler.
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
