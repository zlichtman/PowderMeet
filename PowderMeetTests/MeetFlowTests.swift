//
//  MeetFlowTests.swift
//  PowderMeetTests
//
//  Smoke coverage for the new MeetView state owner. Pin the default
//  values and verify mutations stick — guards against accidental
//  default flips during the @State → @Observable migration follow-up
//  work.
//

import XCTest
@testable import PowderMeet

@MainActor
final class MeetFlowTests: XCTestCase {

    func testDefaultsAreIdleState() {
        let flow = MeetFlow()
        XCTAssertNil(flow.selectedFriendId)
        XCTAssertNil(flow.selectedOptionIndex)
        XCTAssertFalse(flow.requestSent)
        XCTAssertTrue(flow.pendingProfiles.isEmpty)
        XCTAssertNil(flow.solveErrorMessage)
        XCTAssertNil(flow.solveRecovery)
        XCTAssertNil(flow.fullMeetingResult)
        XCTAssertNil(flow.lastSolvedMyKey)
        XCTAssertFalse(flow.isSolving)
    }

    func testGuidanceIsPausedForOffRouteAndEveryRecoveryState() {
        XCTAssertNil(ActiveRouteRecoveryState.ready.guidanceStatus(isOffRoute: false))
        XCTAssertEqual(ActiveRouteRecoveryState.ready.guidanceStatus(isOffRoute: true), "OFF ROUTE — DIRECTIONS PAUSED")
        for offRoute in [false, true] {
            XCTAssertEqual(ActiveRouteRecoveryState.recalculating.guidanceStatus(isOffRoute: offRoute), "RECALCULATING ROUTE")
            XCTAssertEqual(ActiveRouteRecoveryState.unavailable.guidanceStatus(isOffRoute: offRoute), "ROUTE UNAVAILABLE — DIRECTIONS PAUSED")
            XCTAssertEqual(ActiveRouteRecoveryState.recalculating.etaStatus(isOffRoute: offRoute), "UPDATING")
            XCTAssertEqual(ActiveRouteRecoveryState.unavailable.etaStatus(isOffRoute: offRoute), "UNAVAILABLE")
        }
        XCTAssertNil(ActiveRouteRecoveryState.ready.etaStatus(isOffRoute: false))
        XCTAssertEqual(ActiveRouteRecoveryState.ready.etaStatus(isOffRoute: true), "OFF ROUTE")
    }

    func testFriendTapResetsCommitmentState() {
        // Mirror the body of `MeetView.handleFriendTap` for the
        // "select" branch; the action button shouldn't render
        // requestSent / an old committed option after a fresh selection.
        let flow = MeetFlow()
        flow.fullMeetingResult = nil  // Pretend a previous solve set this.
        flow.selectedOptionIndex = 2
        flow.requestSent = true

        // Simulating handleFriendTap(_) selection branch.
        let newId = UUID()
        flow.selectedFriendId = newId
        flow.fullMeetingResult = nil
        flow.solveErrorMessage = nil
        flow.selectedOptionIndex = nil
        flow.requestSent = false
        flow.lastSolvedMyKey = nil

        XCTAssertEqual(flow.selectedFriendId, newId)
        XCTAssertNil(flow.selectedOptionIndex)
        XCTAssertFalse(flow.requestSent)
    }

    func testOutOfRangePageSnapsBackToZero() {
        // Solver can return fewer alternates on a re-run. The focused card
        // section owns and clamps that presentation-only page locally.
        XCTAssertEqual(MeetingOptionPagePolicy.clamped(5, cardCount: 3), 0)
        XCTAssertEqual(MeetingOptionPagePolicy.clamped(2, cardCount: 3), 2)
        XCTAssertEqual(MeetingOptionPagePolicy.clamped(-1, cardCount: 3), 0)
        XCTAssertEqual(MeetingOptionPagePolicy.clamped(0, cardCount: 0), 0)
    }

    func testMeetingOptionsRemainVisibleForFailureCopy() {
        XCTAssertTrue(MeetOptionsVisibilityPolicy.shouldShow(
            hasResult: false,
            isSolving: false,
            hasError: true
        ))
        XCTAssertFalse(MeetOptionsVisibilityPolicy.shouldShow(
            hasResult: false,
            isSolving: false,
            hasError: false
        ))
    }

