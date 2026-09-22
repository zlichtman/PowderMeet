import XCTest
import CoreLocation
@testable import PowderMeet

final class ActiveRouteOperationalValidatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)
    private let version = MountainDatasetVersion(
        manifestVersion: 3,
        graphVersion: "v1",
        contentSHA256: String(repeating: "a", count: 64)
    )

    func testFreshStatusKeepsTwoOpenRoutesValid() {
        XCTAssertEqual(evaluate(), .valid)
    }

    @MainActor
    func testRetainedPartnerRouteKeepsPartialProgressAndIgnoresClosureBehind() throws {
        let dataset = makeDataset()
        let graph = dataset.routingGraph(applying: makeStatus(closedEdgeIDs: ["db"]), at: now)
        let path = [try XCTUnwrap(dataset.graph.edge(byID: "db")),
                    try XCTUnwrap(dataset.graph.edge(byID: "bc"))]
        let solver = MeetingPointSolver(graph: graph)
        let profile = routeProfile()
        let result = try XCTUnwrap(MeetupSessionController().validatedExistingRoute(
            path: path, currentEdgeIndex: 1, currentEdgeFraction: 0.4,
            targetID: "c", profile: profile, graph: graph, solver: solver
        ))
        XCTAssertEqual(result.path.map(\.id), ["bc"])
        XCTAssertEqual(result.initialEdgeFraction, 0.4)
        let expected = try XCTUnwrap(solver.metrics(for: result.path, skier: profile, initialEdgeFraction: 0.4))
        let full = try XCTUnwrap(solver.metrics(for: result.path, skier: profile))
        XCTAssertEqual(result.time, expected.time, accuracy: 0.0001)
        XCTAssertLessThan(result.time, full.time)
        XCTAssertEqual(try XCTUnwrap(result.etaStdSeconds), expected.etaStdSeconds, accuracy: 0.0001)
    }

    @MainActor
    func testRetainedPartnerRouteStillRejectsClosureAheadAndCapabilityMismatch() throws {
        let dataset = makeDataset()
        let path = [try XCTUnwrap(dataset.graph.edge(byID: "db")),
                    try XCTUnwrap(dataset.graph.edge(byID: "bc"))]
        let graph = dataset.routingGraph(applying: makeStatus(closedEdgeIDs: ["bc"]), at: now)
        XCTAssertNil(MeetupSessionController().validatedExistingRoute(
            path: path, currentEdgeIndex: 1, currentEdgeFraction: 0.4,
            targetID: "c", profile: routeProfile(), graph: graph,
            solver: MeetingPointSolver(graph: graph)
        ))
        let openGraph = dataset.routingGraph(applying: makeStatus(), at: now)
        var beginner = routeProfile()
        beginner.skillLevel = "beginner"
        XCTAssertNil(MeetupSessionController().validatedExistingRoute(
            path: path, currentEdgeIndex: 1, currentEdgeFraction: 0.4,
            targetID: "c", profile: beginner, graph: openGraph,
            solver: MeetingPointSolver(graph: openGraph)
        ))
    }

    @MainActor
    func testRetainedPartnerRouteDoesNotTransferCompletedFractionToNextEdge() throws {
        let dataset = makeDataset()
        let graph = dataset.routingGraph(applying: makeStatus(closedEdgeIDs: ["db"]), at: now)
        let path = [try XCTUnwrap(dataset.graph.edge(byID: "db")),
                    try XCTUnwrap(dataset.graph.edge(byID: "bc"))]
        let solver = MeetingPointSolver(graph: graph)
        let result = try XCTUnwrap(MeetupSessionController().validatedExistingRoute(
            path: path, currentEdgeIndex: 0, currentEdgeFraction: 1,
            targetID: "c", profile: routeProfile(), graph: graph, solver: solver
        ))
        XCTAssertEqual(result.path.map(\.id), ["bc"])
        XCTAssertEqual(result.initialEdgeFraction, 0)
        XCTAssertEqual(result.time, try XCTUnwrap(solver.metrics(for: result.path, skier: routeProfile())).time,
                       accuracy: 0.0001)
        let complete = try XCTUnwrap(MeetupSessionController().validatedExistingRoute(
            path: path, currentEdgeIndex: 1, currentEdgeFraction: 1,
            targetID: "c", profile: routeProfile(), graph: graph, solver: solver
        ))
        XCTAssertTrue(complete.path.isEmpty)
        XCTAssertEqual(complete.initialEdgeFraction, 0)
        XCTAssertEqual(complete.time, 0)
    }

    func testRemainingRouteKeepsInitialSolveProgressAndSanitizesInvalidFractions() throws {
        let path = [try XCTUnwrap(makeDataset().graph.edge(byID: "bc"))]
        let partial = ActiveRouteOperationalValidator.remainingRoute(
            path: path, currentEdgeIndex: 0, currentEdgeFraction: 0.6)
        XCTAssertEqual(partial.edgeIDs, ["bc"])
        XCTAssertEqual(partial.initialEdgeFraction, 0.6)
        for fraction in [Double.nan, .infinity, -.infinity, -1] {
            let remaining = ActiveRouteOperationalValidator.remainingRoute(
                path: path, currentEdgeIndex: 0, currentEdgeFraction: fraction)
            XCTAssertEqual(remaining.edgeIDs, ["bc"])
            XCTAssertEqual(remaining.initialEdgeFraction, 0)
        }
    }

    private func routeProfile() -> UserProfile {
        UserProfile(id: UUID(), displayName: "Partner", skillLevel: "intermediate",
                    speedGreen: 7, speedBlue: 5,
                    conditionMoguls: 1, conditionUngroomed: 1, conditionIcy: 1,
                    conditionGladed: 1, onboardingCompleted: true)
    }

    func testClosureOnEitherAcceptedRouteRequiresReroute() {
        XCTAssertEqual(evaluate(closedEdgeIDs: ["bc"]), .routeRequiresReroute)
        XCTAssertEqual(evaluate(closedEdgeIDs: ["db"]), .routeRequiresReroute)
    }

    func testClosureBehindLocalProgressDoesNotInvalidateRemainingRoute() {
        XCTAssertEqual(
            evaluate(localRemainingEdgeIDs: ["bc"], closedEdgeIDs: ["ab"]),
            .valid
        )
    }

    func testClosureBehindFriendProgressDoesNotInvalidateRemainingRoute() {
        XCTAssertEqual(
            evaluate(friendEdgeIDs: ["bc"], closedEdgeIDs: ["db"]),
            .valid
        )
    }

    func testFullyCompletedCurrentEdgeIsExcludedBeforeTrackerIndexAdvances() {
        let path = makeDataset().graph.edges.filter { ["ab", "bc"].contains($0.id) }
            .sorted { $0.id < $1.id }
        XCTAssertEqual(
            ActiveRouteOperationalValidator.remainingEdgeIDs(
                path: path,
                currentEdgeIndex: 0,
                currentEdgeFraction: 1
            ),
            ["bc"]
        )
        XCTAssertEqual(
            ActiveRouteOperationalValidator.remainingEdgeIDs(
                path: path,
                currentEdgeIndex: 0,
                currentEdgeFraction: 0.998
            ),
            ["ab", "bc"]
        )
    }

    func testExpiredOrMismatchedStatusCannotKeepNavigationLive() {
        XCTAssertEqual(evaluate(statusExpiresAt: now.addingTimeInterval(-1)), .statusUnavailable)

        let wrongVersion = MountainDatasetVersion(
            manifestVersion: 4,
            graphVersion: "v1",
            contentSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(evaluate(statusVersion: wrongVersion), .statusUnavailable)
    }

    func testImmutableDatasetChangeIsDistinguishedFromStatusFailure() {
        let dataset = makeDataset()
        let identity = ActiveMeetDatasetIdentity(
            resortID: dataset.resortID,
            datasetVersion: "different-version"
        )
        XCTAssertEqual(
            ActiveRouteOperationalValidator.evaluate(
                identity: identity,
                dataset: dataset,
                status: makeStatus(),
                localRemainingEdgeIDs: ["ab", "bc"],
                friendEdgeIDs: ["db", "bc"],
                meetingNodeID: "c",
                now: now
            ),
            .datasetDrift
        )
    }

    func testOffSeasonEndsRatherThanReroutesActiveMeet() {
        let dataset = makeDataset()
        let status = MountainStatus(
            resortID: dataset.resortID,
            datasetVersion: dataset.version,
            observedAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(300),
            source: .canonicalSidecar,
            operatingMode: .offSeason,
            confidence: 1,
            segmentStates: [:]
        )
        XCTAssertEqual(
            ActiveRouteOperationalValidator.evaluate(
                identity: .init(
                    resortID: dataset.resortID,
                    datasetVersion: dataset.version.identifier
                ),
                dataset: dataset,
                status: status,
                localRemainingEdgeIDs: ["ab", "bc"],
                friendEdgeIDs: ["db", "bc"],
                meetingNodeID: "c",
                now: now
            ),
            .mountainOffSeason
        )
    }

    private func evaluate(
        localRemainingEdgeIDs: [String] = ["ab", "bc"],
        friendEdgeIDs: [String] = ["db", "bc"],
        closedEdgeIDs: Set<String> = [],
        statusExpiresAt: Date? = nil,
        statusVersion: MountainDatasetVersion? = nil
    ) -> ActiveRouteOperationalDecision {
        let dataset = makeDataset()
        return ActiveRouteOperationalValidator.evaluate(
            identity: ActiveMeetDatasetIdentity(
                resortID: dataset.resortID,
                datasetVersion: dataset.version.identifier
            ),
            dataset: dataset,
            status: makeStatus(
                version: statusVersion ?? version,
                expiresAt: statusExpiresAt ?? now.addingTimeInterval(300),
                closedEdgeIDs: closedEdgeIDs
            ),
            localRemainingEdgeIDs: localRemainingEdgeIDs,
            friendEdgeIDs: friendEdgeIDs,
            meetingNodeID: "c",
            now: now
        )
    }

    private func makeDataset() -> MountainDataset {
        let coordinates: [String: CLLocationCoordinate2D] = [
            "a": .init(latitude: 39.603, longitude: -106.30),
            "b": .init(latitude: 39.602, longitude: -106.30),
            "c": .init(latitude: 39.601, longitude: -106.30),
            "d": .init(latitude: 39.602, longitude: -106.31)
        ]
        let nodes = Dictionary(uniqueKeysWithValues: coordinates.map { id, coordinate in
            (id, GraphNode(
                id: id,
                coordinate: coordinate,
                elevation: id == "c" ? 2_800 : 3_000,
                kind: id == "c" ? .liftBase : .junction
            ))
        })
        func edge(_ id: String, _ source: String, _ target: String) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: source,
                targetID: target,
                kind: .run,
                geometry: [coordinates[source]!, coordinates[target]!],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 100,
                    verticalDrop: 50,
                    trailName: id,
                    isOpen: true
                )
            )
        }
        return MountainDataset(
            resortID: "test",
            version: version,
            snapshotDate: "2026-08-13",
            source: .canonicalServer,
            graph: MountainGraph(
                resortID: "test",
                nodes: nodes,
                edges: [edge("ab", "a", "b"), edge("bc", "b", "c"), edge("db", "d", "b")]
            )
        )
    }

    private func makeStatus(
        version: MountainDatasetVersion? = nil,
        expiresAt: Date? = nil,
        closedEdgeIDs: Set<String> = []
    ) -> MountainStatus {
        MountainStatus(
            resortID: "test",
            datasetVersion: version ?? self.version,
            observedAt: now.addingTimeInterval(-30),
            expiresAt: expiresAt ?? now.addingTimeInterval(300),
            source: .canonicalSidecar,
            confidence: 1,
            segmentStates: Dictionary(uniqueKeysWithValues: ["ab", "bc", "db"].map {
                ($0, .init(isOpen: !closedEdgeIDs.contains($0), waitMinutes: nil))
            })
        )
    }
}
