//
//  MeetupSessionController+ActivateRoute.swift
//  PowderMeet
//
//  Extension of MeetupSessionController — route activation (sender + receiver paths, canonical-manifest force-fetch).
//  Split out of MeetupSessionController.swift (behavior-preserving code motion;
//  the determinism-sensitive receiver path is moved verbatim). @MainActor inherited.
//

import Foundation
import CoreLocation
import SwiftUI
import Supabase

extension MeetupSessionController {
    // MARK: - Activate route

    /// Activates routing when a sent meet request is accepted. Both devices
    /// keep the agreed target but resolve their routes from fresh live origins.
    func activateRoute(for request: MeetRequest) async {
        // Sender and receiver use the same activation path. This prevents the
        // sender's cached card from preserving an older fractional ETA while
        // the receiver resolves from a newer GPS fix.
        await activateRouteShared(for: request, isSender: true)
    }

    func activateRouteAsReceiver(for request: MeetRequest) async {
        await activateRouteShared(for: request, isSender: false)
    }

    func activateRouteShared(for request: MeetRequest, isSender: Bool) async {
        guard let coord = coordinator else { return }
        guard coord.activeMeetSession == nil else {
            if coord.activeMeetSession?.id == request.id {
                coord.meetRequestService.trackActiveRequest(request.id)
            }
            return
        }
        guard activationRequestIDs.insert(request.id).inserted else { return }
        defer { activationRequestIDs.remove(request.id) }

        // Ensure correct resort is loaded — wait for graph before proceeding
        if coord.resortManager.currentGraph == nil || coord.resortManager.currentEntry?.id != request.resortId {
            if let entry = ResortEntry.catalog.first(where: { $0.id == request.resortId }) {
                coord.selectedEntry = entry
                // Pass BOTH the sender's manifest_version AND graph_snapshot_date
                // so the receiver lands on a byte-identical graph. Cross-resort
                // accept used to drop the snapshot date — if sender was at
                // snapshot "2026-04-01" and receiver's default pin resolved to
                // "2026-03-15", the receiver routed against a topologically
                // different graph despite loading the same resort. Null on
                // either parameter falls through to the resort's default
                // resolution (legacy meets / pre-pinned resorts).
                await coord.resortManager.loadResort(
                    entry,
                    snapshotOverride: request.graphSnapshotDate,
                    manifestVersionOverride: request.manifestVersion,
                    datasetVersionOverride: request.datasetVersion
                )
                // Route through the coordinator on this path too — otherwise
                // a meet-request-driven resort load would bypass the snapshot
                // gate and re-introduce the "accept-everyone" window.
                let rtl = coord.ensureRealtimeLocationService()
                let presence = coord.ensurePresenceCoordinator(using: rtl)
                presence.enter(resortId: entry.id)
                await presence.waitForEnter()
            } else {
                AppLog.meet.debug("activateRoute: unknown resort_id \(request.resortId) — add it to ResortCatalog to load trail data")
            }
        } else if let entry = coord.resortManager.currentEntry,
                  (request.manifestVersion != nil && request.manifestVersion != coord.resortManager.currentManifestVersion)
                  || (request.graphSnapshotDate != nil && request.graphSnapshotDate != coord.resortManager.currentSnapshotDate)
                  || (request.datasetVersion != nil && request.datasetVersion != coord.resortManager.currentDataset?.version.identifier) {
            // Same resort already loaded but at a different manifest_version
            // OR snapshot_date than the inbound request stamped. Force-fetch
            // BOTH so we route on byte-identical graphs — either dimension
            // drifting alone is enough to put the two devices on different
            // topologies. Passing nils through is safe; loadResort defaults.
            await coord.resortManager.loadResort(
                entry,
                snapshotOverride: request.graphSnapshotDate,
                manifestVersionOverride: request.manifestVersion,
                datasetVersionOverride: request.datasetVersion
            )
        }

        // A pre-release test meet on a preview map needs the exact same
        // preview map and no status; a live meet needs the exact canonical
        // dataset plus fresh routable status. Neither ever substitutes for
        // the other.
        let isPreviewMeet = PreviewMeetupPolicy.isPreviewIdentity(request.datasetVersion)
        guard let requestedDatasetVersion = request.datasetVersion,
              let dataset = coord.resortManager.currentDataset,
              isPreviewMeet
                ? PreviewMeetupPolicy.canActivate(
                    isPreRelease: BuildEnvironment.isPreRelease,
                    requestDatasetVersion: requestedDatasetVersion,
                    datasetSource: dataset.source,
                    datasetVersion: dataset.version.identifier
                  )
                : Self.canActivateLive(
                    dataset: dataset,
                    requestedDatasetVersion: requestedDatasetVersion,
                    status: coord.resortManager.currentStatus
                  ),
              dataset.rendezvousCatalog.nodeIDs.contains(request.meetingNodeId),
              let myProfile = SupabaseManager.shared.currentUserProfile,
              let graph = coord.resortManager.currentGraph,
              let meetingNode = graph.nodes[request.meetingNodeId] else {
            AppLog.meet.error("activateRoute failed — no profile or graph (check resort catalog for id \(request.resortId))")
            if isPreviewMeet && !BuildEnvironment.isPreRelease {
                coord.setTransientMessage("TEST MEETUPS NEED A TESTFLIGHT BUILD")
            } else if isPreviewMeet {
                coord.setTransientMessage("TEST MEETUP MAP DIFFERS — UPDATE BOTH APPS")
            } else {
                coord.setTransientMessage("SAFE ROUTE UNAVAILABLE — REFRESH MOUNTAIN STATUS")
            }
            return
        }

        let friendId = isSender ? request.receiverId : request.senderId
        if !coord.friendService.friends.contains(where: { $0.id == friendId }) {
            // Acceptance can arrive before the cold-launch social snapshot.
            // Hydrate the authoritative accepted-friend roster once rather
            // than inventing a default ability/speed profile for routing.
            await coord.friendService.loadFriends()
        }
        guard let friendProfile = coord.friendService.friends.first(where: { $0.id == friendId }) else {
            AppLog.meet.error("activateRoute rejected request \(request.id) — authoritative friend profile unavailable")
            coord.setTransientMessage("FRIEND PROFILE UNAVAILABLE — TRY AGAIN")
            return
        }

        let target = request.meetingNodeId

        let myStoredPathIds = isSender ? request.senderPathEdgeIds : request.receiverPathEdgeIds
        let friendStoredPathIds = isSender ? request.receiverPathEdgeIds : request.senderPathEdgeIds
        let myStoredStartID = isSender ? request.senderPositionNodeId : request.receiverPositionNodeId
        let friendStoredStartID = isSender ? request.receiverPositionNodeId : request.senderPositionNodeId
        let myLiveOrigin = resolveMyOrigin(graph: graph)
        let friendLiveOrigin = resolveFriendOrigin(friendId, graph: graph)
        let solver = configureSolver(
            graph: graph,
            participantProfiles: [myProfile, friendProfile]
        )

        guard let myRoute = validatedOrStrictlyResolvedRoute(
            storedEdgeIDs: myStoredPathIds,
            storedStartID: myStoredStartID,
            localOrigin: myLiveOrigin,
            targetID: target,
            profile: myProfile,
            graph: graph,
            solver: solver,
            label: isSender ? "sender local" : "receiver local"
        ), let friendRoute = validatedOrStrictlyResolvedRoute(
            storedEdgeIDs: friendStoredPathIds,
            storedStartID: friendStoredStartID,
            localOrigin: friendLiveOrigin,
            targetID: target,
            profile: friendProfile,
            graph: graph,
            solver: solver,
            label: isSender ? "sender friend" : "receiver friend"
        ) else {
            AppLog.meet.error("activateRoute rejected request \(request.id) — no safe route for both participants")
            coord.setTransientMessage("SAFE ROUTE UNAVAILABLE — REFRESH MOUNTAIN STATUS")
            return
        }

        activateSession(
            request: request,
            friendProfile: friendProfile,
            meetingNode: meetingNode,
            myRoute: myRoute,
            friendRoute: friendRoute,
            graph: graph
        )
    }