    func testTerrainRecoveryOnlyAppearsForCurrentSkierBlocker() {
        let me = UUID()
        let friend = UUID()
        let myFailure = SolveFailureReason.skillGatedPath(diagnostics: [
            SkierCapabilityDiagnostic(
                skierID: me,
                skierName: "Me",
                blockers: [.gladesAvoided]
            )
        ])
        let friendFailure = SolveFailureReason.skillGatedPath(diagnostics: [
            SkierCapabilityDiagnostic(
                skierID: friend,
                skierName: "Friend",
                blockers: [.markedDifficulty(.black)]
            )
        ])

        XCTAssertEqual(
            MeetSolveRecovery.suggested(for: myFailure, currentSkierID: me),
            .reviewTerrainLimits
        )
        XCTAssertNil(MeetSolveRecovery.suggested(
            for: friendFailure,
            currentSkierID: me
        ))
    }

    func testStartingTerrainRecoveryDoesNotPretendSettingsRepairPitchData() {
        let me = UUID()
        for blocker: RunCapabilityBlocker in [.gradientDataUnverified, .invalidGradientLimit, .gradientLimit(maxDegrees: 20)] {
            let diagnostic = SkierCapabilityDiagnostic(skierID: me, skierName: "Me", blockers: [blocker])
            XCTAssertNil(MeetSolveRecovery.suggested(for: .startingTerrainBlocked(diagnostic: diagnostic), currentSkierID: me))
            XCTAssertNil(MeetSolveRecovery.suggested(for: .skillGatedPath(diagnostics: [diagnostic]), currentSkierID: me))
        }
        let actionable = SkierCapabilityDiagnostic(skierID: me, skierName: "Me", blockers: [.mogulsAvoided])
        XCTAssertEqual(MeetSolveRecovery.suggested(for: .startingTerrainBlocked(diagnostic: actionable), currentSkierID: me), .reviewTerrainLimits)
        XCTAssertNil(MeetSolveRecovery.suggested(for: .startingTerrainBlocked(diagnostic: actionable), currentSkierID: UUID()))
    }

    func testActiveMeetupProgressCopyReflectsEachArrivalState() {
        XCTAssertEqual(
            ActiveMeetupProgressCopy.subtitle(
                kindLabel: "LIFT BASE",
                localArrived: false,
                friendArrived: false,
                friendSignalIsLive: true,
                friendName: "Alex",
                localETA: "2M",
                friendETA: "3M",
                togetherETA: "3M"
            ),
            "LIFT BASE · EST. TOGETHER IN 3M"
        )
        XCTAssertEqual(
            ActiveMeetupProgressCopy.subtitle(
                kindLabel: nil,
                localArrived: true,
                friendArrived: false,
                friendSignalIsLive: true,
                friendName: "Alex",
                localETA: "0S",
                friendETA: "1M",
                togetherETA: "1M"
            ),
            "EST. ALEX IN 1M"
        )
        XCTAssertEqual(
            ActiveMeetupProgressCopy.subtitle(
                kindLabel: "LODGE",
                localArrived: false,
                friendArrived: true,
                friendSignalIsLive: true,
                friendName: "Alex",
                localETA: "45S",
                friendETA: "0S",
                togetherETA: "45S"
            ),
            "LODGE · PARTNER NEAR MEETING POINT · YOU IN 45S"
        )
        XCTAssertEqual(
            ActiveMeetupProgressCopy.subtitle(
                kindLabel: "SIGNED MEETING AREA",
                localArrived: true,
                friendArrived: true,
                friendSignalIsLive: true,
                friendName: "Alex",
                localETA: "0S",
                friendETA: "0S",
                togetherETA: "0S"
            ),
            "SIGNED MEETING AREA · BOTH NEAR MEETING POINT"
        )
    }

    func testLostPartnerSignalSuppressesCountdownAndEarlierArrivalClaims() {
        for localArrived in [false, true] {
            for friendArrived in [false, true] {
                let copy = ActiveMeetupProgressCopy.subtitle(
                    kindLabel: "LODGE",
                    localArrived: localArrived,
                    friendArrived: friendArrived,
                    friendSignalIsLive: false,
                    friendName: "Alex",
                    localETA: "2M",
                    friendETA: "3M",
                    togetherETA: "3M"
                )
                XCTAssertEqual(copy, localArrived
                    ? "LODGE · YOU'VE ARRIVED · PARTNER UPDATE NEEDED"
                    : "LODGE · MEET TIME AWAITING PARTNER UPDATE")
            }
        }
    }

