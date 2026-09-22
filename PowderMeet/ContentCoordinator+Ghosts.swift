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

        let elapsedPlanSeconds = max(0, selectedTime.timeIntervalSince(session.routePlanStartedAt))

        // Reuse the exact per-skier context factory that built/rerouted the
        // live route. The previous generic context applied the scrubbed
        // instant's weather to every earlier leg and dropped selected skis,
        // learned pace, DST offset, and the hourly timeline entirely.
        let projectionSolver = meetup.configureSolver(
            graph: graph,
            solveTime: session.routePlanStartedAt,
            participantProfiles: [myProfile, session.friendProfile]
        )
        let myContext = projectionSolver.makeContext(for: myProfile.id.uuidString)
        let friendContext = projectionSolver.makeContext(
            for: session.friendProfile.id.uuidString
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

        func trail(
            path: [GraphEdge],
            profile: UserProfile,
            context: TraversalContext,
            initialEdgeFraction: Double,
            headLabel: String
        )
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
                    graph: graph,
                    initialEdgeFraction: initialEdgeFraction
                ) else { continue }
                let label = (i == count) ? headLabel : ""
                out.append((p.coordinate, label))
            }
            return out
        }

        var out: [UUID: [(CLLocationCoordinate2D, String)]] = [:]
        let myTrail = trail(
            path: session.meetingResult.pathA,
            profile: myProfile,
            context: myContext,
            initialEdgeFraction: session.meetingResult.initialEdgeFractionA,
            headLabel: "YOU @ \(timeLabel)"
        )
        if !myTrail.isEmpty { out[myProfile.id] = myTrail }
        let friendTrail = trail(
            path: session.meetingResult.pathB,
            profile: friendProfile,
            context: friendContext,
            initialEdgeFraction: session.meetingResult.initialEdgeFractionB,
            headLabel: "\(friendName) @ \(timeLabel)"
        )
        if !friendTrail.isEmpty { out[friendProfile.id] = friendTrail }
        return out
    }
}
