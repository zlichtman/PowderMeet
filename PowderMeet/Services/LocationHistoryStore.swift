//
//  LocationHistoryStore.swift
//  PowderMeet
//
//  Stores timestamped location breadcrumbs for the current user and friends
//  during a ski day. Enables timeline replay of movement on the mountain.
//

import Foundation
import CoreLocation
import Observation

@MainActor @Observable
final class LocationHistoryStore {

    struct Breadcrumb: Identifiable, Sendable {
        let id = UUID()
        let userId: UUID
        let coordinate: CLLocationCoordinate2D
        let timestamp: Date
    }

    /// userId → ordered breadcrumbs (oldest first).
    private(set) var breadcrumbs: [UUID: [Breadcrumb]] = [:]

    /// Minimum interval between stored breadcrumbs per user (seconds).
    private let minInterval: TimeInterval = 10

    /// Hard cap on stored breadcrumbs per user. At the 10s throttle this
    /// covers ~83 minutes of continuous motion before trimming begins —
    /// enough for timeline replay without growing unbounded across a
    /// multi-hour session.
    private let maxBreadcrumbsPerUser = 500

    /// 5-second bucketed cache for `positions(at:)`. Invalidated on every
    /// `append` / `clear`. SwiftUI scrubs call this on every body eval; before
    /// this cache a backwards-drag re-walked every user's crumb list dozens
    /// of times per second.
    private var positionsCache: [Int: [UUID: CLLocationCoordinate2D]] = [:]
    private static let positionsCacheBucketSeconds: TimeInterval = 5

    /// Append a breadcrumb, throttled to `minInterval`.
    func append(userId: UUID, coordinate: CLLocationCoordinate2D) {
        let now = Date()
        if let last = breadcrumbs[userId]?.last,
           now.timeIntervalSince(last.timestamp) < minInterval {
            return
        }
        let crumb = Breadcrumb(userId: userId, coordinate: coordinate, timestamp: now)
        breadcrumbs[userId, default: []].append(crumb)
        if var list = breadcrumbs[userId], list.count > maxBreadcrumbsPerUser {
            list.removeFirst(list.count - maxBreadcrumbsPerUser)
            breadcrumbs[userId] = list
        }
        positionsCache.removeAll(keepingCapacity: true)
    }

    /// Get breadcrumbs for a user, optionally filtered to a time range.
    func trail(for userId: UUID, since: Date? = nil) -> [Breadcrumb] {
        guard let crumbs = breadcrumbs[userId] else { return [] }
        if let since { return crumbs.filter { $0.timestamp >= since } }
        return crumbs
    }

    /// All user IDs with recorded breadcrumbs.
    var trackedUserIds: Set<UUID> { Set(breadcrumbs.keys) }

    /// Time range of all recorded breadcrumbs.
    var timeRange: ClosedRange<Date>? {
        let allCrumbs = breadcrumbs.values.flatMap { $0 }
        guard let first = allCrumbs.min(by: { $0.timestamp < $1.timestamp }),
              let last = allCrumbs.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        return first.timestamp...last.timestamp
    }

    /// Get all user positions at a specific point in time (nearest breadcrumb before `date`).
    func positions(at date: Date) -> [UUID: CLLocationCoordinate2D] {
        let bucket = Int(date.timeIntervalSince1970 / Self.positionsCacheBucketSeconds)
        if let cached = positionsCache[bucket] { return cached }
        var result: [UUID: CLLocationCoordinate2D] = [:]
        for (userId, crumbs) in breadcrumbs {
            // Find the last breadcrumb at or before the given date
            if let crumb = crumbs.last(where: { $0.timestamp <= date }) {
                result[userId] = crumb.coordinate
            }
        }
        positionsCache[bucket] = result
        return result
    }

    /// Clear all history.
    func clear() {
        breadcrumbs.removeAll()
        positionsCache.removeAll(keepingCapacity: true)
    }
}