    /// Live activation gate: the exact canonical dataset the sender stamped,
    /// with fresh dataset-matched status that permits routing now.
    nonisolated static func canActivateLive(
        dataset: MountainDataset,
        requestedDatasetVersion: String,
        status: MountainStatus?,
        now: Date = .now
    ) -> Bool {
        guard dataset.source == .canonicalServer,
              dataset.version.identifier == requestedDatasetVersion,
              let status else { return false }
        return status.resortID == dataset.resortID
            && status.datasetVersion == dataset.version
            && status.isRoutable(at: now)
    }

    // MARK: - Exact route contract

    struct ActivatedRoute {
        let path: [GraphEdge]
        let time: Double
        let etaStdSeconds: Double
        let initialEdgeFraction: Double
    }

    func validatedOrStrictlyResolvedRoute(
        storedEdgeIDs: [String]?,
        storedStartID: String?,
        localOrigin: RoutingOrigin?,
        targetID: String,
        profile: UserProfile,
        graph: MountainGraph,
        solver: MeetingPointSolver,
        label: String
    ) -> ActivatedRoute? {
        if let localOrigin {
            guard graph.nodes[localOrigin.startNodeID] != nil,
                  let solved = solver.pathTo(
                    target: targetID,
                    from: localOrigin,
                    skier: profile
                  ) else {
                // A fresh fix supersedes request-time location. Falling back
                // to the stored route here would draw and activate a path from
                // where this skier used to be, even though the current strict
                // solve says no safe route exists.
                AppLog.meet.info("activateRoute: fresh origin has no safe \(label) route")
                return nil
            }
            switch StoredRouteValidator.validate(
                edgeIDs: solved.path.map(\.id),
                in: graph,
                expectedStartID: localOrigin.startNodeID,
                targetID: targetID
            ) {
            case .success(let path):
                AppLog.meet.debug("activateRoute: fresh GPS solve succeeded for \(label) (\(path.count) edges)")
                return ActivatedRoute(
                    path: path,
                    time: solved.time,
                    etaStdSeconds: solved.etaStdSeconds,
                    initialEdgeFraction: localOrigin.initialFraction(
                        forFirstEdgeID: path.first?.id
                    )
                )
            case .failure(let failure):
                AppLog.meet.error("activateRoute: fresh GPS solve returned invalid \(label) path: \(String(describing: failure))")
                return nil
            }
        }

        if let stored = validatedStoredRoute(
            edgeIDs: storedEdgeIDs,
            expectedStartID: storedStartID,
            targetID: targetID,
            profile: profile,
            graph: graph,
            solver: solver,
            label: label
        ) {
            AppLog.meet.debug("activateRoute: using exact stored \(label) path (\(stored.path.count) edges)")
            return stored
        }

        AppLog.meet.info("activateRoute: \(label) has neither a safe fresh solve nor a valid stored path")
        return nil
    }

