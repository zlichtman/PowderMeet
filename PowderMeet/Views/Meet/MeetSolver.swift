//
//  MeetSolver.swift
//  PowderMeet
//
//  Pure algorithmic core for "given two skiers, find a meeting point" —
//  extracted out of `MeetView.solveMeeting` so the view stays focused
//  on UI orchestration. Used by the meet flow to run the 3-attempt
//  fallback chain (live → forced-open → neighbor-substitution) on a
//  detached `userInitiated` task, returning the result + the produced
//  solver (so the view can reuse `solver.makeContext(for:)` for the
//  post-solve route narrative).
//
//  Inputs are captured as a `Sendable` struct so the detached task
//  closes over plain values, not the View's `@Environment` services.
//  This file contains zero SwiftUI; the only place it talks to the
//  outside world is through `AppLog.meet.debug` (no-op in Release).
//

import Foundation
import CoreLocation

enum MeetSolver {

    /// All inputs the solver needs. Snapshotted on the main actor before
    /// dispatching to the detached compute task.
    struct Inputs: Sendable {
        let myProfile: UserProfile
        let friend: UserProfile
        let graph: MountainGraph
        let myNodeId: String
        let friendNodeId: String
        let entry: ResortEntry?
        let conditions: ResortConditions?
        /// Outer key edge_id, inner key conditions_fp — see
        /// `TraversalContext.observation(for:)` for the lookup rules.
        let edgeSpeeds: [String: [String: PerEdgeSpeed]]
    }

    /// Solver output. `solver` is non-nil when an attempt actually ran
    /// (which is always — even an unconditional failure returns the
    /// solver instance so callers can inspect `lastFailureReason`).
    struct Output: Sendable {
        let result: MeetingResult?
        let failureReason: SolveFailureReason?
        let solver: MeetingPointSolver?
    }

    /// Run the 3-attempt fallback chain. Originally detached to a
    /// background `userInitiated` task, but the user reported that
    /// async timing produced "ghost meeting point" UI (old solve
    /// finishes after the user has already moved on) and slower-feeling
    /// updates. Reverted to inline-on-caller-actor: the meet-cards
    /// pause for a beat during solve but the result is always fresh
    /// for the user's current friend position. Re-introduce the
    /// detach behind a feature flag if the hitch becomes a concern
    /// on bigger resorts.
    static func solve(_ inputs: Inputs) async -> Output {
        let (result, reason, solver): (MeetingResult?, SolveFailureReason?, MeetingPointSolver?) = {
            func configure(for g: MountainGraph) -> MeetingPointSolver {
                let s = MeetingPointSolver(graph: g)
                s.solveTime = Date.now
                if let entry = inputs.entry {
                    s.resortLatitude = (entry.bounds.minLat + entry.bounds.maxLat) / 2
                    s.resortLongitude = (entry.bounds.minLon + entry.bounds.maxLon) / 2
                }
                if let conditions = inputs.conditions {
                    s.temperatureC = conditions.temperatureC
                    s.windSpeedKmh = conditions.windSpeedKph
                    s.freshSnowCm = conditions.snowfallLast24hCm
                    s.visibilityKm = conditions.visibilityKm
                    s.cloudCoverPercent = conditions.cloudCoverPercent
                    s.stationElevationM = conditions.stationElevationM
                }
                // Per-skier edge memory. Local user gets their own
                // currentEdgeSpeeds; the friend gets an empty history so
                // the solver falls back to bucket-only physics for them
                // (their per-edge data lives on their device — no cross-
                // device sync yet).
                s.edgeSpeedHistoryByProfile = [
                    inputs.myProfile.id.uuidString: inputs.edgeSpeeds,
                    inputs.friend.id.uuidString:    [:]
                ]
                s.edgeSpeedHistory = inputs.edgeSpeeds
                return s
            }

            var workingGraph = inputs.graph

            // Attempt 1: solve with live edge status
            let solver1 = configure(for: workingGraph)
            var result = solver1.solve(
                skierA: inputs.myProfile, positionA: inputs.myNodeId,
                skierB: inputs.friend,    positionB: inputs.friendNodeId
            )
            if result != nil { result?.solveAttempt = .live }
            var lastSolver = solver1

            // Attempt 2: retry with all edges open
            if result == nil {
                AppLog.meet.debug("No path with live status — retrying with all edges open")
                for i in workingGraph.edges.indices {
                    workingGraph.edges[i] = GraphEdge(
                        id: workingGraph.edges[i].id,
                        sourceID: workingGraph.edges[i].sourceID,
                        targetID: workingGraph.edges[i].targetID,
                        kind: workingGraph.edges[i].kind,
                        geometry: workingGraph.edges[i].geometry,
                        attributes: {
                            var attrs = workingGraph.edges[i].attributes
                            attrs.isOpen = true
                            return attrs
                        }()
                    )
                }
                workingGraph.rebuildIndices()
                let solver2 = configure(for: workingGraph)
                result = solver2.solve(
                    skierA: inputs.myProfile, positionA: inputs.myNodeId,
                    skierB: inputs.friend,    positionB: inputs.friendNodeId
                )
                if result != nil { result?.solveAttempt = .forcedOpen }
                lastSolver = solver2
            }

            // Attempt 3: try nearest well-connected neighbors
            if result == nil {
                AppLog.meet.debug("Still nil — trying nearest connected neighbor nodes")
                let wellConnected = workingGraph.nodes.values
                    .filter { workingGraph.outgoing(from: $0.id).count >= 2 }
                    .sorted { ($0.elevation, $0.id) < ($1.elevation, $1.id) }

                let myNode = workingGraph.nodes[inputs.myNodeId]
                let friendNode = workingGraph.nodes[inputs.friendNodeId]
                if let myCoord = myNode?.coordinate, let friendCoord = friendNode?.coordinate {
                    let nearMe = wellConnected
                        .sorted { distSq($0.coordinate, myCoord) < distSq($1.coordinate, myCoord) }
                        .prefix(5)
                    let nearFriend = wellConnected
                        .sorted { distSq($0.coordinate, friendCoord) < distSq($1.coordinate, friendCoord) }
                        .prefix(5)

                    outer: for altMe in nearMe {
                        for altFriend in nearFriend {
                            let altSolver = configure(for: workingGraph)
                            if var r = altSolver.solve(
                                skierA: inputs.myProfile, positionA: altMe.id,
                                skierB: inputs.friend,    positionB: altFriend.id
                            ) {
                                r.solveAttempt = .neighborSubstitution
                                result = r
                                AppLog.meet.debug("Fallback solved using \(altMe.id) ↔ \(altFriend.id)")
                                lastSolver = altSolver
                                break outer
                            }
                        }
                    }
                }
            }

            return (result, lastSolver.lastFailureReason, lastSolver)
        }()

        return Output(result: result, failureReason: reason, solver: solver)
    }

    /// Squared distance between two coordinates (for sorting, avoids sqrt).
    /// `nonisolated static` so the detached solve task can call it without
    /// hopping or capturing actor state.
    nonisolated static func distSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dlat = a.latitude - b.latitude
        let dlon = a.longitude - b.longitude
        return dlat * dlat + dlon * dlon
    }
}
