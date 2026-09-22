//
//  OperationalRefreshPolicy.swift
//  PowderMeet
//
//  Pure foreground-refresh policy for canonical trail/lift status.
//

import Foundation

nonisolated enum OperationalRefreshPolicy {
    static let refreshLeadTime: TimeInterval = 2 * 60
    static let retryInterval: TimeInterval = 5 * 60

    static func shouldRefresh(
        status: MountainStatus?,
        now: Date,
        lastAttemptAt: Date?
    ) -> Bool {
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < retryInterval {
            return false
        }
        guard let status else { return true }
        guard status.isUsable(at: now) else { return true }
        return status.expiresAt.timeIntervalSince(now) <= refreshLeadTime
    }
}
