//
//  ContentCoordinator+ViewHelpers.swift
//  PowderMeet
//
//  Extension of ContentCoordinator — computed helpers read by ContentView.
//  Split out of ContentCoordinator.swift (behavior-preserving), matching the
//  existing +Conditions / +Ghosts extension pattern. @MainActor inherited.
//

import SwiftUI
import CoreLocation

/// Keeps the pre-release route rehearsal honest and independently testable.
/// The preview is allowed only between two distinct, real nodes while no live
/// social meetup owns the map. Runtime code additionally requires a profile
/// and graph before invoking the solver.
nonisolated enum RouteRehearsalPolicy {
    static func canPreview(
        isPreRelease: Bool,
        hasActiveSession: Bool,
        myNodeID: String,
        partnerNodeID: String,
        availableNodeIDs: Set<String>
    ) -> Bool {
        isPreRelease
            && !hasActiveSession
            && myNodeID != partnerNodeID
            && availableNodeIDs.contains(myNodeID)
            && availableNodeIDs.contains(partnerNodeID)
    }
}

/// Strict gate for local point-to-point routes. Unverified data is usable only
/// for a clearly marked rehearsal in pre-release builds, never live navigation.
nonisolated enum LandmarkRoutePolicy {
    /// Preview start points must have a directed path to the chosen landmark.
    /// Whistler's compatibility graph has disconnected pieces, so choosing
    /// the first alphabetical lift base can fail before the strict solver
    /// even has a viable route to evaluate.
    static func nodesReaching(
        destinationNodeID: String,
        edges: [GraphEdge]
    ) -> Set<String> {
        var incoming: [String: [String]] = [:]
        for edge in edges where edge.attributes.isOpen {
            incoming[edge.targetID, default: []].append(edge.sourceID)
        }
        var reached: Set<String> = [destinationNodeID]
        var frontier = [destinationNodeID]
        while let nodeID = frontier.popLast() {
            for sourceID in incoming[nodeID] ?? [] where reached.insert(sourceID).inserted {
                frontier.append(sourceID)
            }
        }
        return reached
    }

    static func canPreview(
        hasActiveSession: Bool,
        datasetSource: MountainDataset.Source?,
        statusIsRoutable: Bool,
        destinationNodeID: String,
        catalogNodeIDs: Set<String>,
        graphNodeIDs: Set<String>
    ) -> Bool {
        !hasActiveSession
            && datasetSource == .canonicalServer
            && statusIsRoutable
            && catalogNodeIDs.contains(destinationNodeID)
            && graphNodeIDs.contains(destinationNodeID)
    }

    static func canUseUnverifiedPreview(
        isPreRelease: Bool,
        hasActiveSession: Bool,
        datasetSource: MountainDataset.Source?,
        destinationNodeID: String,
        catalogNodeIDs: Set<String>,
        graphNodeIDs: Set<String>
    ) -> Bool {
        isPreRelease
            && !hasActiveSession
            && datasetSource != nil
            && datasetSource != .canonicalServer
            && catalogNodeIDs.contains(destinationNodeID)
            && graphNodeIDs.contains(destinationNodeID)
    }

    static func unavailabilityReason(
        hasActiveSession: Bool,
        datasetSource: MountainDataset.Source?,
        statusIsRoutable: Bool,
        hasDestinations: Bool
    ) -> String? {
        if hasActiveSession { return "End your current meetup before choosing another destination." }
        guard let datasetSource else { return "Wait for the mountain map to finish loading." }
        if datasetSource != .canonicalServer {
            return "This mountain has a preview map. Verified routing data has not been published yet."
        }
        if !hasDestinations { return "No verified destinations have been published for this mountain yet." }
        if !statusIsRoutable {
            return "Current lift and trail status is unavailable. Go To will be available when it can check closures."
        }
        return nil
    }

    static func orderedDestinations(_ points: [RendezvousPoint]) -> [RendezvousPoint] {
        func kindRank(_ kind: RendezvousPoint.Kind) -> Int {
            switch kind {
            case .lodge: return 0
            case .patrol: return 1
            case .signedMeetingArea: return 2
            case .liftBase: return 3
            case .midStation: return 4
            }
        }
        return points.sorted { lhs, rhs in
            let lhsRank = kindRank(lhs.kind)
            let rhsRank = kindRank(rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsName = lhs.displayName ?? lhs.nodeID
            let rhsName = rhs.displayName ?? rhs.nodeID
            let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

extension ContentCoordinator {

    // MARK: - Computed view helpers

    /// User's real GPS coordinate when it belongs to the displayed mountain.
    /// Display eligibility is intentionally broader than route eligibility: a
    /// skier at a lodge or parking area should still see their honest raw dot
    /// even while the strict 65–120 m network corridor refuses navigation.
    ///
    /// Priority matches `resolveMyNodeId`: live GPS at this resort wins
    /// over the tester pick. If GPS is far from the resort (nearestNode
    /// returns nil per its 1000m cap), we fall through to the tester pick;
    /// if neither is available, the dot is hidden — viewing the resort
    /// without being there is supported.
    var snappedUserLocation: CLLocationCoordinate2D? {
        if let rawCoord = locationManager.currentLocation,
           let graph = resortManagerRef?.currentGraph,
           RoutingFixPolicy.isUsable(
                horizontalAccuracyMeters: locationManager.currentAccuracy,
                capturedAt: locationManager.currentFixTimestamp
           ),
           graph.nearestNode(to: rawCoord) != nil {
            return rawCoord
        }
        if let testId = testMyNodeId,
           let node = resortManagerRef?.currentGraph?.nodes[testId] {
            return node.coordinate
        }
        // No GPS at resort, no tester pick — return nil so the map hides
        // the dot rather than placing it at the user's literal GPS coord
        // (which could be hundreds of km away from the displayed resort).
        return nil
    }

    /// True when the timeline is scrolled to a past time and we have
    /// history data.
    var isShowingReplay: Bool {
        selectedTime < Date() && locationHistory.timeRange != nil
    }

    /// Show a short banner. Caller can call again to overwrite — the prior
    /// auto-clear is cancelled and a new one starts. Pass `nil` to clear
    /// immediately.
    func setTransientMessage(_ message: String?) {
        transientMessageClearTask?.cancel()
        transientMessage = message
        guard message != nil else { return }
        transientMessageClearTask = Task { [weak self, transientMessageDurationSeconds] in
            try? await Task.sleep(for: .seconds(transientMessageDurationSeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Only clear if it's still the same message we set —
                // a newer setTransientMessage would have cancelled this
                // task, but be defensive in case the cancellation lost
                // the race with a subsequent set.
                if self.transientMessage == message { self.transientMessage = nil }
            }
        }
    }

    func replayTrails(upTo date: Date) -> [UUID: [CLLocationCoordinate2D]] {
        var result: [UUID: [CLLocationCoordinate2D]] = [:]
        for userId in locationHistory.trackedUserIds {
            let crumbs = locationHistory.trail(for: userId, since: nil)
                .filter { $0.timestamp <= date }
            if crumbs.count >= 2 {
                result[userId] = crumbs.map(\.coordinate)
            }
        }
        return result
    }

    /// Upper bound for the timeline scrubber when a meetup is running —
    /// `startedAt + max(ETA A, ETA B) + 5 min` so the user can scrub
    /// past "now" and see where each skier is expected to be at arrival
    /// time. `nil` when no meetup is active; `TimelineView` falls back
    /// to its default ±12h window.
    var activeMeetupFutureRangeMax: Date? {
        guard let session = activeMeetSession else { return nil }
        return session.routePlanStartedAt.addingTimeInterval(session.meetingResult.maxTime + 5 * 60)
    }

    /// Pre-release-only, local two-skier route rehearsal. It exercises the
    /// same strict solver and map output as a real meet, but never creates a
    /// request/session or marks compatibility data navigable.
    func previewRouteRehearsal(
        myNodeID: String,
        partnerNodeID: String
    ) async -> Bool {
        guard let graph = resortManagerRef?.currentGraph,
              RouteRehearsalPolicy.canPreview(
                isPreRelease: BuildEnvironment.isPreRelease,
                hasActiveSession: activeMeetSession != nil,
                myNodeID: myNodeID,
                partnerNodeID: partnerNodeID,
                availableNodeIDs: Set(graph.nodes.keys)
              ),
              let myProfile = SupabaseManager.shared.currentUserProfile else {
            setTransientMessage("ROUTE REHEARSAL UNAVAILABLE")
            return false
        }

        var partner = UserProfile.defaultProfile(
            id: UUID(uuidString: "D3A00000-0000-4000-8000-000000000001")!
        )
        partner.displayName = "Demo Partner"
        partner.currentResortId = graph.resortID
        partner.applyPreset("advanced")
        partner.onboardingCompleted = true

        let solver = meetup.configureSolver(
            graph: graph,
            participantProfiles: [myProfile, partner]
        )
        let output = await Task.detached(priority: .userInitiated) {
            let result = solver.solve(
                skierA: myProfile,
                positionA: myNodeID,
                skierB: partner,
                positionB: partnerNodeID
            )
            return (result, solver.lastFailureReason)
        }.value
        guard var result = output.0 else {
            setTransientMessage(
                output.1?.userMessage.uppercased()
                    ?? "NO SAFE REHEARSAL ROUTE FOUND"
            )
            return false
        }
        result.solveAttempt = .nonCanonicalDataset
        meetingResult = result
        routeAnimationTrigger &+= 1
        setTransientMessage("ROUTE REHEARSAL · PREVIEW ONLY")
        return true
    }

    var isUnverifiedDestinationPreview: Bool {
        guard let dataset = resortManagerRef?.currentDataset,
              let graph = resortManagerRef?.currentGraph,
              !dataset.rendezvousCatalog.points.isEmpty else { return false }
        return LandmarkRoutePolicy.canUseUnverifiedPreview(
            isPreRelease: BuildEnvironment.isPreRelease,
            hasActiveSession: activeMeetSession != nil,
            datasetSource: dataset.source,
            destinationNodeID: dataset.rendezvousCatalog.points[0].nodeID,
            catalogNodeIDs: dataset.rendezvousCatalog.nodeIDs,
            graphNodeIDs: Set(graph.nodes.keys)
        )
    }

    var destinationRoutingProblem: String? {
        if isUnverifiedDestinationPreview { return nil }
        let dataset = resortManagerRef?.currentDataset
        let status = resortManagerRef?.currentStatus
        let matchedStatus = status?.resortID == dataset?.resortID
            && status?.datasetVersion == dataset?.version
            && status?.isRoutable() == true
        return LandmarkRoutePolicy.unavailabilityReason(
            hasActiveSession: activeMeetSession != nil,
            datasetSource: dataset?.source,
            statusIsRoutable: matchedStatus,
            hasDestinations: dataset?.rendezvousCatalog.points.isEmpty == false
        )
    }

    /// Local route preview. Canonical data requires live status; legacy data is
    /// limited to pre-release, labeled unverified, and never starts navigation.
    func previewLandmarkRoute(to requestedPoint: RendezvousPoint) async -> Bool {
        // A same-dataset graph refresh mid-solve (background status merge on
        // a freshly loaded map) re-solves once on the new graph rather than
        // failing a tap that was made moments after the mountain appeared.
        for attempt in 0..<2 {
            switch await attemptLandmarkRoute(to: requestedPoint) {
            case .finished(let succeeded):
                return succeeded
            case .graphChanged where attempt == 0:
                continue
            case .graphChanged:
                break
            }
        }
        setTransientMessage("Mountain conditions changed while routing. Please try again.")
        return false
    }

    private enum LandmarkRouteAttempt {
        case finished(Bool)
        /// Same immutable dataset, but its displayed graph changed during the solve.
        case graphChanged
    }

    private func attemptLandmarkRoute(to requestedPoint: RendezvousPoint) async -> LandmarkRouteAttempt {
        if let problem = destinationRoutingProblem {
            setTransientMessage(problem)
            return .finished(false)
        }
        guard let dataset = resortManagerRef?.currentDataset,
              let graph = resortManagerRef?.currentGraph,
              let point = dataset.rendezvousCatalog.points.first(where: {
                  $0.id == requestedPoint.id && $0.nodeID == requestedPoint.nodeID
              }),
              let destination = graph.nodes[point.nodeID] else {
            setTransientMessage("DESTINATION PREVIEW UNAVAILABLE")
            return .finished(false)
        }
        let previewOnly = isUnverifiedDestinationPreview
        let status = resortManagerRef?.currentStatus
        let statusIsRoutable = status?.resortID == dataset.resortID
            && status?.datasetVersion == dataset.version
            && status?.isRoutable() == true
        guard previewOnly ? LandmarkRoutePolicy.canUseUnverifiedPreview(
                isPreRelease: BuildEnvironment.isPreRelease,
                hasActiveSession: activeMeetSession != nil,
                datasetSource: dataset.source,
                destinationNodeID: point.nodeID,
                catalogNodeIDs: dataset.rendezvousCatalog.nodeIDs,
                graphNodeIDs: Set(graph.nodes.keys)
              ) : LandmarkRoutePolicy.canPreview(
                hasActiveSession: activeMeetSession != nil,
                datasetSource: dataset.source,
                statusIsRoutable: statusIsRoutable,
                destinationNodeID: point.nodeID,
                catalogNodeIDs: dataset.rendezvousCatalog.nodeIDs,
                graphNodeIDs: Set(graph.nodes.keys)
              ) else {
            setTransientMessage("SAFE DESTINATION ROUTING UNAVAILABLE")
            return .finished(false)
        }
        guard let profile = SupabaseManager.shared.currentUserProfile else {
            setTransientMessage("FINISH YOUR SKIER PROFILE TO ROUTE")
            return .finished(false)
        }
        guard let origin = meetup.resolveMyOrigin(graph: graph) else {
            setTransientMessage(previewOnly
                ? "CHOOSE A PREVIEW START ON THE MOUNTAIN"
                : "MOVE ONTO A MAPPED TRAIL OR SET YOUR TEST LOCATION")
            return .finished(false)
        }
        if origin.startNodeID == point.nodeID, origin.approachEdgeID == nil {
            setTransientMessage("YOU'RE ALREADY AT \((point.displayName ?? "THIS LANDMARK").uppercased())")
            return .finished(false)
        }

        let solver = meetup.configureSolver(
            graph: graph,
            participantProfiles: [profile]
        )
        if previewOnly {
            // A tester may inspect the mountain outside operating hours.
            // With no published status, these hours cannot be treated as
            // live route truth; keep the exercise a timeless graph preview.
            solver.solveTime = nil
        }
        let route = await Task.detached(priority: .userInitiated) {
            solver.pathTo(target: point.nodeID, from: origin, skier: profile)
        }.value
        // A resort switch, updated closure projection, or accepted meetup
        // while the solver was running must not install an obsolete route.
        guard !Task.isCancelled,
              resortManagerRef?.currentDataset?.version == dataset.version,
              resortManagerRef?.currentDataset?.resortID == dataset.resortID,
              destinationRoutingProblem == nil else {
            setTransientMessage("Mountain conditions changed while routing. Please try again.")
            return .finished(false)
        }
        guard resortManagerRef?.currentGraph?.fingerprint == graph.fingerprint else {
            return .graphChanged
        }
        guard let route, !route.path.isEmpty else {
            setTransientMessage(previewOnly
                ? "NO PREVIEW PATH TO THIS LANDMARK"
                : "NO SAFE ROUTE TO THIS LANDMARK")
            return .finished(false)
        }

        var result = MeetingResult(
            meetingNode: destination,
            pathA: route.path,
            pathB: [],
            timeA: route.time,
            timeB: 0,
            alternates: [],
            initialEdgeFractionA: origin.initialFraction(forFirstEdgeID: route.path.first?.id),
            meetingDisplayName: point.displayName,
            rendezvousPoint: point,
            routeReasonA: RouteInstructionBuilder.reason(
                for: route.path,
                profile: profile,
                context: solver.makeContext(for: profile.id.uuidString)
            ),
            etaStdSecondsA: route.etaStdSeconds,
            solveAttempt: previewOnly ? .nonCanonicalDataset : .live
        )
        result.presentationPurpose = previewOnly ? .previewDestination : .destination
        meetingResult = result
        routeAnimationTrigger &+= 1
        setTransientMessage(previewOnly
            ? "UNVERIFIED ROUTE PREVIEW · NOT FOR NAVIGATION"
            : "SAFE ROUTE READY · PREVIEW")
        return .finished(true)
    }
}