    private func validatedStoredRoute(
        edgeIDs: [String]?,
        expectedStartID: String?,
        targetID: String,
        profile: UserProfile,
        graph: MountainGraph,
        solver: MeetingPointSolver,
        label: String
    ) -> ActivatedRoute? {
        switch StoredRouteValidator.validate(
            edgeIDs: edgeIDs,
            in: graph,
            expectedStartID: expectedStartID,
            targetID: targetID
        ) {
        case .failure(let failure):
            AppLog.meet.info("activateRoute: rejected stored \(label) path: \(String(describing: failure))")
            return nil
        case .success(let path):
            guard let metrics = solver.metrics(
                for: path,
                skier: profile
            ) else {
                AppLog.meet.info("activateRoute: rejected stored \(label) path — current ability/status gate failed")
                return nil
            }
            return ActivatedRoute(
                path: path,
                time: metrics.time,
                etaStdSeconds: metrics.etaStdSeconds,
                initialEdgeFraction: 0
            )
        }
    }

    private func resolveFriendOrigin(_ friendID: UUID, graph: MountainGraph) -> RoutingOrigin? {
        guard let location = coordinator?.realtimeLocation?.friendLocations[friendID],
              FriendSignalClassifier.isEligibleForRouting(
                locationResortID: location.resortId,
                selectedResortID: graph.resortID,
                lastSeen: location.capturedAt,
                accuracyMeters: location.accuracyMeters,
                now: .now
              ) else {
            return nil
        }
        return graph.routingOrigin(
            to: CLLocationCoordinate2D(
                latitude: location.latitude,
                longitude: location.longitude
            ),
            travelCourseDegrees: location.usableTravelCourse,
            altitudeMeters: location.routingAltitudeMeters,
            verticalAccuracyMeters: location.verticalAccuracyMeters,
            maximumSnapDistanceMeters: RoutingFixPolicy.networkSnapTolerance(
                horizontalAccuracyMeters: location.accuracyMeters
            ),
            positionUncertaintyMeters: RoutingFixPolicy.positionUncertaintyMeters(
                horizontalAccuracyMeters: location.accuracyMeters
            )
        )
    }

