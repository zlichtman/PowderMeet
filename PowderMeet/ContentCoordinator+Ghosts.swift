//
//  ContentCoordinator+Ghosts.swift
//  PowderMeet
//
//  Ghost-position computation for scrubbed-time playback during active
//  meetups. The "ghosts" are the projected dots representing where each
//  skier would be along their planned path at a future scrub instant.
//
//  Pure projection — `RouteProjection.skierPosition(at:path:profile:
//  context:graph:)` does the work; this layer just iterates over the
//  scrub interval, builds breadcrumb dots, and labels the head dot
//  with a "YOU @ 3:15PM" / "ALEX @ 3:15PM" tag. Behaviour-equivalent
//  to the inline implementation; pulled out so ContentCoordinator
//  reads against fewer concerns.
//

import Foundation
import CoreLocation

extension ContentCoordinator {

    /// Recomputes the ghost-positions cache when the scrub bucket or
    /// session changes. Called from onChange handlers and from the
    /// session-id watcher.
    func refreshGhostCache(force: Bool) {
        let bucket = Int(selectedTime.timeIntervalSince1970 / Self.ghostCacheBucketSeconds)
        let sessionId = activeMeetSession?.id
        if !force && bucket == cachedGhostBucket && sessionId == cachedGhostSessionId {
            return
        }
        cachedGhostBucket = bucket
        cachedGhostSessionId = sessionId
        cachedGhostPositions = ghostPositionsForScrub()
    }

    /// Computes projected skier positions along each skier's path for
    /// the scrubbed instant. Active only when scrubbing forward during
    /// an active meetup — otherwise returns an empty dictionary so the
    /// ghost layer renders nothing.
    fileprivate func ghostPositionsForScrub() -> [UUID: [(coordinate: CLLocationCoordinate2D, label: String)]] {
        guard let session = activeMeetSession,
              let graph = resortManager.currentGraph,
              selectedTime > Date(),
              let myProfile = SupabaseManager.shared.currentUserProfile else {
            return [:]
        }

        let elapsedPlanSeconds = max(0, selectedTime.timeIntervalSince(session.startedAt))

        let hourly = resortConditions?.atTime(selectedTime)
        let context = TraversalContext(
            solveTime: selectedTime,
            latitude: resortManager.currentEntry.map { ($0.bounds.minLat + $0.bounds.maxLat) / 2 },
            longitude: resortManager.currentEntry.map { ($0.bounds.minLon + $0.bounds.maxLon) / 2 },
            temperatureCelsius: hourly?.temperatureC ?? resortConditions?.temperatureC ?? -2,
            stationElevationM: resortConditions?.stationElevationM ?? 0,
            windSpeedKmh: hourly?.windSpeedKph ?? resortConditions?.windSpeedKph ?? 0,
            visibilityKm: hourly?.visibilityKm ?? resortConditions?.visibilityKm ?? 10,
            freshSnowCm: resortConditions?.snowfallLast24hCm ?? 0,
            cloudCoverPercent: hourly?.cloudCoverPercent ?? resortConditions?.cloudCoverPercent ?? 0
        )

        let timeLabel = Self.ghostTimeFormatter.string(from: selectedTime).uppercased()
        let friendProfile = session.friendProfile
        let friendName = friendProfile.displayName.split(separator: " ").first.map(String.init)?.uppercased() ?? "FRIEND"

        // Breadcrumb spacing along the planned route: ~60s of plan time per
        // dot, capped at 20 dots so very long scrubs don't blow up the ghost
        // layer. Final dot carries the "YOU @ 3:15PM" label; earlier dots are
        // unlabeled.
        let step: TimeInterval = 60
        let maxDots = 20
        let count = min(maxDots, max(1, Int(ceil(elapsedPlanSeconds / step))))
        let actualStep = elapsedPlanSeconds / Double(count)

        func trail(path: [GraphEdge], profile: UserProfile, headLabel: String)
        -> [(coordinate: CLLocationCoordinate2D, label: String)] {
            var out: [(CLLocationCoordinate2D, String)] = []
            out.reserveCapacity(count)
            for i in 1...count {
                let t = actualStep * Double(i)
                guard let p = RouteProjection.skierPosition(
                    at: t,
                    path: path,
                    profile: profile,
                    context: context,
                    graph: graph
                ) else { continue }
                let label = (i == count) ? headLabel : ""
                out.append((p.coordinate, label))
            }
            return out
        }

        var out: [UUID: [(CLLocationCoordinate2D, String)]] = [:]
        let myTrail = trail(path: session.meetingResult.pathA, profile: myProfile, headLabel: "YOU @ \(timeLabel)")
        if !myTrail.isEmpty { out[myProfile.id] = myTrail }
        let friendTrail = trail(path: session.meetingResult.pathB, profile: friendProfile, headLabel: "\(friendName) @ \(timeLabel)")
        if !friendTrail.isEmpty { out[friendProfile.id] = friendTrail }
        return out
    }
}
