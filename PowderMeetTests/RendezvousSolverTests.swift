//
//  RendezvousSolverTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class RendezvousSolverTests: XCTestCase {
    func testUnknownDifficultyDoesNotBecomeEasierTerrain() {
        func metrics(_ difficulty: RunDifficulty?) -> MeetingOptionTradeoff.Metrics {
            let edge = GraphEdge(id: "r", sourceID: "a", targetID: "b", kind: .run,
                                 geometry: [], attributes: EdgeAttributes(difficulty: difficulty, lengthMeters: 100))
            return .init(pathA: [edge], pathB: [], timeA: 100, timeB: 100, stdA: 10, stdB: 10)
        }
        XCTAssertNotEqual(MeetingOptionTradeoff.label(primary: metrics(.black), alternate: metrics(nil), ordinal: 2),
                          "EASIER TERRAIN")
        XCTAssertNotEqual(MeetingOptionTradeoff.primaryLabel(primary: metrics(nil), alternates: [metrics(.black)]),
                          "EASIEST TOP PICK")
    }

    func testMissingOrInvalidUncertaintyCannotAdvertisePredictability() {
        func metrics(_ a: Double?, _ b: Double?) -> MeetingOptionTradeoff.Metrics {
            .init(pathA: [], pathB: [], timeA: 100, timeB: 100, stdA: a, stdB: b)
        }
        let known = metrics(100, 100)
        for missing in [metrics(nil, nil), metrics(nil, 10), metrics(-1, 10), metrics(.nan, 10)] {
            XCTAssertNotEqual(MeetingOptionTradeoff.label(primary: known, alternate: missing, ordinal: 2),
                              "MORE PREDICTABLE")
            XCTAssertNotEqual(MeetingOptionTradeoff.primaryLabel(primary: missing, alternates: [known]),
                              "MOST PREDICTABLE")
        }
        XCTAssertEqual(MeetingOptionTradeoff.label(primary: known, alternate: metrics(0, 0), ordinal: 2),
                       "MORE PREDICTABLE", "Explicit zero is valid evidence; missing is not zero")
    }

    func testTerrainComparisonRequiresRatedRunsAndDoesNotRankParkFeatures() {
        func edge(_ id: String, _ kind: GraphEdge.EdgeKind, _ rating: RunDifficulty?) -> GraphEdge {
            GraphEdge(id: id, sourceID: "a", targetID: "b", kind: kind, geometry: [],
                      attributes: EdgeAttributes(difficulty: rating, lengthMeters: 100))
        }
        func metrics(_ edges: [GraphEdge]) -> MeetingOptionTradeoff.Metrics {
            .init(pathA: edges, pathB: [], timeA: 100, timeB: 100, stdA: 10, stdB: 10)
        }
        let blue = edge("blue", .run, .blue)
        XCTAssertEqual(metrics([blue, edge("lift", .lift, .doubleBlack)]).maxTerrainRank, 1)
        let withLift = MeetingRouteFacts(path: [blue, edge("lift", .lift, .doubleBlack)])
        XCTAssertEqual(withLift.hardestTerrain, .blue)
        XCTAssertNil(metrics([blue, edge("unknown", .run, nil)]).maxTerrainRank)
        let mixedFacts = MeetingRouteFacts(path: [blue, edge("unknown", .run, nil)])
        XCTAssertTrue(mixedFacts.summary?.contains("BLUE MARKED") == true)
        XCTAssertTrue(mixedFacts.summary?.contains("UNRATED SECTIONS") == true)
        XCTAssertFalse(mixedFacts.summary?.contains("BLUE MAX") == true)
        XCTAssertNil(metrics([edge("park", .run, .terrainPark)]).maxTerrainRank)
        XCTAssertEqual(metrics([edge("lift", .lift, nil)]).maxTerrainRank, 0)
    }

    private func profile(_ name: String, skill: String = "intermediate") -> UserProfile {
        UserProfile(
            id: UUID(),
            displayName: name,
            skillLevel: skill,
            speedGreen: 10,
            speedBlue: 10,
            speedBlack: skill == "expert" ? 10 : nil,
            speedDoubleBlack: skill == "expert" ? 10 : nil,
            speedTerrainPark: skill == "expert" ? 10 : nil,
            conditionMoguls: 1,
            conditionUngroomed: 1,
            conditionIcy: 1,
            conditionGladed: 1,
            onboardingCompleted: true
        )
    }

    private func node(_ id: String, kind: GraphNode.NodeKind = .junction, lon: Double) -> GraphNode {
        GraphNode(
            id: id,
            coordinate: .init(latitude: 40, longitude: lon),
            elevation: 2_500,
            kind: kind
        )
    }

    private func edge(
        _ id: String,
        _ source: GraphNode,
        _ target: GraphNode,
        length: Double,
        difficulty: RunDifficulty = .blue,
        isOpen: Bool = true
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source.id,
            targetID: target.id,
            kind: .run,
            geometry: [source.coordinate, target.coordinate],
            attributes: EdgeAttributes(
                difficulty: difficulty,
                lengthMeters: length,
                verticalDrop: 0,
                averageGradient: 0,
                maxGradient: 0,
                isGroomed: true,
                isOpen: isOpen,
                isOfficiallyValidated: true
            )
        )
    }

    private func observation(
        edgeID: String,
        conditions: String,
        variance: Double
    ) -> PerEdgeSpeed {
        PerEdgeSpeed(
            resortId: "test",
            edgeId: edgeID,
            conditionsFp: conditions,
            datasetVersion: "dataset-v1",
            observationCount: 5,
            rollingSpeedMs: 10,
            rollingDurationS: 100,
            rollingSpeedVarianceMs2: variance,
            lastObservedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    func testOnlyExplicitValidatedStoppingPointsAreEligible() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let junction = node("ordinary-junction", lon: -106.02)
        let meet = node("lift-base", kind: .liftBase, lon: -106.03)
        let edges = [
            edge("a-short", a, junction, length: 10),
            edge("b-short", b, junction, length: 10),
            edge("a-meet", a, meet, length: 100),
            edge("b-meet", b, meet, length: 100)
        ]
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, junction.id: junction, meet.id: meet],
            edges: edges
        )
        let catalog = RendezvousCatalog(points: [
            RendezvousPoint(
                id: meet.id,
                nodeID: meet.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            ),
            // Invalid: arbitrary junctions cannot be promoted by a client.
            RendezvousPoint(
                id: junction.id,
                nodeID: junction.id,
                kind: .signedMeetingArea,
                confidence: 1,
                quality: 1
            )
        ], graph: graph)

        XCTAssertEqual(catalog.points.map(\.id), [meet.id])
        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))
        XCTAssertEqual(result.meetingNode.id, meet.id)
        XCTAssertEqual(result.rendezvousPoint?.kind, .liftBase)
        XCTAssertEqual(result.rendezvousPoint?.nodeID, meet.id)
    }

    func testInvalidDuplicateCannotConsumeAValidStableID() {
        let start = node("start", lon: -106.00)
        let meet = node("meet", kind: .liftBase, lon: -106.01)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [start.id: start, meet.id: meet],
            edges: [edge("approach", start, meet, length: 100)]
        )
        let invalidFirst = RendezvousPoint(
            id: meet.id,
            nodeID: meet.id,
            kind: .liftBase,
            confidence: 2,
            quality: 1
        )
        let valid = RendezvousPoint(
            id: meet.id,
            nodeID: meet.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )

        XCTAssertEqual(
            RendezvousCatalog(points: [invalidFirst, valid], graph: graph).points,
            [valid]
        )
    }

    func testReliabilityRankBalancesArrivalFairnessAndUncertainty() {
        let nominallyFastButFragile = RendezvousRank(
            latestArrivalSeconds: 99,
            waitSpreadSeconds: 90,
            uncertaintySeconds: 90,
            confidencePenalty: 1,
            qualityPenalty: 1,
            stableID: "z"
        )
        let dependable = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "a"
        )
        XCTAssertLessThan(dependable, nominallyFastButFragile)
        XCTAssertEqual(dependable.reliabilityScoreSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(nominallyFastButFragile.reliabilityScoreSeconds, 408, accuracy: 0.001)

        let lowerQuality = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 10,
            confidencePenalty: 1,
            qualityPenalty: 1,
            stableID: "z"
        )
        let higherQuality = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 10,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "a"
        )
        XCTAssertLessThan(higherQuality, lowerQuality)
    }

    func testWeatherAwareWaitPenaltyOnlyIncreasesForHazardousExposure() {
        let clearLiftBase = SolverConstants.Scoring.weatherAwareWaitPenaltyAlpha(
            temperatureCelsius: -5,
            windSpeedKmh: 15,
            visibilityKm: 10,
            rendezvousKind: .liftBase
        )
        let harshLiftBase = SolverConstants.Scoring.weatherAwareWaitPenaltyAlpha(
            temperatureCelsius: -25,
            windSpeedKmh: 70,
            visibilityKm: 0.25,
            rendezvousKind: .liftBase
        )
        let harshLodge = SolverConstants.Scoring.weatherAwareWaitPenaltyAlpha(
            temperatureCelsius: -25,
            windSpeedKmh: 70,
            visibilityKm: 0.25,
            rendezvousKind: .lodge
        )

        XCTAssertEqual(
            clearLiftBase,
            SolverConstants.Scoring.waitPenaltyAlpha,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(harshLiftBase, harshLodge)
        XCTAssertGreaterThan(harshLodge, clearLiftBase)
        XCTAssertLessThanOrEqual(harshLiftBase, 1.5)
    }

    func testWeatherAwareWaitCostCanChangeRendezvousChoice() {
        let clearExposed = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 50,
            uncertaintySeconds: 0,
            waitPenaltyAlpha: SolverConstants.Scoring.weatherAwareWaitPenaltyAlpha(
                temperatureCelsius: -5,
                windSpeedKmh: 15,
                visibilityKm: 10,
                rendezvousKind: .liftBase
            ),
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "exposed"
        )
        let sheltered = RendezvousRank(
            latestArrivalSeconds: 135,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "sheltered"
        )
        let harshExposed = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 50,
            uncertaintySeconds: 0,
            waitPenaltyAlpha: SolverConstants.Scoring.weatherAwareWaitPenaltyAlpha(
                temperatureCelsius: -25,
                windSpeedKmh: 70,
                visibilityKm: 0.25,
                rendezvousKind: .liftBase
            ),
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "exposed"
        )

        XCTAssertLessThan(clearExposed, sheltered)
        XCTAssertLessThan(sheltered, harshExposed)
    }

    func testWeatherWaitExplanationIsQuietNormallyAndNamesShelterHonestly() {
        XCTAssertNil(RendezvousWaitExplanation.copy(
            temperatureCelsius: -5,
            windSpeedKmh: 15,
            visibilityKm: 10,
            rendezvousKind: .liftBase
        ))
        XCTAssertEqual(RendezvousWaitExplanation.copy(
            temperatureCelsius: -20,
            windSpeedKmh: 50,
            visibilityKm: 10,
            rendezvousKind: .lodge
        ), "SHELTERED STOP REDUCES COLD + WIND WAIT EXPOSURE")
        XCTAssertEqual(RendezvousWaitExplanation.copy(
            temperatureCelsius: -5,
            windSpeedKmh: 15,
            visibilityKm: 0.5,
            rendezvousKind: .liftBase
        ), "LOW VISIBILITY MAKES ARRIVAL SYNC MORE IMPORTANT")
    }

    func testSolverSurfacesHarshWeatherWaitContextOnItsResult() throws {
        let a = node("context-a", lon: -106.00)
        let b = node("context-b", lon: -106.01)
        let meet = node("context-meet", kind: .liftBase, lon: -106.02)
        let graph = MountainGraph(
            resortID: "weather-wait-context",
            nodes: [a, b, meet].reduce(into: [:]) { $0[$1.id] = $1 },
            edges: [
                edge("context-a-meet", a, meet, length: 100),
                edge("context-b-meet", b, meet, length: 50),
            ]
        )
        let catalog = RendezvousCatalog(points: [
            RendezvousPoint(
                id: meet.id,
                nodeID: meet.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            ),
        ], graph: graph)
        let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
        solver.stationElevationM = 2_500
        solver.temperatureC = -20
        solver.windSpeedKmh = 50
        solver.visibilityKm = 10

        let result = try XCTUnwrap(solver.solve(
            skierA: profile("A"),
            positionA: a.id,
            skierB: profile("B"),
            positionB: b.id
        ))
        XCTAssertEqual(
            result.rendezvousReason,
            "COLD + WIND MAKES ARRIVAL SYNC MORE IMPORTANT"
        )
    }

    func testRendezvousQualityCanBeatANominallyFasterPoorStopWithoutDominatingTravel() {
        let poorStop = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            confidencePenalty: 0.4,
            qualityPenalty: 0.5,
            stableID: "poor"
        )
        let clearStop = RendezvousRank(
            latestArrivalSeconds: 150,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "clear"
        )
        XCTAssertLessThan(clearStop, poorStop)

        let muchFartherClearStop = RendezvousRank(
            latestArrivalSeconds: 300,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "far"
        )
        XCTAssertLessThan(poorStop, muchFartherClearStop)
    }

    func testSharedContinuationIsUsefulButNeverDominatesTravelTime() {
        let terminal = RendezvousRank(
            latestArrivalSeconds: 100,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            continuationPenalty: 1,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "terminal"
        )
        let usefulHub = RendezvousRank(
            latestArrivalSeconds: 125,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            continuationPenalty: 0,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "hub"
        )
        let farHub = RendezvousRank(
            latestArrivalSeconds: 175,
            waitSpreadSeconds: 0,
            uncertaintySeconds: 0,
            continuationPenalty: 0,
            confidencePenalty: 0,
            qualityPenalty: 0,
            stableID: "far"
        )

        XCTAssertLessThan(usefulHub, terminal)
        XCTAssertLessThan(terminal, farHub)
    }

    func testSolverPrefersAUsefulSharedContinuationWithinTheBoundedCost() throws {
        func winner(usefulHubLength: Double) throws -> String {
            MeetingPointSolver.solutionCache.clear()
            let a = node("continue-a", lon: -106.00)
            let b = node("continue-b", lon: -106.01)
            let terminal = node("terminal", kind: .liftBase, lon: -106.02)
            let useful = node("useful", kind: .liftBase, lon: -106.03)
            let onward = node("onward", lon: -106.04)
            let graph = MountainGraph(
                resortID: "continuation-\(Int(usefulHubLength))",
                nodes: [
                    a.id: a, b.id: b, terminal.id: terminal,
                    useful.id: useful, onward.id: onward,
                ],
                edges: [
                    edge("a-terminal", a, terminal, length: 100),
                    edge("b-terminal", b, terminal, length: 100),
                    edge("a-useful", a, useful, length: usefulHubLength),
                    edge("b-useful", b, useful, length: usefulHubLength),
                    edge("shared-onward", useful, onward, length: 100),
                ]
            )
            let catalog = RendezvousCatalog(points: [
                RendezvousPoint(
                    id: terminal.id,
                    nodeID: terminal.id,
                    kind: .liftBase,
                    confidence: 1,
                    quality: 1
                ),
                RendezvousPoint(
                    id: useful.id,
                    nodeID: useful.id,
                    kind: .liftBase,
                    confidence: 1,
                    quality: 1
                ),
            ], graph: graph)
            return try XCTUnwrap(MeetingPointSolver(
                graph: graph,
                rendezvousCatalog: catalog
            ).solve(
                skierA: profile("A"), positionA: a.id,
                skierB: profile("B"), positionB: b.id
            )).meetingNode.id
        }

        XCTAssertEqual(try winner(usefulHubLength: 300), "useful")
        XCTAssertEqual(try winner(usefulHubLength: 700), "terminal")
    }

    func testDeadEndConnectorDoesNotMasqueradeAsUsefulSharedContinuation() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("rollout-a", lon: -106.00)
        let b = node("rollout-b", lon: -106.01)
        let deadStop = node("a-dead-stop", kind: .liftBase, lon: -106.02)
        let usefulStop = node("z-useful-stop", kind: .liftBase, lon: -106.03)
        let deadEnd = node("dead-end", lon: -106.04)
        let sharedRunEnd = node("shared-run-end", lon: -106.05)
        let graph = MountainGraph(
            resortID: "continuation-rollout",
            nodes: [
                a.id: a, b.id: b, deadStop.id: deadStop,
                usefulStop.id: usefulStop, deadEnd.id: deadEnd,
                sharedRunEnd.id: sharedRunEnd,
            ],
            edges: [
                edge("a-dead", a, deadStop, length: 100),
                edge("b-dead", b, deadStop, length: 100),
                edge("a-useful", a, usefulStop, length: 100),
                edge("b-useful", b, usefulStop, length: 100),
                GraphEdge(
                    id: "tiny-dead-connector",
                    sourceID: deadStop.id,
                    targetID: deadEnd.id,
                    kind: .traverse,
                    geometry: [],
                    attributes: EdgeAttributes(lengthMeters: 20, isOpen: true)
                ),
                GraphEdge(
                    id: "shared-real-run",
                    sourceID: usefulStop.id,
                    targetID: sharedRunEnd.id,
                    kind: .run,
                    geometry: [usefulStop.coordinate, sharedRunEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 100,
                        trailName: "Homeward",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
            ]
        )
        let catalog = RendezvousCatalog(points: [deadStop, usefulStop].map {
            RendezvousPoint(
                id: $0.id,
                nodeID: $0.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )
        }, graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        XCTAssertEqual(result.meetingNode.id, usefulStop.id)
        XCTAssertEqual(result.sharedContinuation?.edgeID, "shared-real-run")
        XCTAssertEqual(
            result.sharedContinuation?.cardCopy,
            "BOTH CAN SKI HOMEWARD NEXT"
        )
    }

    func testSharedLiftRequiresMutuallyUsableTerrainBeyondItsTop() throws {
        func solve(hasDownstreamRun: Bool) throws -> MeetingResult {
            MeetingPointSolver.solutionCache.clear()
            let a = node("lift-rollout-a", lon: -106.00)
            let b = node("lift-rollout-b", lon: -106.01)
            let base = node("lift-rollout-base", kind: .liftBase, lon: -106.02)
            let top = node("lift-rollout-top", kind: .liftTop, lon: -106.03)
            let runEnd = node("lift-rollout-run-end", lon: -106.04)
            var edges: [GraphEdge] = [
                edge("a-base", a, base, length: 100),
                edge("b-base", b, base, length: 100),
                GraphEdge(
                    id: "summit-chair",
                    sourceID: base.id,
                    targetID: top.id,
                    kind: .lift,
                    geometry: [base.coordinate, top.coordinate],
                    attributes: EdgeAttributes(
                        lengthMeters: 500,
                        verticalDrop: -200,
                        trailName: "Summit Chair",
                        liftType: .chairLift,
                        rideTimeSeconds: 240,
                        isOpen: true
                    )
                ),
            ]
            if hasDownstreamRun {
                edges.append(GraphEdge(
                    id: "summit-cruiser",
                    sourceID: top.id,
                    targetID: runEnd.id,
                    kind: .run,
                    geometry: [top.coordinate, runEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 300,
                        verticalDrop: 100,
                        trailName: "Summit Cruiser",
                        isGroomed: true,
                        isOpen: true
                    )
                ))
            }
            let graph = MountainGraph(
                resortID: "lift-rollout-\(hasDownstreamRun)",
                nodes: [
                    a.id: a, b.id: b, base.id: base,
                    top.id: top, runEnd.id: runEnd,
                ],
                edges: edges
            )
            let catalog = RendezvousCatalog(points: [RendezvousPoint(
                id: base.id,
                nodeID: base.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )], graph: graph)
            return try XCTUnwrap(MeetingPointSolver(
                graph: graph,
                rendezvousCatalog: catalog
            ).solve(
                skierA: profile("A"), positionA: a.id,
                skierB: profile("B"), positionB: b.id
            ))
        }

        let useful = try solve(hasDownstreamRun: true)
        XCTAssertEqual(useful.sharedContinuation?.edgeID, "summit-chair")
        XCTAssertEqual(useful.sharedContinuation?.kind, .ride)
        XCTAssertEqual(useful.sharedContinuation?.cardCopy, "BOTH CAN RIDE SUMMIT CHAIR NEXT")

        let stranded = try solve(hasDownstreamRun: false)
        XCTAssertNil(stranded.sharedContinuation)
    }

    func testSharedContinuationRecognizesLapReturningToMeetingBase() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("loop-a", lon: -106.00)
        let b = node("loop-b", lon: -106.01)
        let base = node("loop-base", kind: .liftBase, lon: -106.02)
        let top = node("loop-top", kind: .liftTop, lon: -106.03)
        let graph = MountainGraph(
            resortID: "shared-lap-loop",
            nodes: [a.id: a, b.id: b, base.id: base, top.id: top],
            edges: [
                edge("loop-a-base", a, base, length: 100),
                edge("loop-b-base", b, base, length: 100),
                GraphEdge(
                    id: "loop-chair",
                    sourceID: base.id,
                    targetID: top.id,
                    kind: .lift,
                    geometry: [base.coordinate, top.coordinate],
                    attributes: EdgeAttributes(
                        lengthMeters: 700,
                        verticalDrop: -250,
                        trailName: "Loop Chair",
                        liftType: .chairLift,
                        rideTimeSeconds: 300,
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "home-lap",
                    sourceID: top.id,
                    targetID: base.id,
                    kind: .run,
                    geometry: [top.coordinate, base.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 600,
                        verticalDrop: 250,
                        trailName: "Home Lap",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
            ]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: base.id,
            nodeID: base.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        XCTAssertEqual(result.sharedContinuation?.edgeID, "loop-chair")
        XCTAssertEqual(result.sharedContinuation?.kind, .ride)
        XCTAssertEqual(result.sharedContinuation?.sharedRunLengthMeters, 600)
        XCTAssertEqual(result.sharedContinuation?.sharedVerticalDropMeters, 250)
        XCTAssertEqual(result.sharedContinuation?.cardCopy, "BOTH CAN RIDE LOOP CHAIR NEXT")
    }

    func testSharedLiftThroughConnectorStillRequiresDownhillTerrain() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("connector-a", lon: -106.00)
        let b = node("connector-b", lon: -106.01)
        let base = node("connector-base", kind: .liftBase, lon: -106.02)
        let top = node("connector-top", kind: .liftTop, lon: -106.03)
        let deadEnd = node("connector-dead-end", lon: -106.04)
        let graph = MountainGraph(
            resortID: "lift-connector-dead-end",
            nodes: [
                a.id: a, b.id: b, base.id: base,
                top.id: top, deadEnd.id: deadEnd,
            ],
            edges: [
                edge("connector-a-base", a, base, length: 100),
                edge("connector-b-base", b, base, length: 100),
                GraphEdge(
                    id: "connector-chair",
                    sourceID: base.id,
                    targetID: top.id,
                    kind: .lift,
                    geometry: [base.coordinate, top.coordinate],
                    attributes: EdgeAttributes(
                        lengthMeters: 500,
                        verticalDrop: -200,
                        trailName: "Connector Chair",
                        liftType: .chairLift,
                        rideTimeSeconds: 240,
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "long-dead-connector",
                    sourceID: top.id,
                    targetID: deadEnd.id,
                    kind: .traverse,
                    geometry: [top.coordinate, deadEnd.coordinate],
                    attributes: EdgeAttributes(
                        lengthMeters: 500,
                        trailName: "Service Road",
                        isOpen: true
                    )
                ),
            ]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: base.id,
            nodeID: base.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        XCTAssertNil(result.sharedContinuation)
    }

    func testSharedContinuationChoosesSubstantialRunInsteadOfStableEdgeID() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("choice-a", lon: -106.00)
        let b = node("choice-b", lon: -106.01)
        let base = node("choice-base", kind: .liftBase, lon: -106.02)
        let shortEnd = node("choice-short-end", lon: -106.03)
        let fullEnd = node("choice-full-end", lon: -106.04)
        let graph = MountainGraph(
            resortID: "continuation-quality",
            nodes: [
                a.id: a, b.id: b, base.id: base,
                shortEnd.id: shortEnd, fullEnd.id: fullEnd,
            ],
            edges: [
                edge("choice-a-base", a, base, length: 100),
                edge("choice-b-base", b, base, length: 100),
                GraphEdge(
                    id: "a-short-run",
                    sourceID: base.id,
                    targetID: shortEnd.id,
                    kind: .run,
                    geometry: [base.coordinate, shortEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 100,
                        verticalDrop: 10,
                        trailName: "Short Cut",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "z-full-run",
                    sourceID: base.id,
                    targetID: fullEnd.id,
                    kind: .run,
                    geometry: [base.coordinate, fullEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 800,
                        verticalDrop: 300,
                        trailName: "Full Lap",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
            ]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: base.id,
            nodeID: base.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        XCTAssertEqual(result.sharedContinuation?.edgeID, "z-full-run")
        XCTAssertEqual(result.sharedContinuation?.cardCopy, "BOTH CAN SKI FULL LAP NEXT")
        XCTAssertEqual(result.sharedContinuation?.sharedRunLengthMeters, 800)
        XCTAssertEqual(result.sharedContinuation?.sharedVerticalDropMeters, 300)
        let continuation = try XCTUnwrap(result.sharedContinuation)
        XCTAssertGreaterThan(continuation.jointTerrainFit, 0.9)
        XCTAssertEqual(
            continuation.quality,
            SharedLapUtility.score(
                runLengthMeters: 800,
                verticalDropMeters: 300,
                actionTransitionCount: 0,
                downhillAccessSeconds: 0,
                jointTerrainFit: continuation.jointTerrainFit
            ),
            accuracy: 0.0001
        )
    }

    func testRendezvousRankRewardsSubstantialSharedLapOverTokenRun() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("lap-rank-a", lon: -106.00)
        let b = node("lap-rank-b", lon: -106.01)
        let shortHub = node("a-short-hub", kind: .liftBase, lon: -106.02)
        let fullHub = node("z-full-hub", kind: .liftBase, lon: -106.03)
        let shortEnd = node("lap-short-end", lon: -106.04)
        let fullEnd = node("lap-full-end", lon: -106.05)
        let graph = MountainGraph(
            resortID: "continuation-rank-quality",
            nodes: [
                a.id: a, b.id: b, shortHub.id: shortHub, fullHub.id: fullHub,
                shortEnd.id: shortEnd, fullEnd.id: fullEnd,
            ],
            edges: [
                edge("lap-a-short", a, shortHub, length: 100),
                edge("lap-b-short", b, shortHub, length: 100),
                edge("lap-a-full", a, fullHub, length: 100),
                edge("lap-b-full", b, fullHub, length: 100),
                GraphEdge(
                    id: "token-run",
                    sourceID: shortHub.id,
                    targetID: shortEnd.id,
                    kind: .run,
                    geometry: [shortHub.coordinate, shortEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 75,
                        verticalDrop: 10,
                        trailName: "Token Run",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "proper-shared-lap",
                    sourceID: fullHub.id,
                    targetID: fullEnd.id,
                    kind: .run,
                    geometry: [fullHub.coordinate, fullEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 800,
                        verticalDrop: 300,
                        trailName: "Proper Shared Lap",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
            ]
        )
        let catalog = RendezvousCatalog(points: [shortHub, fullHub].map {
            RendezvousPoint(
                id: $0.id,
                nodeID: $0.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )
        }, graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        // Both rendezvous have equal approach ETAs. The older binary score
        // chose a-short-hub by stable ID because both had "some" run. The
        // continuous score must prefer the genuinely useful shared lap.
        XCTAssertEqual(result.meetingNode.id, fullHub.id)
        XCTAssertEqual(result.sharedContinuation?.edgeID, "proper-shared-lap")
    }

    func testSharedLapQualityIsInvariantToCanonicalRunSegmentation() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("segment-rank-a", lon: -106.00)
        let b = node("segment-rank-b", lon: -106.01)
        let singleHub = node("a-single-hub", kind: .liftBase, lon: -106.02)
        let splitHub = node("z-split-hub", kind: .liftBase, lon: -106.03)
        let singleEnd = node("segment-single-end", lon: -106.04)
        let splitMid = node("segment-split-mid", lon: -106.05)
        let splitEnd = node("segment-split-end", lon: -106.06)
        let graph = MountainGraph(
            resortID: "shared-lap-segmentation",
            nodes: [
                a.id: a, b.id: b, singleHub.id: singleHub,
                splitHub.id: splitHub, singleEnd.id: singleEnd,
                splitMid.id: splitMid, splitEnd.id: splitEnd,
            ],
            edges: [
                edge("segment-a-single", a, singleHub, length: 100),
                edge("segment-b-single", b, singleHub, length: 100),
                edge("segment-a-split", a, splitHub, length: 100),
                edge("segment-b-split", b, splitHub, length: 100),
                GraphEdge(
                    id: "single-cruiser",
                    sourceID: singleHub.id,
                    targetID: singleEnd.id,
                    kind: .run,
                    geometry: [singleHub.coordinate, singleEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 450,
                        verticalDrop: 150,
                        trailName: "Single Cruiser",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "split-cruiser-1",
                    sourceID: splitHub.id,
                    targetID: splitMid.id,
                    kind: .run,
                    geometry: [splitHub.coordinate, splitMid.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 300,
                        verticalDrop: 100,
                        trailName: "Split Cruiser",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
                GraphEdge(
                    id: "split-cruiser-2",
                    sourceID: splitMid.id,
                    targetID: splitEnd.id,
                    kind: .run,
                    geometry: [splitMid.coordinate, splitEnd.coordinate],
                    attributes: EdgeAttributes(
                        difficulty: .blue,
                        lengthMeters: 300,
                        verticalDrop: 100,
                        trailName: "Split Cruiser",
                        isGroomed: true,
                        isOpen: true
                    )
                ),
            ]
        )
        let catalog = RendezvousCatalog(points: [singleHub, splitHub].map {
            RendezvousPoint(
                id: $0.id,
                nodeID: $0.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )
        }, graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        // Equal approach ETAs isolate post-meet utility. The split corridor is
        // physically longer and must win even though its first stored segment
        // is shorter than the single-edge alternative.
        XCTAssertEqual(result.meetingNode.id, splitHub.id)
        XCTAssertEqual(result.sharedContinuation?.edgeID, "split-cruiser-1")
        XCTAssertEqual(result.sharedContinuation?.sharedRunLengthMeters, 600)
        XCTAssertEqual(result.sharedContinuation?.sharedVerticalDropMeters, 200)
        let continuation = try XCTUnwrap(result.sharedContinuation)
        XCTAssertEqual(continuation.sharedRunOptionCount, 1)
        XCTAssertGreaterThan(continuation.jointTerrainFit, 0.9)
        XCTAssertEqual(
            continuation.quality,
            SharedLapUtility.score(
                runLengthMeters: 600,
                verticalDropMeters: 200,
                actionTransitionCount: 0,
                downhillAccessSeconds: 0,
                jointTerrainFit: continuation.jointTerrainFit
            ),
            accuracy: 0.0001
        )
    }

    func testSharedLapUtilityPrefersFasterAccessToEquivalentDownhill() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("access-rank-a", lon: -106.00)
        let b = node("access-rank-b", lon: -106.01)
        let slowHub = node("a-slow-hub", kind: .liftBase, lon: -106.02)
        let fastHub = node("z-fast-hub", kind: .liftBase, lon: -106.03)
        let slowTop = node("access-slow-top", kind: .liftTop, lon: -106.04)
        let fastTop = node("access-fast-top", kind: .liftTop, lon: -106.05)
        let slowEnd = node("access-slow-end", lon: -106.06)
        let fastEnd = node("access-fast-end", lon: -106.07)

        func lift(
            _ id: String,
            from source: GraphNode,
            to target: GraphNode,
            waitMinutes: Double
        ) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: source.id,
                targetID: target.id,
                kind: .lift,
                geometry: [source.coordinate, target.coordinate],
                attributes: EdgeAttributes(
                    lengthMeters: 700,
                    verticalDrop: -300,
                    trailName: id,
                    liftType: .chairLift,
                    rideTimeSeconds: 300,
                    waitTimeMinutes: waitMinutes,
                    isOpen: true
                )
            )
        }

        func run(
            _ id: String,
            from source: GraphNode,
            to target: GraphNode
        ) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: source.id,
                targetID: target.id,
                kind: .run,
                geometry: [source.coordinate, target.coordinate],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 800,
                    verticalDrop: 300,
                    trailName: "Equivalent Cruiser",
                    isGroomed: true,
                    isOpen: true
                )
            )
        }

        let graph = MountainGraph(
            resortID: "shared-lap-access-time",
            nodes: [
                a.id: a, b.id: b, slowHub.id: slowHub, fastHub.id: fastHub,
                slowTop.id: slowTop, fastTop.id: fastTop,
                slowEnd.id: slowEnd, fastEnd.id: fastEnd,
            ],
            edges: [
                edge("access-a-slow", a, slowHub, length: 100),
                edge("access-b-slow", b, slowHub, length: 100),
                edge("access-a-fast", a, fastHub, length: 100),
                edge("access-b-fast", b, fastHub, length: 100),
                lift("slow-chair", from: slowHub, to: slowTop, waitMinutes: 25),
                lift("fast-chair", from: fastHub, to: fastTop, waitMinutes: 0),
                run("slow-cruiser", from: slowTop, to: slowEnd),
                run("fast-cruiser", from: fastTop, to: fastEnd),
            ]
        )
        func point(_ node: GraphNode) -> RendezvousPoint {
            RendezvousPoint(
                id: node.id,
                nodeID: node.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )
        }
        func solve(_ points: [RendezvousPoint]) throws -> MeetingResult {
            try XCTUnwrap(MeetingPointSolver(
                graph: graph,
                rendezvousCatalog: RendezvousCatalog(points: points, graph: graph)
            ).solve(
                skierA: profile("A"), positionA: a.id,
                skierB: profile("B"), positionB: b.id
            ))
        }

        let slowOnly = try solve([point(slowHub)])
        let fastOnly = try solve([point(fastHub)])
        let ranked = try solve([point(slowHub), point(fastHub)])

        XCTAssertGreaterThan(
            slowOnly.sharedContinuation?.downhillAccessSeconds ?? 0,
            (fastOnly.sharedContinuation?.downhillAccessSeconds ?? 0) + 10 * 60
        )
        XCTAssertLessThan(
            slowOnly.sharedContinuation?.quality ?? 1,
            fastOnly.sharedContinuation?.quality ?? 0
        )
        // Before time-to-downhill entered utility, equal approach and physical
        // run metrics selected a-slow-hub only because its ID sorted first.
        XCTAssertEqual(ranked.meetingNode.id, fastHub.id)
        XCTAssertEqual(ranked.sharedContinuation?.edgeID, "fast-chair")
    }

    func testSharedLapUtilityPrefersTerrainThatFitsBothSkiers() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("fit-rank-a", lon: -106.00)
        let b = node("fit-rank-b", lon: -106.01)
        let technicalHub = node("a-technical-hub", kind: .liftBase, lon: -106.02)
        let groomedHub = node("z-groomed-hub", kind: .liftBase, lon: -106.03)
        let technicalEnd = node("fit-technical-end", lon: -106.04)
        let groomedEnd = node("fit-groomed-end", lon: -106.05)

        func run(
            _ id: String,
            from source: GraphNode,
            to target: GraphNode,
            moguls: Bool,
            groomed: Bool
        ) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: source.id,
                targetID: target.id,
                kind: .run,
                geometry: [source.coordinate, target.coordinate],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 600,
                    verticalDrop: 200,
                    trailName: id,
                    hasMoguls: moguls,
                    isGroomed: groomed,
                    isOpen: true
                )
            )
        }

        let technicalRun = run(
            "technical-descent",
            from: technicalHub,
            to: technicalEnd,
            moguls: true,
            groomed: false
        )
        let groomedRun = run(
            "groomed-descent",
            from: groomedHub,
            to: groomedEnd,
            moguls: false,
            groomed: true
        )
        let graph = MountainGraph(
            resortID: "shared-lap-joint-fit",
            nodes: [
                a.id: a, b.id: b, technicalHub.id: technicalHub,
                groomedHub.id: groomedHub, technicalEnd.id: technicalEnd,
                groomedEnd.id: groomedEnd,
            ],
            edges: [
                edge("fit-a-technical", a, technicalHub, length: 100),
                edge("fit-b-technical", b, technicalHub, length: 100),
                edge("fit-a-groomed", a, groomedHub, length: 100),
                edge("fit-b-groomed", b, groomedHub, length: 100),
                technicalRun,
                groomedRun,
            ]
        )
        func point(_ node: GraphNode) -> RendezvousPoint {
            RendezvousPoint(
                id: node.id,
                nodeID: node.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )
        }
        func cautiousProfile(_ name: String) -> UserProfile {
            var skier = profile(name)
            skier.conditionMoguls = 0.2
            skier.mogulTolerance = 0.2
            skier.conditionUngroomed = 0.2
            return skier
        }
        let skierA = cautiousProfile("A")
        let skierB = cautiousProfile("B")
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 2_500,
            windSpeedKmh: 0,
            visibilityKm: 10,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )
        XCTAssertNotNil(skierA.traverseTime(for: technicalRun, context: context))
        XCTAssertNotNil(skierB.traverseTime(for: technicalRun, context: context))

        func solve(_ points: [RendezvousPoint]) throws -> MeetingResult {
            try XCTUnwrap(MeetingPointSolver(
                graph: graph,
                rendezvousCatalog: RendezvousCatalog(points: points, graph: graph)
            ).solve(
                skierA: skierA, positionA: a.id,
                skierB: skierB, positionB: b.id
            ))
        }

        let technicalOnly = try solve([point(technicalHub)])
        let groomedOnly = try solve([point(groomedHub)])
        let ranked = try solve([point(technicalHub), point(groomedHub)])

        XCTAssertLessThan(
            technicalOnly.sharedContinuation?.jointTerrainFit ?? 1,
            groomedOnly.sharedContinuation?.jointTerrainFit ?? 0
        )
        // Both runs are open, blue, and physically identical. Before joint fit
        // entered utility, a-technical-hub won only because its ID sorted first.
        XCTAssertEqual(ranked.meetingNode.id, groomedHub.id)
        XCTAssertEqual(ranked.sharedContinuation?.edgeID, "groomed-descent")
    }

    func testRendezvousSoftlyPrefersSeveralViableSharedRuns() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("variety-a", lon: -106.00)
        let b = node("variety-b", lon: -106.01)
        let singleHub = node("a-single-run-hub", kind: .liftBase, lon: -106.02)
        let variedHub = node("z-varied-run-hub", kind: .liftBase, lon: -106.03)
        let singleEnd = node("variety-single-end", lon: -106.04)
        let variedEndA = node("variety-end-a", lon: -106.05)
        let variedEndB = node("variety-end-b", lon: -106.06)

        func run(
            _ id: String,
            name: String,
            from source: GraphNode,
            to target: GraphNode
        ) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: source.id,
                targetID: target.id,
                kind: .run,
                geometry: [source.coordinate, target.coordinate],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 600,
                    verticalDrop: 200,
                    trailName: name,
                    isGroomed: true,
                    isOpen: true
                )
            )
        }

        let graph = MountainGraph(
            resortID: "shared-run-variety",
            nodes: [
                a.id: a, b.id: b, singleHub.id: singleHub,
                variedHub.id: variedHub, singleEnd.id: singleEnd,
                variedEndA.id: variedEndA, variedEndB.id: variedEndB,
            ],
            edges: [
                edge("variety-a-single", a, singleHub, length: 100),
                edge("variety-b-single", b, singleHub, length: 100),
                edge("variety-a-varied", a, variedHub, length: 100),
                edge("variety-b-varied", b, variedHub, length: 100),
                run("single-cruiser", name: "Single Cruiser", from: singleHub, to: singleEnd),
                run("varied-cruiser", name: "Varied Cruiser", from: variedHub, to: variedEndA),
                run("varied-glider", name: "Varied Glider", from: variedHub, to: variedEndB),
            ]
        )
        func point(_ node: GraphNode) -> RendezvousPoint {
            RendezvousPoint(
                id: node.id,
                nodeID: node.id,
                kind: .liftBase,
                confidence: 1,
                quality: 1
            )
        }
        func solve(_ points: [RendezvousPoint]) throws -> MeetingResult {
            try XCTUnwrap(MeetingPointSolver(
                graph: graph,
                rendezvousCatalog: RendezvousCatalog(points: points, graph: graph)
            ).solve(
                skierA: profile("A"), positionA: a.id,
                skierB: profile("B"), positionB: b.id
            ))
        }

        let singleOnly = try solve([point(singleHub)])
        let variedOnly = try solve([point(variedHub)])
        let ranked = try solve([point(singleHub), point(variedHub)])

        XCTAssertEqual(singleOnly.sharedContinuation?.sharedRunOptionCount, 1)
        XCTAssertEqual(variedOnly.sharedContinuation?.sharedRunOptionCount, 2)
        XCTAssertGreaterThan(
            variedOnly.sharedContinuation?.quality ?? 0,
            singleOnly.sharedContinuation?.quality ?? 1
        )
        // Approaches and best runs are physically identical. Before bounded
        // route variety entered utility, stable ID selected a-single-run-hub.
        XCTAssertEqual(ranked.meetingNode.id, variedHub.id)
        XCTAssertEqual(ranked.sharedContinuation?.sharedRunOptionCount, 2)
    }

    func testSharedContinuationAllowsTimeToRegroupBeforeLastChair() throws {
        MeetingPointSolver.solutionCache.clear()
        let a = node("handoff-a", lon: -106.00)
        let b = node("handoff-b", lon: -106.01)
        let base = node("handoff-base", kind: .liftBase, lon: -106.02)
        let top = node("handoff-top", kind: .liftTop, lon: -106.03)
        let end = node("handoff-end", lon: -106.04)
        let lift = GraphEdge(
            id: "handoff-chair",
            sourceID: base.id,
            targetID: top.id,
            kind: .lift,
            geometry: [base.coordinate, top.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 800,
                verticalDrop: -300,
                trailName: "Handoff Chair",
                liftType: .chairLift,
                rideTimeSeconds: 300,
                waitTimeMinutes: 1,
                chargesLiftWait: true,
                isOpen: true
            )
        )
        let run = GraphEdge(
            id: "handoff-run",
            sourceID: top.id,
            targetID: end.id,
            kind: .run,
            geometry: [top.coordinate, end.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 700,
                verticalDrop: 300,
                trailName: "Handoff Run",
                isGroomed: true,
                isOpen: true
            )
        )
        let graph = MountainGraph(
            resortID: "shared-handoff-last-chair",
            nodes: [a.id: a, b.id: b, base.id: base, top.id: top, end.id: end],
            edges: [
                edge("handoff-a-base", a, base, length: 10),
                edge("handoff-b-base", b, base, length: 10),
                lift,
                run,
            ]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: base.id,
            nodeID: base.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)

        func time(hour: Int, minute: Int) -> Date {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(secondsFromGMT: 0)
            components.year = 2026
            components.month = 1
            components.day = 15
            components.hour = hour
            components.minute = minute
            return components.date!
        }
        func solve(at date: Date) throws -> MeetingResult {
            let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
            solver.solveTime = date
            solver.resortLongitude = 0
            solver.resortUTCOffsetSeconds = 0
            solver.liftOpenHour = 8
            solver.liftCloseHour = 16
            return try XCTUnwrap(solver.solve(
                skierA: profile("A"), positionA: a.id,
                skierB: profile("B"), positionB: b.id
            ))
        }

        let enoughTime = try solve(at: time(hour: 15, minute: 57))
        MeetingPointSolver.solutionCache.clear()
        let tooLate = try solve(at: time(hour: 15, minute: 59))

        XCTAssertEqual(enoughTime.sharedContinuation?.edgeID, lift.id)
        XCTAssertNil(tooLate.sharedContinuation)
    }

    func testUncertainApproachMustReliablyCatchLastChair() throws {
        let start = node("deadline-start", lon: -106.00)
        let base = node("deadline-base", kind: .liftBase, lon: -106.01)
        let meet = node("deadline-meet", kind: .liftBase, lon: -106.02)
        let approach = edge("deadline-approach", start, base, length: 2_000)
        let lift = GraphEdge(
            id: "deadline-lift",
            sourceID: base.id,
            targetID: meet.id,
            kind: .lift,
            geometry: [base.coordinate, meet.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 500,
                liftType: .chairLift,
                rideTimeSeconds: 60,
                chargesLiftWait: false,
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        let graph = MountainGraph(
            resortID: "uncertain-last-chair",
            nodes: [start.id: start, base.id: base, meet.id: meet],
            edges: [approach, lift]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: meet.id,
            nodeID: meet.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)

        func time(hour: Int, minute: Int, second: Int) -> Date {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(secondsFromGMT: 0)
            components.year = 2026
            components.month = 1
            components.day = 15
            components.hour = hour
            components.minute = minute
            components.second = second
            return components.date!
        }
        func solve(at date: Date) -> MeetingResult? {
            let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
            solver.solveTime = date
            solver.resortLongitude = 0
            solver.resortUTCOffsetSeconds = 0
            solver.liftOpenHour = 8
            solver.liftCloseHour = 16
            return solver.solve(
                skierA: profile("A"), positionA: start.id,
                skierB: profile("B"), positionB: start.id
            )
        }

        // The cold-snow-adjusted 2 km approach is about 207 seconds with a
        // 31-second modeled standard deviation. The 15:56:30 request is
        // normalized to 15:56; its mean reaches the lift before 16:00 but its
        // P90 reaches it after closing, so the route must not advertise that
        // chair. Ten minutes earlier it remains valid.
        let comfortable = solve(at: time(hour: 15, minute: 46, second: 30))
        MeetingPointSolver.solutionCache.clear()
        let fragile = solve(at: time(hour: 15, minute: 56, second: 30))

        XCTAssertEqual(comfortable?.pathA.map(\.id), [approach.id, lift.id])
        XCTAssertNil(fragile)
        let diagnosticSolver = MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        )
        diagnosticSolver.solveTime = time(hour: 15, minute: 56, second: 30)
        diagnosticSolver.resortLongitude = 0
        diagnosticSolver.resortUTCOffsetSeconds = 0
        diagnosticSolver.liftOpenHour = 8
        diagnosticSolver.liftCloseHour = 16
        _ = diagnosticSolver.solve(
            skierA: profile("A"), positionA: start.id,
            skierB: profile("B"), positionB: start.id
        )
        guard case .liftDeadlineRisk = diagnosticSolver.lastFailureReason else {
            return XCTFail("Expected a last-chair reliability explanation")
        }
        XCTAssertTrue(diagnosticSolver.lastFailureReason?.userMessage.contains(
            "too close to last chair"
        ) == true)
        let skier = profile("Stored skier")
        XCTAssertNil(diagnosticSolver.metrics(for: [approach, lift], skier: skier),
                     "An exact stored route must not bypass the solver's last-chair risk gate")
        XCTAssertNil(ActiveRouteETA.estimate(
            path: [approach, lift], currentEdgeIndex: 0, currentEdgeFraction: 0,
            profile: skier, context: diagnosticSolver.makeContext(for: skier.id.uuidString)
        ), "Live recalculation must trigger recovery when the same route can no longer reliably catch the lift")
        diagnosticSolver.solveTime = time(hour: 15, minute: 46, second: 30)
        XCTAssertNotNil(diagnosticSolver.metrics(for: [approach, lift], skier: skier))
        XCTAssertNotNil(ActiveRouteETA.estimate(
            path: [approach, lift], currentEdgeIndex: 0, currentEdgeFraction: 0,
            profile: skier, context: diagnosticSolver.makeContext(for: skier.id.uuidString)
        ))
    }

    func testSkierAlreadyOnLiftMayFinishRideAfterLastChair() throws {
        let base = node("aboard-base", kind: .liftBase, lon: -106.00)
        let meet = node("aboard-mid", kind: .midStation, lon: -106.01)
        let lift = GraphEdge(
            id: "aboard-lift",
            sourceID: base.id,
            targetID: meet.id,
            kind: .lift,
            geometry: [base.coordinate, meet.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 500,
                liftType: .chairLift,
                rideTimeSeconds: 120,
                waitTimeMinutes: 10,
                chargesLiftWait: true,
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        let graph = MountainGraph(
            resortID: "already-aboard-last-chair",
            nodes: [base.id: base, meet.id: meet],
            edges: [lift]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: meet.id,
            nodeID: meet.id,
            kind: .midStation,
            confidence: 1,
            quality: 1
        )], graph: graph)
        let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 1
        components.day = 15
        components.hour = 16
        components.minute = 5
        solver.solveTime = components.date!
        solver.resortLongitude = 0
        solver.resortUTCOffsetSeconds = 0
        solver.liftOpenHour = 8
        solver.liftCloseHour = 16
        let origin = RoutingOrigin.interior(
            edge: lift,
            fractionAlongEdge: 0.5,
            positionUncertaintyMeters: 150
        )

        let result = try XCTUnwrap(solver.solve(
            skierA: profile("A"), originA: origin,
            skierB: profile("B"), originB: origin
        ))

        XCTAssertEqual(result.pathA.map(\.id), [lift.id])
        XCTAssertEqual(result.timeA, 60, accuracy: 0.001)
        XCTAssertEqual(result.initialEdgeFractionA, 0.5, accuracy: 0.001)
        let aboard = profile("Already aboard")
        let stored = try XCTUnwrap(solver.metrics(for: [lift], skier: aboard, initialEdgeFraction: 0.5))
        let live = try XCTUnwrap(ActiveRouteETA.estimate(
            path: [lift], currentEdgeIndex: 0, currentEdgeFraction: 0.5,
            profile: aboard, context: solver.makeContext(for: aboard.id.uuidString)
        ))
        XCTAssertEqual(stored.time, 60, accuracy: 0.001)
        XCTAssertEqual(live.totalSeconds, stored.time, accuracy: 0.001)
    }

    private func splitLiftClosingFixture(secondOpen: Bool = true, fasterWrongLift: Bool = false) -> (MeetingPointSolver, [GraphEdge], GraphNode) {
        let base = node("split-base", kind: .liftBase, lon: -106)
        let mid = node("split-mid", kind: .midStation, lon: -106.01)
        let top = node("split-top", kind: .midStation, lon: -106.02)
        let path = [(base, mid), (mid, top)].enumerated().map { index, pair in
            GraphEdge(id: "l123_vx\(index + 1)", sourceID: pair.0.id, targetID: pair.1.id,
                kind: .lift, geometry: [pair.0.coordinate, pair.1.coordinate],
                attributes: EdgeAttributes(lengthMeters: 500, trailName: "Same Lift",
                    liftType: .chairLift, rideTimeSeconds: 180,
                    waitTimeMinutes: index == 0 ? 0 : nil,
                    chargesLiftWait: index == 0, isOpen: index == 0 || secondOpen,
                    trailGroupId: "same-display-group"))
        }
        var edges = path
        if fasterWrongLift {
            edges.append(GraphEdge(id: "l999_vx1", sourceID: base.id, targetID: mid.id, kind: .lift,
                geometry: path[0].geometry,
                attributes: EdgeAttributes(lengthMeters: 500, trailName: "Same Lift",
                    liftType: .chairLift, rideTimeSeconds: 60, waitTimeMinutes: 0,
                    chargesLiftWait: true, isOpen: true, trailGroupId: "same-display-group")))
        }
        let graph = MountainGraph(resortID: "split-last-chair", nodes: [base.id: base, mid.id: mid, top.id: top], edges: edges)
        let catalog = RendezvousCatalog(points: [.init(id: top.id, nodeID: top.id, kind: .midStation,
                                                     confidence: 1, quality: 1)], graph: graph)
        let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
        solver.solveTime = DateComponents(calendar: Calendar(identifier: .gregorian),
            timeZone: .gmt, year: 2026, month: 1, day: 15, hour: 15, minute: 59).date!
        solver.resortLongitude = 0
        solver.resortUTCOffsetSeconds = 0
        solver.liftOpenHour = 8
        solver.liftCloseHour = 16
        return (solver, path, top)
    }

    func testSplitLiftFinishesAfterLastChairAcrossSolveStoredLiveAndPreviewPaths() throws {
        let (solver, path, top) = splitLiftClosingFixture()
        let a = profile("A"), b = profile("B")
        let context = solver.makeContext(for: a.id.uuidString)
        // Preserve the existing first-boarding queue model, including its
        // conservative adjustment of reported zero waits. The continuation
        // adds exactly its 180-second ride, not another queue or closing gate.
        let expected = try XCTUnwrap(a.traverseTime(for: path[0], context: context)) + 180
        let result = try XCTUnwrap(solver.solve(skierA: a, positionA: path[0].sourceID,
                                               skierB: b, positionB: path[0].sourceID))
        XCTAssertEqual(result.pathA.map(\.id), path.map(\.id))
        XCTAssertEqual(result.pathB.map(\.id), path.map(\.id))
        XCTAssertEqual(result.meetingNode.id, top.id)
        XCTAssertEqual(result.timeA, expected, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(solver.metrics(for: path, skier: a)).time, expected, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ActiveRouteETA.seconds(path: path, currentEdgeIndex: 0,
            currentEdgeFraction: 0, profile: a, context: context)), expected, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(RouteProjection.totalTime(for: path, profile: a, context: context)), expected, accuracy: 0.001)
        let graph = MountainGraph(resortID: "preview", nodes: [:], edges: path)
        XCTAssertEqual(RouteProjection.skierPosition(at: 240, path: path, profile: a,
            context: context, graph: graph)?.currentEdge?.id, path[1].id)
        let instructions = RouteInstructionBuilder.build(from: path, profile: a, context: context, naming: MountainNaming(graph))
        XCTAssertFalse(instructions.isEmpty)
        XCTAssertEqual(instructions.reduce(0) { $0 + $1.estimatedSeconds }, expected, accuracy: 0.001)
    }

    func testFasterSameNamedDifferentLiftCannotDominateAlreadyBoardedState() throws {
        let (solver, path, _) = splitLiftClosingFixture(fasterWrongLift: true)
        let a = profile("A"), b = profile("B")
        let result = try XCTUnwrap(solver.solve(skierA: a, positionA: path[0].sourceID,
                                               skierB: b, positionB: path[0].sourceID))
        XCTAssertEqual(result.pathA.map(\.id), path.map(\.id))
        XCTAssertEqual(result.pathB.map(\.id), path.map(\.id))
        XCTAssertFalse(result.pathA.contains { $0.id == "l999_vx1" })
    }

    func testSplitLiftBoundaryDoesNotBecomeANewBoardingAfterClose() throws {
        let (solver, path, _) = splitLiftClosingFixture()
        let skier = profile("Aboard")
        let context = solver.makeContext(for: skier.id.uuidString)
            .rebased(to: solver.solveTime!.addingTimeInterval(180))
        XCTAssertEqual(try XCTUnwrap(ActiveRouteETA.seconds(path: path, currentEdgeIndex: 1,
            currentEdgeFraction: 0, profile: skier, context: context)), 180, accuracy: 0.001)
        XCTAssertNil(skier.traverseTime(for: path[1], context: context),
                     "A node-origin skier without prior ride evidence cannot board after close")
        XCTAssertNil(skier.traverseTime(for: path[0], context: context))
    }

    func testContinuationDoesNotBypassAnExplicitLiftClosure() {
        let (solver, path, _) = splitLiftClosingFixture(secondOpen: false)
        let skier = profile("Aboard")
        XCTAssertNil(solver.metrics(for: path, skier: skier))
        XCTAssertNil(ActiveRouteETA.seconds(path: path, currentEdgeIndex: 0, currentEdgeFraction: 0.5,
            profile: skier, context: solver.makeContext(for: skier.id.uuidString)))
    }

    func testLiftContinuationRequiresExactConsecutiveSourceSegmentsNotNames() {
        let (_, path, _) = splitLiftClosingFixture()
        func changed(_ edge: GraphEdge, id: String? = nil, source: String? = nil) -> GraphEdge {
            GraphEdge(id: id ?? edge.id, sourceID: source ?? edge.sourceID, targetID: edge.targetID,
                      kind: edge.kind, geometry: edge.geometry, attributes: edge.attributes)
        }
        XCTAssertTrue(LiftRideContinuation.isContinuation(from: path[0], to: path[1]))
        XCTAssertFalse(LiftRideContinuation.isContinuation(from: nil, to: path[1]))
        XCTAssertFalse(LiftRideContinuation.isContinuation(from: path[0], to: changed(path[1], id: "l999_vx2")))
        XCTAssertFalse(LiftRideContinuation.isContinuation(from: path[0], to: changed(path[1], id: "l123_vx3")))
        XCTAssertFalse(LiftRideContinuation.isContinuation(from: path[0], to: changed(path[1], source: "unconnected")))
        for invalid in ["same-lift-2", "l123_vx02", "l123_vx+2", "l123_vx2_extra", "l123_vx999999999999999999999"] {
            XCTAssertFalse(LiftRideContinuation.isContinuation(from: path[0], to: changed(path[1], id: invalid)))
        }
    }

    func testMeetingExplanationReportsTravelAndActualLeadTruthfully() {
        func summary(timeA: Double, timeB: Double) -> String {
            MeetingArrivalPresentation(timeA: timeA, timeB: timeB, stdA: nil, stdB: nil).comparisonText
        }
        XCTAssertEqual(
            summary(timeA: 600, timeB: 620),
            "SIMILAR ESTIMATED ARRIVALS"
        )
        XCTAssertEqual(
            summary(timeA: 300, timeB: 420),
            "EXPECTED WAIT · YOU ~2m"
        )
        XCTAssertEqual(
            summary(timeA: 95, timeB: 35),
            "EXPECTED WAIT · FRIEND ~1m"
        )
        XCTAssertFalse(MeetingRouteTimePresentation.shouldShowRanges(stdA: 29, stdB: 10))
        XCTAssertTrue(MeetingRouteTimePresentation.shouldShowRanges(stdA: 30, stdB: 10))
    }

    func testAlternateMeetingLabelsExplainMaterialTradeoff() {
        let primary = MeetingOptionTradeoff.Metrics(
            maxTerrainRank: 3,
            latestArrivalSeconds: 600,
            waitSpreadSeconds: 120,
            uncertaintySeconds: 100,
            liftBoardings: 3
        )

        XCTAssertEqual(
            MeetingOptionTradeoff.label(
                primary: primary,
                alternate: .init(
                    maxTerrainRank: 2,
                    latestArrivalSeconds: 700,
                    waitSpreadSeconds: 120,
                    uncertaintySeconds: 100,
                    liftBoardings: 3
                ),
                ordinal: 2
            ),
            "EASIER TERRAIN"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.label(
                primary: primary,
                alternate: .init(
                    maxTerrainRank: 3,
                    latestArrivalSeconds: 560,
                    waitSpreadSeconds: 180,
                    uncertaintySeconds: 150,
                    liftBoardings: 4
                ),
                ordinal: 2
            ),
            "QUICKER ARRIVAL"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.label(
                primary: .init(
                    maxTerrainRank: 2,
                    latestArrivalSeconds: 600,
                    waitSpreadSeconds: 120,
                    uncertaintySeconds: 100,
                    liftBoardings: 3,
                    traverseMeters: 500
                ),
                alternate: .init(
                    maxTerrainRank: 2,
                    latestArrivalSeconds: 650,
                    waitSpreadSeconds: 120,
                    uncertaintySeconds: 100,
                    liftBoardings: 3,
                    traverseMeters: 200
                ),
                ordinal: 2
            ),
            "LESS SKATING"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.label(
                primary: primary,
                alternate: .init(
                    maxTerrainRank: 3,
                    latestArrivalSeconds: 650,
                    waitSpreadSeconds: 50,
                    uncertaintySeconds: 100,
                    liftBoardings: 3
                ),
                ordinal: 2
            ),
            "CLOSER ARRIVALS"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.label(
                primary: primary,
                alternate: .init(
                    maxTerrainRank: 3,
                    latestArrivalSeconds: 650,
                    waitSpreadSeconds: 120,
                    uncertaintySeconds: 60,
                    liftBoardings: 3
                ),
                ordinal: 2
            ),
            "MORE PREDICTABLE"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.label(
                primary: primary,
                alternate: .init(
                    maxTerrainRank: 3,
                    latestArrivalSeconds: 650,
                    waitSpreadSeconds: 120,
                    uncertaintySeconds: 100,
                    liftBoardings: 2
                ),
                ordinal: 2
            ),
            "FEWER LIFTS"
        )
    }

    func testPrimaryMeetingLabelExplainsWhyTheRecommendationWon() {
        let primary = MeetingOptionTradeoff.Metrics(
            maxTerrainRank: 2,
            latestArrivalSeconds: 600,
            waitSpreadSeconds: 60,
            uncertaintySeconds: 50,
            liftBoardings: 2
        )

        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(primary: primary, alternates: []),
            "RECOMMENDED STOP"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(
                primary: primary,
                alternates: [
                    .init(
                        maxTerrainRank: 1,
                        latestArrivalSeconds: 640,
                        waitSpreadSeconds: 20,
                        uncertaintySeconds: 20,
                        liftBoardings: 1
                    )
                ]
            ),
            "FASTEST TOGETHER"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(
                primary: primary,
                alternates: [
                    .init(
                        maxTerrainRank: 1,
                        latestArrivalSeconds: 610,
                        waitSpreadSeconds: 130,
                        uncertaintySeconds: 20,
                        liftBoardings: 1
                    )
                ]
            ),
            "BEST SYNC"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(
                primary: primary,
                alternates: [
                    .init(
                        maxTerrainRank: 1,
                        latestArrivalSeconds: 610,
                        waitSpreadSeconds: 70,
                        uncertaintySeconds: 100,
                        liftBoardings: 1
                    )
                ]
            ),
            "MOST PREDICTABLE"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(
                primary: primary,
                alternates: [
                    .init(
                        maxTerrainRank: 3,
                        latestArrivalSeconds: 610,
                        waitSpreadSeconds: 70,
                        uncertaintySeconds: 60,
                        liftBoardings: 1
                    )
                ]
            ),
            "EASIEST TOP PICK"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(
                primary: primary,
                alternates: [
                    .init(
                        maxTerrainRank: 2,
                        latestArrivalSeconds: 610,
                        waitSpreadSeconds: 70,
                        uncertaintySeconds: 60,
                        liftBoardings: 3
                    )
                ]
            ),
            "FEWEST LIFTS"
        )
        XCTAssertEqual(
            MeetingOptionTradeoff.primaryLabel(
                primary: primary,
                alternates: [
                    .init(
                        maxTerrainRank: 1,
                        latestArrivalSeconds: 610,
                        waitSpreadSeconds: 70,
                        uncertaintySeconds: 60,
                        liftBoardings: 1
                    )
                ]
            ),
            "BEST BALANCE"
        )
    }

    func testRouteFactsReportMarkedTerrainDistanceAndPhysicalBoardings() {
        let top = node("facts-top", lon: -106.0)
        let bottom = node("facts-bottom", lon: -106.01)
        let blue = edge(
            "facts-blue",
            top,
            bottom,
            length: 1_200,
            difficulty: .blue
        )
        let lift = GraphEdge(
            id: "facts-lift",
            sourceID: bottom.id,
            targetID: top.id,
            kind: .lift,
            geometry: [bottom.coordinate, top.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 800,
                liftType: .chairLift,
                rideTimeSeconds: 300,
                chargesLiftWait: true,
                isOpen: true
            )
        )
        let continuation = GraphEdge(
            id: "facts-lift-continuation",
            sourceID: bottom.id,
            targetID: top.id,
            kind: .lift,
            geometry: [bottom.coordinate, top.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 200,
                liftType: .chairLift,
                rideTimeSeconds: 60,
                chargesLiftWait: false,
                isOpen: true
            )
        )
        let connector = GraphEdge(
            id: "facts-connector",
            sourceID: bottom.id,
            targetID: top.id,
            kind: .traverse,
            geometry: [bottom.coordinate, top.coordinate],
            attributes: EdgeAttributes(
                lengthMeters: 120,
                isOpen: true
            )
        )

        let facts = MeetingRouteFacts(path: [blue, lift, continuation, connector])
        XCTAssertEqual(facts.hardestTerrain, .blue)
        XCTAssertFalse(facts.includesTerrainPark)
        XCTAssertEqual(facts.liftBoardings, 1)
        XCTAssertEqual(facts.distanceMeters, 2_320, accuracy: 0.001)
        XCTAssertEqual(facts.traverseMeters, 120, accuracy: 0.001)
        XCTAssertTrue(facts.summary?.contains("BLUE MAX") == true)
        XCTAssertTrue(facts.summary?.contains("1 LIFT") == true)
        XCTAssertTrue(facts.summary?.contains("CONNECTOR") == true)
    }

    func testRouteFactsDiscloseTerrainParkSeparatelyFromMarkedDifficulty() {
        let top = node("park-top", lon: -106.0)
        let middle = node("park-middle", lon: -106.005)
        let bottom = node("park-bottom", lon: -106.01)
        let black = edge(
            "black-entry",
            top,
            middle,
            length: 500,
            difficulty: .black
        )
        let park = edge(
            "park-finish",
            middle,
            bottom,
            length: 400,
            difficulty: .terrainPark
        )

        let facts = MeetingRouteFacts(path: [black, park])
        XCTAssertEqual(facts.hardestTerrain, .black)
        XCTAssertTrue(facts.includesTerrainPark)
        XCTAssertEqual(facts.summary, "BLACK MAX · PARK FEATURES · 2952FT")
    }

    func testClosedApproachMakesRendezvousIneligible() {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let safe = node("safe", lon: -106.015)
        let meet = node("meet", kind: .liftBase, lon: -106.02)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, safe.id: safe, meet.id: meet],
            edges: [
                edge("a-meet", a, meet, length: 100),
                edge("b-meet-closed", b, meet, length: 100, isOpen: false),
                edge("b-safe-exit", b, safe, length: 100)
            ]
        )
        let solver = MeetingPointSolver(graph: graph)

        XCTAssertNil(solver.solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))
        guard case .noReachableRendezvous = solver.lastFailureReason else {
            return XCTFail("Expected closure-aware rendezvous failure")
        }
    }

    func testSkierAlreadyAtTerminalRendezvousCanWaitWithoutOutgoingRoute() throws {
        let waiting = node("waiting", kind: .liftBase, lon: -106.00)
        let approaching = node("approaching", lon: -106.01)
        let approach = edge("approach", approaching, waiting, length: 100)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [waiting.id: waiting, approaching.id: approaching],
            edges: [approach]
        )
        let catalog = RendezvousCatalog(points: [
            RendezvousPoint(
                id: waiting.id,
                nodeID: waiting.id,
                kind: .liftBase,
                displayName: "Terminal Base",
                confidence: 1,
                quality: 1
            )
        ], graph: graph)

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("Waiting"), positionA: waiting.id,
            skierB: profile("Approaching"), positionB: approaching.id
        ))

        XCTAssertEqual(result.meetingNode.id, waiting.id)
        XCTAssertTrue(result.pathA.isEmpty)
        XCTAssertEqual(result.timeA, 0, accuracy: 0.001)
        XCTAssertEqual(result.pathB.map(\.id), [approach.id])
    }

    func testAbilityGateIsDiagnosedWithoutWeakeningRealSolve() {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let safe = node("safe", lon: -106.015)
        let meet = node("meet", kind: .liftBase, lon: -106.02)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, safe.id: safe, meet.id: meet],
            edges: [
                edge("a-meet", a, meet, length: 100),
                edge("b-too-hard", b, meet, length: 100, difficulty: .doubleBlack),
                edge("b-safe", b, safe, length: 100, difficulty: .green)
            ]
        )
        let solver = MeetingPointSolver(graph: graph)
        let skierB = profile("B")

        XCTAssertNil(solver.solve(
            skierA: profile("A"), positionA: a.id,
            skierB: skierB, positionB: b.id
        ))
        guard case .skillGatedPath(let diagnostics) = solver.lastFailureReason else {
            return XCTFail("Expected ability-gated rendezvous failure")
        }
        XCTAssertEqual(diagnostics, [SkierCapabilityDiagnostic(
            skierID: skierB.id,
            skierName: "B",
            blockers: [.markedDifficulty(.doubleBlack)]
        )])
        XCTAssertTrue(solver.lastFailureReason?.userMessage.contains(
            "B: DOUBLE BLACK TERRAIN"
        ) == true)
    }

    func testRelaxedOrdinaryJunctionDoesNotMasqueradeAsCapabilityRoute() {
        let a = node("junction-a", lon: -106.00)
        let b = node("junction-b", lon: -106.01)
        let safe = node("junction-safe", lon: -106.015)
        let ordinary = node("ordinary", lon: -106.02)
        let isolated = node("isolated", lon: -106.03)
        let unreachableMeet = node("unreachable-meet", kind: .liftBase, lon: -106.04)
        let graph = MountainGraph(
            resortID: "ordinary-intersection",
            nodes: [
                a.id: a, b.id: b, safe.id: safe, ordinary.id: ordinary,
                isolated.id: isolated, unreachableMeet.id: unreachableMeet,
            ],
            edges: [
                edge("a-too-hard", a, ordinary, length: 100, difficulty: .doubleBlack),
                edge("a-safe", a, safe, length: 100, difficulty: .green),
                edge("b-ordinary", b, ordinary, length: 100, difficulty: .green),
                edge("isolated-meet", isolated, unreachableMeet, length: 100),
            ]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: unreachableMeet.id,
            nodeID: unreachableMeet.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)
        let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)

        XCTAssertNil(solver.solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))
        guard case .noReachableRendezvous = solver.lastFailureReason else {
            return XCTFail("An ordinary relaxed junction is not a meeting route")
        }
    }

    func testSelectionAndAlternatesAreStableAcrossInputOrder() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let r1 = node("r1", kind: .liftBase, lon: -106.02)
        let r2 = node("r2", kind: .liftBase, lon: -106.03)
        let r3 = node("r3", kind: .midStation, lon: -106.04)
        let nodes = [a, b, r1, r2, r3]
        let edges = [
            edge("a-r1", a, r1, length: 100), edge("b-r1", b, r1, length: 100),
            edge("a-r2", a, r2, length: 100), edge("b-r2", b, r2, length: 100),
            edge("a-r3", a, r3, length: 110), edge("b-r3", b, r3, length: 110)
        ]
        let points = [r3, r2, r1].map {
            RendezvousPoint(
                id: $0.id,
                nodeID: $0.id,
                kind: $0.kind == .midStation ? .midStation : .liftBase,
                confidence: 1,
                quality: 1
            )
        }
        let skierA = profile("A")
        let skierB = profile("B")
        var outputs: [[String]] = []

        for reverse in [false, true, false, true] {
            MeetingPointSolver.solutionCache.clear()
            let orderedNodes = reverse ? Array(nodes.reversed()) : nodes
            let graph = MountainGraph(
                resortID: "test",
                nodes: Dictionary(uniqueKeysWithValues: orderedNodes.map { ($0.id, $0) }),
                edges: reverse ? Array(edges.reversed()) : edges
            )
            let orderedPoints = reverse ? Array(points.reversed()) : points
            let catalog = RendezvousCatalog(points: orderedPoints, graph: graph)
            let result = try XCTUnwrap(MeetingPointSolver(
                graph: graph,
                rendezvousCatalog: catalog
            ).solve(
                skierA: skierA, positionA: a.id,
                skierB: skierB, positionB: b.id
            ))
            outputs.append([result.meetingNode.id] + result.alternates.map(\.node.id))
            XCTAssertEqual(result.rendezvousPoint?.nodeID, result.meetingNode.id)
            XCTAssertTrue(result.alternates.allSatisfy {
                $0.rendezvousPoint?.nodeID == $0.node.id
            })
        }

        XCTAssertTrue(outputs.dropFirst().allSatisfy { $0 == outputs[0] })
        XCTAssertEqual(outputs[0].first, "r1")
        XCTAssertTrue(Set(outputs[0]).isSubset(of: ["r1", "r2", "r3"]))
    }

    func testNearbyDuplicateStopsDoNotPadAlternateCarousel() throws {
        let a = node("near-a", lon: -106.00)
        let b = node("near-b", lon: -106.01)
        let stops = (0..<5).map { index in
            node(
                "near-stop-\(index)",
                kind: .liftBase,
                lon: -106.0200 + Double(index) * 0.0001
            )
        }
        var edges: [GraphEdge] = []
        for stop in stops {
            edges.append(edge("a-\(stop.id)", a, stop, length: 100))
            edges.append(edge("b-\(stop.id)", b, stop, length: 100))
        }
        let nodes = [a, b] + stops
        let graph = MountainGraph(
            resortID: "nearby-stops",
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
            edges: edges
        )
        let catalog = RendezvousCatalog(
            points: stops.map {
                RendezvousPoint(
                    id: $0.id,
                    nodeID: $0.id,
                    kind: .liftBase,
                    confidence: 1,
                    quality: 1
                )
            },
            graph: graph
        )

        let result = try XCTUnwrap(MeetingPointSolver(
            graph: graph,
            rendezvousCatalog: catalog
        ).solve(
            skierA: profile("A"), positionA: a.id,
            skierB: profile("B"), positionB: b.id
        ))

        XCTAssertEqual(result.alternates.count, 1)
        XCTAssertNotEqual(result.alternates.first?.node.id, result.meetingNode.id)
    }

    func testSolutionCacheInvalidatesWhenLiveLiftWaitChanges() throws {
        let start = node("queue-start", lon: -106.00)
        let topA = node("queue-top-a", lon: -106.01)
        let topB = node("queue-top-b", lon: -106.02)
        let meet = node("queue-meet", kind: .liftBase, lon: -106.03)
        let skierA = profile("A")
        let skierB = profile("B")

        func lift(_ id: String, to target: GraphNode, waitMinutes: Double) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: start.id,
                targetID: target.id,
                kind: .lift,
                geometry: [start.coordinate, target.coordinate],
                attributes: EdgeAttributes(
                    lengthMeters: 500,
                    liftType: .chairLift,
                    rideTimeSeconds: 60,
                    waitTimeMinutes: waitMinutes,
                    chargesLiftWait: true,
                    isOpen: true,
                    isOfficiallyValidated: true
                )
            )
        }
        func graph(waitA: Double, waitB: Double) -> MountainGraph {
            MountainGraph(
                resortID: "queue-test",
                nodes: [start.id: start, topA.id: topA, topB.id: topB, meet.id: meet],
                edges: [
                    lift("lift-a", to: topA, waitMinutes: waitA),
                    lift("lift-b", to: topB, waitMinutes: waitB),
                    edge("run-a", topA, meet, length: 1_000),
                    edge("run-b", topB, meet, length: 1_000),
                ]
            )
        }

        MeetingPointSolver.solutionCache.clear()
        let first = try XCTUnwrap(MeetingPointSolver(
            graph: graph(waitA: 0, waitB: 10)
        ).solve(
            skierA: skierA, positionA: start.id,
            skierB: skierB, positionB: start.id
        ))
        let second = try XCTUnwrap(MeetingPointSolver(
            graph: graph(waitA: 10, waitB: 0)
        ).solve(
            skierA: skierA, positionA: start.id,
            skierB: skierB, positionB: start.id
        ))

        XCTAssertEqual(first.pathA.first?.id, "lift-a")
        XCTAssertEqual(second.pathA.first?.id, "lift-b")
        XCTAssertNotEqual(first.pathA.map(\.id), second.pathA.map(\.id))
    }

    func testMisfiledHistoryCannotChangeTheChosenApproach() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let meet = node("meet", kind: .liftBase, lon: -106.02)
        let direct = edge("direct", a, meet, length: 1000)
        let detour = edge("detour", a, meet, length: 2000)
        let partner = edge("partner", b, meet, length: 1000)
        let graph = MountainGraph(resortID: "test",
                                  nodes: [a.id: a, b.id: b, meet.id: meet],
                                  edges: [direct, detour, partner])
        let skierA = profile("A")
        let skierB = profile("B")
        let row = PerEdgeSpeed(resortId: "test", edgeId: "unrelated-trail",
                               conditionsFp: ConditionsFingerprint.defaultBucket,
                               datasetVersion: "dataset-v1", observationCount: 5,
                               rollingSpeedMs: 25, rollingDurationS: 80,
                               rollingSpeedVarianceMs2: 1, lastObservedAt: .now)
        for includeBadRow in [false, true] {
            MeetingPointSolver.solutionCache.clear()
            let solver = MeetingPointSolver(graph: graph)
            solver.temperatureC = 0
            solver.datasetVersion = "dataset-v1"
            if includeBadRow {
                solver.edgeSpeedHistoryByProfile = [
                    skierA.id.uuidString: [detour.id: [row.historyKey: row]]
                ]
            }
            let result = try XCTUnwrap(solver.solve(
                skierA: skierA, positionA: a.id, skierB: skierB, positionB: b.id))
            XCTAssertEqual(result.pathA.map(\.id), [direct.id])
            XCTAssertEqual(result.timeA, 100, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(result.etaStdSecondsA), 15, accuracy: 0.001)
        }
    }

    func testUncertaintyUsesOnlyEligibleLearnedConditionCohorts() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let meet = node("meet", kind: .liftBase, lon: -106.02)
        let edgeA = edge("a-meet", a, meet, length: 1_000)
        let edgeB = edge("b-meet", b, meet, length: 1_000)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, meet.id: meet],
            edges: [edgeA, edgeB]
        )
        let skierA = profile("A")
        let skierB = profile("B")

        func solve(conditions: String) throws -> MeetingResult {
            MeetingPointSolver.solutionCache.clear()
            let row = observation(
                edgeID: edgeA.id,
                conditions: conditions,
                variance: 4
            )
            let solver = MeetingPointSolver(graph: graph)
            // Keep this uncertainty-cohort test condition-neutral. Dedicated
            // performance tests cover the continuous cold-snow glide model.
            solver.temperatureC = 0
            solver.datasetVersion = "dataset-v1"
            solver.edgeSpeedHistoryByProfile = [
                skierA.id.uuidString: [edgeA.id: [row.historyKey: row]]
            ]
            return try XCTUnwrap(solver.solve(
                skierA: skierA,
                positionA: a.id,
                skierB: skierB,
                positionB: b.id
            ))
        }

        let unattributed = try solve(conditions: ConditionsFingerprint.defaultBucket)
        let mismatched = try solve(conditions: "unrelated-weather-bucket")

        // The accepted measured row has σ(speed)=2m/s. At 100 seconds and
        // 10m/s the delta method gives σ(time)=20 seconds.
        XCTAssertEqual(try XCTUnwrap(unattributed.etaStdSecondsA), 20, accuracy: 0.001)
        // Unrelated conditions must not supply false empirical confidence;
        // the solver falls back to the run prior of 15% × 100 seconds.
        XCTAssertEqual(try XCTUnwrap(mismatched.etaStdSecondsA), 15, accuracy: 0.001)
    }

    func testSolverPrefersDependableMeetOverNominallyFasterFragileMeet() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let fragile = node("fragile", kind: .liftBase, lon: -106.02)
        let dependable = node("dependable", kind: .liftBase, lon: -106.03)
        let aFragile = edge("a-fragile", a, fragile, length: 900)
        let bFragile = edge("b-fragile", b, fragile, length: 900)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b, fragile.id: fragile, dependable.id: dependable],
            edges: [
                aFragile, bFragile,
                edge("a-dependable", a, dependable, length: 1_000),
                edge("b-dependable", b, dependable, length: 1_000)
            ]
        )
        let skierA = profile("A")
        let skierB = profile("B")
        let observationA = observation(
            edgeID: aFragile.id,
            conditions: ConditionsFingerprint.defaultBucket,
            variance: 16
        )
        let observationB = observation(
            edgeID: bFragile.id,
            conditions: ConditionsFingerprint.defaultBucket,
            variance: 16
        )
        let solver = MeetingPointSolver(graph: graph)
        solver.datasetVersion = "dataset-v1"
        solver.edgeSpeedHistoryByProfile = [
            skierA.id.uuidString: [aFragile.id: [observationA.historyKey: observationA]],
            skierB.id.uuidString: [bFragile.id: [observationB.historyKey: observationB]]
        ]

        MeetingPointSolver.solutionCache.clear()
        let result = try XCTUnwrap(solver.solve(
            skierA: skierA, positionA: a.id,
            skierB: skierB, positionB: b.id
        ))

        XCTAssertEqual(result.meetingNode.id, dependable.id)
        XCTAssertGreaterThan(result.timeA, 90)
        let alternate = try XCTUnwrap(result.alternates.first)
        XCTAssertEqual(alternate.node.id, fragile.id)
        XCTAssertGreaterThan(
            try XCTUnwrap(alternate.etaStdSecondsA),
            try XCTUnwrap(result.etaStdSecondsA)
        )
    }

    func testPathToSameMeetPreservesSlowerDependableAlternative() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let fragileMid = node("fragile-mid", lon: -106.02)
        let dependableMid = node("dependable-mid", lon: -106.03)
        let meet = node("meet", kind: .liftBase, lon: -106.04)

        let fragile1 = edge("fragile-1", a, fragileMid, length: 450)
        let fragile2 = edge("fragile-2", fragileMid, meet, length: 450)
        let dependable1 = edge("dependable-1", a, dependableMid, length: 500)
        let dependable2 = edge("dependable-2", dependableMid, meet, length: 500)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [
                a.id: a, b.id: b, fragileMid.id: fragileMid,
                dependableMid.id: dependableMid, meet.id: meet
            ],
            edges: [
                fragile1, fragile2, dependable1, dependable2,
                edge("b-meet", b, meet, length: 1_000)
            ]
        )
        let skierA = profile("A")
        let skierB = profile("B")
        let fragileRows = [fragile1, fragile2].map {
            observation(
                edgeID: $0.id,
                conditions: ConditionsFingerprint.defaultBucket,
                variance: 36
            )
        }
        let solver = MeetingPointSolver(graph: graph)
        // Isolate route reliability from the continuous cold-snow glide model.
        solver.temperatureC = 0
        solver.datasetVersion = "dataset-v1"
        solver.edgeSpeedHistoryByProfile = [
            skierA.id.uuidString: Dictionary(
                uniqueKeysWithValues: fragileRows.map {
                    ($0.edgeId, [$0.historyKey: $0])
                }
            )
        ]

        MeetingPointSolver.solutionCache.clear()
        let result = try XCTUnwrap(solver.solve(
            skierA: skierA, positionA: a.id,
            skierB: skierB, positionB: b.id
        ))

        XCTAssertEqual(result.meetingNode.id, meet.id)
        XCTAssertEqual(result.pathA.map(\.id), [dependable1.id, dependable2.id])
        XCTAssertEqual(result.timeA, 100, accuracy: 0.001)
        XCTAssertLessThan(try XCTUnwrap(result.etaStdSecondsA), 15)
    }

    func testFairnessNeverSendsFasterSkierOnADetourToConsumeWaitTime() throws {
        let a = node("a", lon: -106.00)
        let b = node("b", lon: -106.01)
        let fastMid = node("fast-mid", lon: -106.02)
        let alignedMid = node("aligned-mid", lon: -106.03)
        let meet = node("meet", kind: .liftBase, lon: -106.04)

        let fast1 = edge("fast-1", a, fastMid, length: 300)
        let fast2 = edge("fast-2", fastMid, meet, length: 300)
        let aligned1 = edge("aligned-1", a, alignedMid, length: 500)
        let aligned2 = edge("aligned-2", alignedMid, meet, length: 500)
        let bMeet = edge("b-meet", b, meet, length: 1_000)
        let graph = MountainGraph(
            resortID: "test",
            nodes: [
                a.id: a, b.id: b, fastMid.id: fastMid,
                alignedMid.id: alignedMid, meet.id: meet
            ],
            edges: [fast1, fast2, aligned1, aligned2, bMeet]
        )
        let skierA = profile("A")
        let skierB = profile("B")
        let volatileFastRows = [fast1, fast2].map {
            observation(
                edgeID: $0.id,
                conditions: ConditionsFingerprint.defaultBucket,
                variance: 36
            )
        }
        let solver = MeetingPointSolver(graph: graph)
        // Isolate coordinated path selection from weather speed effects.
        solver.temperatureC = 0
        solver.datasetVersion = "dataset-v1"
        solver.edgeSpeedHistoryByProfile = [
            skierA.id.uuidString: Dictionary(
                uniqueKeysWithValues: volatileFastRows.map {
                    ($0.edgeId, [$0.historyKey: $0])
                }
            )
        ]

        MeetingPointSolver.solutionCache.clear()
        let result = try XCTUnwrap(solver.solve(
            skierA: skierA, positionA: a.id,
            skierB: skierB, positionB: b.id
        ))

        XCTAssertEqual(result.pathA.map(\.id), [fast1.id, fast2.id])
        XCTAssertEqual(result.pathB.map(\.id), [bMeet.id])
        XCTAssertEqual(result.timeA, 60, accuracy: 0.001)
        XCTAssertEqual(result.timeB, 100, accuracy: 0.001)
    }

    func testMeetSolveSelectsApproachPathsByJointReliability() throws {
        let a = node("joint-a", lon: -106.00)
        let b = node("joint-b", lon: -106.01)
        let fragileMid = node("joint-fragile-mid", lon: -106.02)
        let dependableMid = node("joint-dependable-mid", lon: -106.03)
        let meet = node("joint-meet", kind: .liftBase, lon: -106.04)

        let fragile1 = edge("joint-fragile-1", a, fragileMid, length: 450)
        let fragile2 = edge("joint-fragile-2", fragileMid, meet, length: 450)
        let dependable1 = edge("joint-dependable-1", a, dependableMid, length: 500)
        let dependable2 = edge("joint-dependable-2", dependableMid, meet, length: 500)
        let bMeet = edge("joint-b-meet", b, meet, length: 850)
        let graph = MountainGraph(
            resortID: "joint-path-reliability",
            nodes: [a, b, fragileMid, dependableMid, meet].reduce(into: [:]) {
                $0[$1.id] = $1
            },
            edges: [fragile1, fragile2, dependable1, dependable2, bMeet]
        )
        let catalog = RendezvousCatalog(points: [RendezvousPoint(
            id: meet.id,
            nodeID: meet.id,
            kind: .liftBase,
            confidence: 1,
            quality: 1
        )], graph: graph)
        let skierA = profile("A")
        let skierB = profile("B")
        let fragileRows = [fragile1, fragile2].map {
            observation(
                edgeID: $0.id,
                conditions: ConditionsFingerprint.defaultBucket,
                variance: 36
            )
        }
        let bRow = observation(
            edgeID: bMeet.id,
            conditions: ConditionsFingerprint.defaultBucket,
            variance: 100
        )
        let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
        solver.temperatureC = 0
        solver.datasetVersion = "dataset-v1"
        solver.edgeSpeedHistoryByProfile = [
            skierA.id.uuidString: Dictionary(
                uniqueKeysWithValues: fragileRows.map {
                    ($0.edgeId, [$0.historyKey: $0])
                }
            ),
            skierB.id.uuidString: [bMeet.id: [bRow.historyKey: bRow]],
        ]

        MeetingPointSolver.solutionCache.clear()
        let result = try XCTUnwrap(solver.solve(
            skierA: skierA,
            positionA: a.id,
            skierB: skierB,
            positionB: b.id
        ))

        // In isolation A's 100-second dependable path scores below the
        // 90-second fragile path. B's much larger independent uncertainty
        // dominates the pair, however, so paying ten more mean seconds for A
        // barely narrows the group range. The exact pair objective correctly
        // keeps the faster path and improves dependable group arrival.
        XCTAssertEqual(result.pathA.map(\.id), [fragile1.id, fragile2.id])
        XCTAssertEqual(result.timeA, 90, accuracy: 0.001)
        XCTAssertEqual(result.timeB, 85, accuracy: 0.001)
    }

    func testFrontierCapPreservesFastestApproachForTheDetourLimit() throws {
        let a = node("cap-a", lon: -106.00)
        let b = node("cap-b", lon: -106.01)
        let meet = node("cap-meet", kind: .liftBase, lon: -106.02)
        let fast = edge("fast-volatile", a, meet, length: 1_000)
        let slow = (0..<SolverConstants.Scoring.maxParetoLabelsPerNode).map {
            edge("slow-stable-\($0)", a, meet, length: 1_400 + Double($0) * 10)
        }
        let partner = edge("partner", b, meet, length: 1_000)
        let skierA = profile("A")
        let skierB = profile("B")
        let row = observation(
            edgeID: fast.id, conditions: ConditionsFingerprint.defaultBucket, variance: 400
        )

        for reversed in [false, true] {
            let edges = [fast, partner] + slow
            let graph = MountainGraph(
                resortID: "test", nodes: [a.id: a, b.id: b, meet.id: meet],
                edges: reversed ? Array(edges.reversed()) : edges
            )
            let solver = MeetingPointSolver(graph: graph)
            solver.temperatureC = 0
            solver.datasetVersion = "dataset-v1"
            solver.edgeSpeedHistoryByProfile = [
                skierA.id.uuidString: [fast.id: [row.historyKey: row]]
            ]
            MeetingPointSolver.solutionCache.clear()
            let result = try XCTUnwrap(solver.solve(
                skierA: skierA, positionA: a.id,
                skierB: skierB, positionB: b.id
            ))
            // Every stable option exceeds 100 + max(30, 15%) seconds.
            // Trimming by reliability alone must not erase that baseline and
            // make a forty-second detour look like the fastest legal path.
            XCTAssertEqual(result.pathA.map(\.id), [fast.id])
            XCTAssertEqual(result.timeA, 100, accuracy: 0.001)
            XCTAssertEqual(result.pathB.map(\.id), [partner.id])
        }
    }

    func testCachedWhistlerParetoSolveStaysInteractive() throws {
        let cacheDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ).appendingPathComponent("MountainDatasets", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        guard let url = candidates.first(where: {
            $0.lastPathComponent.hasPrefix("whistler--") && $0.pathExtension == "json"
        }) else {
            throw XCTSkip("No local Whistler mountain cache; performance scenario is device-data dependent")
        }

        let cached = try JSONDecoder().decode(
            CachedMountainDataset.self,
            from: Data(contentsOf: url)
        )
        let dataset = cached.dataset
        let incomingToRendezvous = dataset.graph.edges
            .filter { $0.attributes.isOpen && dataset.rendezvousCatalog.nodeIDs.contains($0.targetID) }
            .sorted { $0.id < $1.id }
        let startNodeID = try XCTUnwrap(incomingToRendezvous.first?.sourceID)
        let skierA = profile("A", skill: "expert")
        let skierB = profile("B", skill: "expert")
        let solver = MeetingPointSolver(
            graph: dataset.graph,
            rendezvousCatalog: dataset.rendezvousCatalog
        )
        solver.datasetVersion = dataset.version.identifier

        MeetingPointSolver.solutionCache.clear()
        let started = ContinuousClock.now
        let result = solver.solve(
            skierA: skierA, positionA: startNodeID,
            skierB: skierB, positionB: startNodeID
        )
        let elapsed = ContinuousClock.now - started

        XCTAssertNotNil(result)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "A 2,596-node Whistler solve should remain interactive in a debug simulator build"
        )
    }
}