    private func activateSession(
        request: MeetRequest,
        friendProfile: UserProfile,
        meetingNode: GraphNode,
        myRoute: ActivatedRoute,
        friendRoute: ActivatedRoute,
        graph: MountainGraph
    ) {
        guard let coord = coordinator,
              let dataset = coord.resortManager.currentDataset,
              let localUserID = SupabaseManager.shared.currentSession?.user.id else { return }
        let isPreviewMeet = PreviewMeetupPolicy.canActivate(
            isPreRelease: BuildEnvironment.isPreRelease,
            requestDatasetVersion: request.datasetVersion,
            datasetSource: dataset.source,
            datasetVersion: dataset.version.identifier
        )
        guard dataset.source == .canonicalServer || isPreviewMeet else { return }
        let localRole: ActiveMeetParticipantRole
        if request.senderId == localUserID {
            localRole = .sender
        } else if request.receiverId == localUserID {
            localRole = .receiver
        } else {
            AppLog.meet.error("activateRoute rejected request \(request.id) — local user is not a participant")
            return
        }
        let result = MeetingResult(
            meetingNode: meetingNode,
            pathA: myRoute.path,
            pathB: friendRoute.path,
            timeA: myRoute.time,
            timeB: friendRoute.time,
            alternates: [],
            initialEdgeFractionA: myRoute.initialEdgeFraction,
            initialEdgeFractionB: friendRoute.initialEdgeFraction,
            meetingDisplayName: request.meetingNodeDisplayName,
            rendezvousPoint: dataset.rendezvousCatalog.points.first {
                $0.nodeID == meetingNode.id
            },
            etaStdSecondsA: myRoute.etaStdSeconds,
            etaStdSecondsB: friendRoute.etaStdSeconds,
            solveAttempt: isPreviewMeet ? .nonCanonicalDataset : .live
        )
        lastFasterRerouteAt = .distantPast
        lastAppliedFasterRerouteAt = nil
        coord.meetingResult = result
        let tracker = RouteProgressTracker(
            path: result.pathA,
            graph: graph,
            meetingNodeId: meetingNode.id,
            initialEdgeFraction: myRoute.initialEdgeFraction
        )
        let friendTracker = RouteProgressTracker(
            path: result.pathB,
            graph: graph,
            meetingNodeId: meetingNode.id,
            initialEdgeFraction: friendRoute.initialEdgeFraction
        )
        let activatedAt = Date.now
        coord.activeMeetSession = ActiveMeetSession(
            id: request.id,
            friendProfile: friendProfile,
            localRole: localRole,
            meetingResult: result,
            meetingNodeId: meetingNode.id,
            datasetIdentity: ActiveMeetDatasetIdentity(
                resortID: dataset.resortID,
                datasetVersion: dataset.version.identifier
            ),
            startedAt: activatedAt,
            routePlanStartedAt: activatedAt,
            routeTracker: tracker,
            friendRouteTracker: friendTracker
        )
        coord.meetRequestService.trackActiveRequest(request.id)
        coord.routeAnimationTrigger += 1
    }
}