    func testUnconfirmedPartnerArrivalSuppressesZeroSecondMeetupPromise() {
        for localArrived in [false, true] {
            let copy = ActiveMeetupProgressCopy.subtitle(kindLabel: nil, localArrived: localArrived,
                friendArrived: false, friendSignalIsLive: true, friendName: "Alex",
                localETA: "0S", friendETA: "0S", togetherETA: "0S", friendArrivalUnconfirmed: true)
            XCTAssertEqual(copy, localArrived ? "YOU'VE ARRIVED · PARTNER ARRIVAL UNCONFIRMED" : "PARTNER ARRIVAL UNCONFIRMED")
        }
    }

    func testRouteRehearsalRequiresPreReleaseIdleDistinctKnownNodes() {
        let nodes: Set<String> = ["me", "partner"]
        XCTAssertTrue(RouteRehearsalPolicy.canPreview(
            isPreRelease: true,
            hasActiveSession: false,
            myNodeID: "me",
            partnerNodeID: "partner",
            availableNodeIDs: nodes
        ))

        XCTAssertFalse(RouteRehearsalPolicy.canPreview(
            isPreRelease: false,
            hasActiveSession: false,
            myNodeID: "me",
            partnerNodeID: "partner",
            availableNodeIDs: nodes
        ))
        XCTAssertFalse(RouteRehearsalPolicy.canPreview(
            isPreRelease: true,
            hasActiveSession: true,
            myNodeID: "me",
            partnerNodeID: "partner",
            availableNodeIDs: nodes
        ))
        XCTAssertFalse(RouteRehearsalPolicy.canPreview(
            isPreRelease: true,
            hasActiveSession: false,
            myNodeID: "me",
            partnerNodeID: "me",
            availableNodeIDs: nodes
        ))
        XCTAssertFalse(RouteRehearsalPolicy.canPreview(
            isPreRelease: true,
            hasActiveSession: false,
            myNodeID: "me",
            partnerNodeID: "missing",
            availableNodeIDs: nodes
        ))
    }

    func testLandmarkRoutingRequiresCanonicalLiveCatalogDestination() {
        let catalog: Set<String> = ["lodge", "patrol"]
        let graph: Set<String> = ["start", "lodge", "patrol"]
        XCTAssertTrue(LandmarkRoutePolicy.canPreview(
            hasActiveSession: false,
            datasetSource: .canonicalServer,
            statusIsRoutable: true,
            destinationNodeID: "lodge",
            catalogNodeIDs: catalog,
            graphNodeIDs: graph
        ))
        XCTAssertFalse(LandmarkRoutePolicy.canPreview(
            hasActiveSession: true,
            datasetSource: .canonicalServer,
            statusIsRoutable: true,
            destinationNodeID: "lodge",
            catalogNodeIDs: catalog,
            graphNodeIDs: graph
        ))
        XCTAssertFalse(LandmarkRoutePolicy.canPreview(
            hasActiveSession: false,
            datasetSource: .legacySnapshot,
            statusIsRoutable: true,
            destinationNodeID: "lodge",
            catalogNodeIDs: catalog,
            graphNodeIDs: graph
        ))
        XCTAssertFalse(LandmarkRoutePolicy.canPreview(
            hasActiveSession: false,
            datasetSource: .canonicalServer,
            statusIsRoutable: false,
            destinationNodeID: "lodge",
            catalogNodeIDs: catalog,
            graphNodeIDs: graph
        ))
        XCTAssertFalse(LandmarkRoutePolicy.canPreview(
            hasActiveSession: false,
            datasetSource: .canonicalServer,
            statusIsRoutable: true,
            destinationNodeID: "arbitrary-junction",
            catalogNodeIDs: catalog,
            graphNodeIDs: graph.union(["arbitrary-junction"])
        ))
    }

