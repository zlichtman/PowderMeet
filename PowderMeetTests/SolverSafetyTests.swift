//
//  SolverSafetyTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class SolverSafetyTests: XCTestCase {

    private func profile(_ name: String) -> UserProfile {
        UserProfile(
            id: UUID(),
            displayName: name,
            skillLevel: "intermediate",
            speedGreen: 6,
            speedBlue: 8,
            conditionMoguls: 1,
            conditionUngroomed: 1,
            conditionIcy: 1,
            conditionGladed: 1,
            onboardingCompleted: true
        )
    }

    func testStrictSolveNeverSubstitutesNearbyEscapeNode() {
        let nodes: [String: GraphNode] = [
            "dead": GraphNode(
                id: "dead",
                coordinate: .init(latitude: 40, longitude: -106),
                elevation: 3_000,
                kind: .trailEnd
            ),
            "start": GraphNode(
                id: "start",
                coordinate: .init(latitude: 40.0001, longitude: -106),
                elevation: 3_000,
                kind: .trailHead
            ),
            "target": GraphNode(
                id: "target",
                coordinate: .init(latitude: 39.99, longitude: -106),
                elevation: 2_900,
                kind: .liftBase
            )
        ]
        let edge = GraphEdge(
            id: "safe-run",
            sourceID: "start",
            targetID: "target",
            kind: .run,
            geometry: [nodes["start"]!.coordinate, nodes["target"]!.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                isOpen: true
            )
        )
        let solver = MeetingPointSolver(
            graph: MountainGraph(resortID: "test", nodes: nodes, edges: [edge])
        )

        XCTAssertNil(solver.solve(
            skierA: profile("A"),
            positionA: "dead",
            skierB: profile("B"),
            positionB: "start"
        ))
        guard case .skierAtDeadEnd(let name) = solver.lastFailureReason else {
            return XCTFail("Expected exact-start dead-end failure")
        }
        XCTAssertEqual(name, "A")
    }
}
