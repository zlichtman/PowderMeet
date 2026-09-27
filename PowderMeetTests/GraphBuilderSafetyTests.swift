//
//  GraphBuilderSafetyTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class GraphBuilderSafetyTests: XCTestCase {
    private func resort(
        trails: [Trail],
        lifts: [Lift] = [],
        connections: [PisteConnection] = []
    ) -> ResortData {
        ResortData(
            name: "Test",
            bounds: BoundingBox(
                minLat: 39.999,
                maxLat: 40.001,
                minLon: -106.001,
                maxLon: -105.999
            ),
            trails: trails,
            lifts: lifts,
            connections: connections,
            pois: [],
            fetchDate: Date(timeIntervalSince1970: 0),
            graphBuildHints: nil
        )
    }

    private func edge(id: String, source: String, target: String, name: String) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source,
            targetID: target,
            kind: .run,
            geometry: [
                CLLocationCoordinate2D(latitude: 40, longitude: -106),
                CLLocationCoordinate2D(latitude: 39.99, longitude: -106)
            ],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                trailName: name,
                isOpen: true
            )
        )
    }

    private func coincidentTrail(id: Int64, longitudeOffset: Double) -> Trail {
        let coordinates: [Coordinate] = [
            Coordinate(
                lat: 40.0002,
                lon: -106 + longitudeOffset,
                ele: 20,
                sourceNodeID: id * 10
            ),
            Coordinate(
                lat: 40.0001,
                lon: -106,
                ele: 10,
                sourceNodeID: id * 10 + 1
            ),
            Coordinate(
                lat: 40,
                lon: -106 + longitudeOffset,
                ele: 0,
                sourceNodeID: id * 10 + 2
            )
        ]
        return Trail(
            id: id,
            name: "Run \(id)",
            difficulty: .blue,
            grooming: nil,
            coordinates: coordinates,
            lit: false,
            ref: nil,
            isOpen: true
        )
    }

    func testTrailGroupIDsAreIndependentOfInputOrder() {
        let first = edge(id: "osm-1", source: "a", target: "b", name: "Bluebird")
        let second = edge(id: "osm-2", source: "b", target: "c", name: "Bluebird")
        var forward = [first, second]
        var reversed = [second, first]

        GraphBuilder.assignTrailGroups(&forward)
        GraphBuilder.assignTrailGroups(&reversed)

        let lhs = Dictionary(uniqueKeysWithValues: forward.map { ($0.id, $0.attributes.trailGroupId) })
        let rhs = Dictionary(uniqueKeysWithValues: reversed.map { ($0.id, $0.attributes.trailGroupId) })
        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs["osm-1"]!, lhs["osm-2"]!)
    }

    func testUnrelatedTrailDoesNotRenumberExistingGroup() {
        let first = edge(id: "osm-1", source: "a", target: "b", name: "Bluebird")
        let second = edge(id: "osm-2", source: "b", target: "c", name: "Bluebird")
        var baseline = [first, second]
        var expanded = [
            edge(id: "aaa-new", source: "x", target: "y", name: "Another Trail"),
            first,
            second
        ]

        GraphBuilder.assignTrailGroups(&baseline)
        GraphBuilder.assignTrailGroups(&expanded)

        XCTAssertEqual(
            baseline.first { $0.id == "osm-1" }?.attributes.trailGroupId,
            expanded.first { $0.id == "osm-1" }?.attributes.trailGroupId
        )
    }

    func testBuilderSplitsOnlyAtExactSharedSourceVertices() {
        let first = Trail(
            id: 1,
            name: "One",
            difficulty: .blue,
            grooming: nil,
            coordinates: [
                Coordinate(lat: 40.0002, lon: -106, ele: 20, sourceNodeID: 1),
                Coordinate(lat: 40.0001, lon: -106, ele: 10, sourceNodeID: 99),
                Coordinate(lat: 40, lon: -106, ele: 0, sourceNodeID: 2)
            ],
            lit: false,
            ref: nil,
            isOpen: true
        )
        let second = Trail(
            id: 2,
            name: "Two",
            difficulty: .green,
            grooming: nil,
            coordinates: [
                Coordinate(lat: 40.0001, lon: -106.0001, ele: 15, sourceNodeID: 3),
                Coordinate(lat: 40.0001, lon: -106, ele: 10, sourceNodeID: 99),
                Coordinate(lat: 40, lon: -106.0001, ele: 0, sourceNodeID: 4)
            ],
            lit: false,
            ref: nil,
            isOpen: true
        )

        let graph = GraphBuilder.buildGraph(
            from: resort(trails: [first, second]),
            resortID: "test"
        )
        let runEdges = graph.edges.filter { edge in
            edge.kind == GraphEdge.EdgeKind.run
        }
        XCTAssertEqual(runEdges.count, 4)
        XCTAssertEqual(
            graph.edges.filter {
                $0.sourceID == "src:99" ||
                $0.targetID == "src:99"
            }.count,
            4
        )
        XCTAssertFalse(graph.edges.contains { $0.id.contains("_ix") })
    }

    func testBuilderKeepsCoincidentDifferentSourceVerticesDisconnected() {
        let trails = [
            coincidentTrail(id: 1, longitudeOffset: -0.001),
            coincidentTrail(id: 2, longitudeOffset: 0.001)
        ]

        let graph = GraphBuilder.buildGraph(from: resort(trails: trails), resortID: "test")
        let runEdges = graph.edges.filter { edge in
            edge.kind == GraphEdge.EdgeKind.run
        }
        XCTAssertEqual(runEdges.count, 4)
        let coincidentNodes = graph.nodes.values.filter { node in
            node.coordinate.latitude == 40.0001 && node.coordinate.longitude == -106
        }
        XCTAssertEqual(coincidentNodes.count, 2)
        XCTAssertEqual(Set(coincidentNodes.map(\.id)).count, 2)
    }

    func testBuilderKeepsCoincidentDifferentSourceEndpointsDisconnected() {
        let upper = Trail(
            id: 1,
            name: "Upper",
            difficulty: .blue,
            grooming: nil,
            coordinates: [
                Coordinate(lat: 40.001, lon: -106, ele: 100, sourceNodeID: 10),
                Coordinate(lat: 40, lon: -106, ele: 0, sourceNodeID: 11)
            ],
            lit: false,
            ref: nil,
            isOpen: true
        )
        let lower = Trail(
            id: 2,
            name: "Lower",
            difficulty: .blue,
            grooming: nil,
            coordinates: [
                Coordinate(lat: 40, lon: -106, ele: 100, sourceNodeID: 20),
                Coordinate(lat: 39.999, lon: -106, ele: 0, sourceNodeID: 21)
            ],
            lit: false,
            ref: nil,
            isOpen: true
        )

        let graph = GraphBuilder.buildGraph(
            from: resort(trails: [upper, lower]),
            resortID: "test"
        )
        let upperEdge = graph.edges.first { $0.id == "t1" }
        let lowerEdge = graph.edges.first { $0.id == "t2" }

        XCTAssertNotEqual(upperEdge?.targetID, lowerEdge?.sourceID)
        XCTAssertEqual(
            graph.nodes.values.filter {
                $0.coordinate.latitude == 40 && $0.coordinate.longitude == -106
            }.count,
            2
        )
    }

    func testExplicitConnectionIsBidirectionalAndLiftKindWins() {
        let run = Trail(
            id: 1,
            name: "Run",
            difficulty: .blue,
            grooming: nil,
            coordinates: [
                Coordinate(lat: 40.0002, lon: -106, ele: 20, sourceNodeID: 1),
                Coordinate(lat: 40, lon: -106, ele: 0, sourceNodeID: 2)
            ],
            lit: false,
            ref: nil,
            isOpen: true
        )
        let lift = Lift(
            id: 2,
            name: "Lift",
            type: .chairLift,
            coordinates: [
                Coordinate(lat: 40, lon: -106, ele: 0, sourceNodeID: 2),
                Coordinate(lat: 40.0002, lon: -106, ele: 20, sourceNodeID: 1)
            ],
            capacity: nil,
            occupancy: nil,
            isOpen: true
        )
        let connection = PisteConnection(
            id: 3,
            name: "Walkway",
            coordinates: [
                Coordinate(lat: 40, lon: -106, ele: 0, sourceNodeID: 2),
                Coordinate(lat: 40, lon: -106.0001, ele: 1, sourceNodeID: 3)
            ],
            isOpen: true
        )

        let graph = GraphBuilder.buildGraph(
            from: resort(trails: [run], lifts: [lift], connections: [connection]),
            resortID: "test"
        )
        let traverses = graph.edges.filter { edge in
            edge.kind == GraphEdge.EdgeKind.traverse
        }
        XCTAssertEqual(traverses.count, 2)
        XCTAssertEqual(
            graph.nodes["src:2"]?.kind,
            GraphNode.NodeKind.liftBase
        )
        XCTAssertEqual(
            graph.nodes["src:1"]?.kind,
            GraphNode.NodeKind.liftTop
        )
    }
}