    func testPreviewStartOnlyUsesDirectedConnectedLiftBases() {
        let edges = [
            GraphEdge(id: "connected", sourceID: "usable-base", targetID: "lodge",
                      kind: .lift, geometry: [], attributes: EdgeAttributes()),
            GraphEdge(id: "wrong-direction", sourceID: "lodge", targetID: "one-way-base",
                      kind: .run, geometry: [], attributes: EdgeAttributes()),
            GraphEdge(id: "island", sourceID: "isolated-base", targetID: "isolated-top",
                      kind: .lift, geometry: [], attributes: EdgeAttributes())
        ]
        let reachable = LandmarkRoutePolicy.nodesReaching(
            destinationNodeID: "lodge", edges: edges
        )
        XCTAssertTrue(reachable.contains("usable-base"))
        XCTAssertFalse(reachable.contains("one-way-base"))
        XCTAssertFalse(reachable.contains("isolated-base"))
    }

    func testGoToExplainsMissingDataWithoutWeakeningRouting() {
        let preview = LandmarkRoutePolicy.unavailabilityReason(
            hasActiveSession: false, datasetSource: .legacySnapshot,
            statusIsRoutable: false, hasDestinations: true)
        XCTAssertTrue(preview?.contains("preview map") == true)
        let missingStatus = LandmarkRoutePolicy.unavailabilityReason(
            hasActiveSession: false, datasetSource: .canonicalServer,
            statusIsRoutable: false, hasDestinations: true)
        XCTAssertTrue(missingStatus?.contains("closures") == true)
        XCTAssertNotNil(LandmarkRoutePolicy.unavailabilityReason(
            hasActiveSession: false, datasetSource: .canonicalServer,
            statusIsRoutable: true, hasDestinations: false))
        XCTAssertNil(LandmarkRoutePolicy.unavailabilityReason(
            hasActiveSession: false, datasetSource: .canonicalServer,
            statusIsRoutable: true, hasDestinations: true))
    }

    func testUnverifiedGoToPreviewIsConfinedToTestBuildsAndCatalogNodes() {
        let catalog: Set<String> = ["lift"]
        let graph: Set<String> = ["lift", "junction"]
        func allowed(_ preRelease: Bool, _ active: Bool, _ source: MountainDataset.Source?, _ node: String) -> Bool {
            LandmarkRoutePolicy.canUseUnverifiedPreview(
                isPreRelease: preRelease,
                hasActiveSession: active,
                datasetSource: source,
                destinationNodeID: node,
                catalogNodeIDs: catalog,
                graphNodeIDs: graph
            )
        }
        XCTAssertTrue(allowed(true, false, .legacySnapshot, "lift"))
        XCTAssertFalse(allowed(false, false, .legacySnapshot, "lift"))
        XCTAssertFalse(allowed(true, true, .legacySnapshot, "lift"))
        XCTAssertFalse(allowed(true, false, .canonicalServer, "lift"))
        XCTAssertFalse(allowed(true, false, .legacySnapshot, "junction"))
        XCTAssertFalse(allowed(true, false, nil, "lift"))
    }

    func testLandmarkDestinationsUseStableUsefulOrdering() {
        func point(_ id: String, _ kind: RendezvousPoint.Kind, _ name: String) -> RendezvousPoint {
            RendezvousPoint(
                id: id,
                nodeID: id,
                kind: kind,
                displayName: name,
                confidence: 1,
                quality: 1
            )
        }
        let ordered = LandmarkRoutePolicy.orderedDestinations([
            point("lift-b", .liftBase, "Zephyr"),
            point("patrol", .patrol, "Base Patrol"),
            point("lift-a", .liftBase, "Alpine"),
            point("lodge", .lodge, "Summit Lodge"),
        ])
        XCTAssertEqual(ordered.map(\.id), ["lodge", "patrol", "lift-a", "lift-b"])
    }

    func testResortTransitionPreservesOnlyItsOwnActiveMeetup() {
        XCTAssertTrue(ActiveMeetResortTransitionPolicy.preservesActiveMeetup(
            activeResortID: "vail",
            selectedResortID: "vail"
        ))
        XCTAssertFalse(ActiveMeetResortTransitionPolicy.preservesActiveMeetup(
            activeResortID: "vail",
            selectedResortID: "whistler"
        ))
        XCTAssertFalse(ActiveMeetResortTransitionPolicy.preservesActiveMeetup(
            activeResortID: "vail",
            selectedResortID: nil
        ))
        XCTAssertFalse(ActiveMeetResortTransitionPolicy.preservesActiveMeetup(
            activeResortID: nil,
            selectedResortID: "vail"
        ))
    }
}
