//
//  MeetSolver.swift
//  PowderMeet
//
//  Pure algorithmic core for "given two skiers, find a meeting point" —
//  extracted out of `MeetView.solveMeeting` so the view stays focused
//  on UI orchestration. Used by the meet flow to run a strict solve on a
//  detached `userInitiated` task, returning the result + the produced
//  solver (so the view can reuse `solver.makeContext(for:)` for the
//  post-solve route narrative).
//
//  Inputs are captured as a `Sendable` struct so the detached task
//  closes over plain values, not the View's `@Environment` services.
//  The solve is strict: closed terrain, ability gates, and exact skier
//  positions are never relaxed into a route-shaped preview.
//  This file contains zero SwiftUI; the only place it talks to the
//  outside world is through `AppLog.meet.debug` (no-op in Release).
//

import Foundation

enum MeetSolver {

    nonisolated static func routingConditions(
        _ conditions: ResortConditions?,
        at now: Date = .now
    ) -> ResortConditions? {
        guard let conditions, conditions.isFreshForRouting(at: now) else {
            return nil
        }
        return conditions
    }

    nonisolated enum Readiness {
        static func failure(
            isAuthoritativeDataset: Bool,
            hasFreshOperationalStatus: Bool,
            isMountainOffSeason: Bool
        ) -> SolveFailureReason? {
            if isAuthoritativeDataset, isMountainOffSeason {
                return .mountainOffSeason
            }
            guard isAuthoritativeDataset, !hasFreshOperationalStatus else { return nil }
            return .operationalStatusUnavailable
        }
    }

    /// All inputs the solver needs. Snapshotted on the main actor before
    /// dispatching to the detached compute task.
    struct Inputs: Sendable {
        let myProfile: UserProfile
        let friend: UserProfile
        let graph: MountainGraph
        let rendezvousCatalog: RendezvousCatalog
        let datasetVersion: String?
        let isAuthoritativeDataset: Bool
        let hasFreshOperationalStatus: Bool
        let isMountainOffSeason: Bool
        let myOrigin: RoutingOrigin
        let friendOrigin: RoutingOrigin
        var myNodeId: String { myOrigin.startNodeID }
        var friendNodeId: String { friendOrigin.startNodeID }
        let entry: ResortEntry?
        let conditions: ResortConditions?
        /// Outer key edge_id, inner key compound history key — see
        /// `TraversalContext.learnedPace(for:)` for the lookup rules.
        let edgeSpeeds: [String: [String: PerEdgeSpeed]]
        /// Friend's per-edge rolling-speed history. Same shape as
        /// `edgeSpeeds`, populated from `SupabaseManager.friendEdgeSpeeds`
        /// (loaded via friends-only RLS on `profile_edge_speeds`).
        /// Empty dict when the friend has no calibration history or
        /// the load failed — solver falls back to bucket physics for
        /// the friend in that case.
        let friendEdgeSpeeds: [String: [String: PerEdgeSpeed]]
        let myEquipment: SkiPerformanceProfile?
        let friendEquipment: SkiPerformanceProfile?
    }

    /// Solver output. `solver` is non-nil when an attempt actually ran
    /// (which is always — even an unconditional failure returns the
    /// solver instance so callers can inspect `lastFailureReason`).
    struct Output: Sendable {
        let result: MeetingResult?
        let failureReason: SolveFailureReason?
        let solver: MeetingPointSolver?
    }

    /// Run one strict solve. Earlier versions retried by forcing every edge
    /// open and substituting nearby start nodes. Those results were marked
    /// preview-only, but a plausible-looking path across closed terrain is
    /// still unsafe and confusing. A failed strict solve now stays failed so
    /// `SolveFailureReason.userMessage` can tell the user what to change.
    static func solve(_ inputs: Inputs) async -> Output {
        if let failure = Readiness.failure(
            isAuthoritativeDataset: inputs.isAuthoritativeDataset,
            hasFreshOperationalStatus: inputs.hasFreshOperationalStatus,
            isMountainOffSeason: inputs.isMountainOffSeason
        ) {
            return Output(result: nil, failureReason: failure, solver: nil)
        }
        let (result, reason, solver): (MeetingResult?, SolveFailureReason?, MeetingPointSolver?) = {
            func configure(for g: MountainGraph) -> MeetingPointSolver {
                let s = MeetingPointSolver(
                    graph: g,
                    rendezvousCatalog: inputs.rendezvousCatalog
                )
                s.datasetVersion = inputs.datasetVersion
                // Preview maps carry no verified lift hours or status, so
                // their (never-live) solve is timeless — an evening tester
                // would otherwise find every lift closed by the clock.
                s.solveTime = inputs.isAuthoritativeDataset ? Date.now : nil
                if let hours = CuratedResortLoader.load(
                    resortId: g.resortID
                )?.operatingHours {
                    s.liftOpenHour = hours.openHour
                    s.liftCloseHour = hours.closeHour
                }
                if let entry = inputs.entry {
                    s.resortLatitude = (entry.bounds.minLat + entry.bounds.maxLat) / 2
                    s.resortLongitude = (entry.bounds.minLon + entry.bounds.maxLon) / 2
                }
                if let conditions = routingConditions(inputs.conditions) {
                    s.resortUTCOffsetSeconds = conditions.utcOffsetSeconds
                    s.temperatureC = conditions.temperatureC
                    s.windSpeedKmh = conditions.windSpeedKph
                    s.freshSnowCm = conditions.snowfallLast24hCm
                    s.visibilityKm = conditions.visibilityKm
                    s.cloudCoverPercent = conditions.cloudCoverPercent
                    s.stationElevationM = conditions.stationElevationM
                    s.hourlyWeather = conditions.hourlyForecast
                }
                // Per-skier edge memory. Each side gets their own per-edge
                // rolling-speed dict; without this, the friend always fell
                // back to bucketed difficulty and uploading activity files
                // only improved your own half of the route. Friend dict
                // is fetched via friends-only RLS in SupabaseManager —
                // empty on miss, in which case the solver still falls
                // back to bucket physics for that side.
                s.edgeSpeedHistoryByProfile = [
                    inputs.myProfile.id.uuidString: inputs.edgeSpeeds,
                    inputs.friend.id.uuidString:    inputs.friendEdgeSpeeds
                ]
                s.edgeSpeedHistory = inputs.edgeSpeeds
                s.equipmentByProfile = [
                    inputs.myProfile.id.uuidString: inputs.myEquipment,
                    inputs.friend.id.uuidString: inputs.friendEquipment
                ].compactMapValues { $0 }
                return s
            }

            let strictSolver = configure(for: inputs.graph)
            var result = strictSolver.solve(
                skierA: inputs.myProfile, originA: inputs.myOrigin,
                skierB: inputs.friend,    originB: inputs.friendOrigin
            )
            if result != nil {
                result?.solveAttempt = inputs.isAuthoritativeDataset ? .live : .nonCanonicalDataset
            }
            return (result, strictSolver.lastFailureReason, strictSolver)
        }()

        return Output(result: result, failureReason: reason, solver: solver)
    }
}
