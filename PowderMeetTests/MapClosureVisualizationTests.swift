import XCTest
import CoreLocation
@testable import PowderMeet

final class MapClosureVisualizationTests: XCTestCase {
    func testOverviewHierarchyFavorsMountainDefiningRunsWithoutHidingShortOnes() {
        let connector = GeoJSONBuilder.trailOverviewImportance(
            totalLengthMeters: 120,
            totalVerticalMeters: 15,
            officialRatio: 1,
            hasName: true
        )
        let fallLine = GeoJSONBuilder.trailOverviewImportance(
            totalLengthMeters: 1_800,
            totalVerticalMeters: 420,
            officialRatio: 1,
            hasName: true
        )

        XCTAssertGreaterThan(fallLine, connector)
        XCTAssertGreaterThanOrEqual(connector, 0.08)
        XCTAssertLessThanOrEqual(fallLine, 1)
    }

    func testMeetingPointFeatureCarriesHumanLandmarkMetadata() throws {
        let node = GraphNode(
            id: "peak-base",
            coordinate: .init(latitude: 50.0, longitude: -122.0),
            elevation: 1_800,
            kind: .liftBase
        )
        let point = RendezvousPoint(
            id: node.id,
            nodeID: node.id,
            kind: .liftBase,
            displayName: "Peak Chair Base",
            confidence: 0.95,
            quality: 0.9
        )

        let collection = GeoJSONBuilder.meetingPointFeature(
            node: node,
            displayName: point.displayName,
            rendezvousPoint: point
        )
        let features = try XCTUnwrap(collection["features"] as? [[String: Any]])
        let properties = try XCTUnwrap(features.first?["properties"] as? [String: Any])

        XCTAssertEqual(properties["mapLabel"] as? String, "MEET · PEAK CHAIR BASE")
        XCTAssertEqual(properties["kindLabel"] as? String, "LIFT BASE")
        XCTAssertEqual(properties["kind"] as? String, "liftBase")
    }

    func testClosureLayerIncludesOnlyValidatedClosedRunAndLiftSegments() throws {
        let a = GraphNode(
            id: "a",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 2_600,
            kind: .trailHead
        )
        let b = GraphNode(
            id: "b",
            coordinate: .init(latitude: 39.99, longitude: -106),
            elevation: 2_500,
            kind: .liftBase
        )

        func edge(
            _ id: String,
            kind: GraphEdge.EdgeKind,
            open: Bool,
            validated: Bool,
            name: String
        ) -> GraphEdge {
            GraphEdge(
                id: id,
                sourceID: a.id,
                targetID: b.id,
                kind: kind,
                geometry: [a.coordinate, b.coordinate],
                attributes: EdgeAttributes(
                    difficulty: .blue,
                    lengthMeters: 100,
                    verticalDrop: 100,
                    averageGradient: 20,
                    maxGradient: 20,
                    trailName: name,
                    isOpen: open,
                    isOfficiallyValidated: validated
                )
            )
        }

        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b],
            edges: [
                edge("closed-run", kind: .run, open: false, validated: true, name: "Couloir"),
                edge("closed-lift", kind: .lift, open: false, validated: true, name: "Summit Chair"),
                edge("open-run", kind: .run, open: true, validated: true, name: "Open Run"),
                edge("phantom", kind: .run, open: false, validated: false, name: "Phantom")
            ]
        )

        let collection = GeoJSONBuilder.closedTerrainFeatures(from: graph)
        let features = try XCTUnwrap(collection["features"] as? [[String: Any]])
        let properties = features.compactMap { $0["properties"] as? [String: Any] }
        let ids = Set(properties.compactMap { $0["id"] as? String })

        XCTAssertEqual(ids, ["closed-run", "closed-lift"])
        XCTAssertEqual(
            properties.first { $0["id"] as? String == "closed-run" }?["closedLabel"] as? String,
            "CLOSED · Couloir"
        )
    }

    func testRouteOverlayStartsAtFractionalGPSOrigin() throws {
        let a = GraphNode(
            id: "a",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 2_600,
            kind: .trailHead
        )
        let b = GraphNode(
            id: "b",
            coordinate: .init(latitude: 39.99, longitude: -106),
            elevation: 2_400,
            kind: .liftBase
        )
        let edge = GraphEdge(
            id: "run",
            sourceID: a.id,
            targetID: b.id,
            kind: .run,
            geometry: [a.coordinate, b.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                isOpen: true,
                isOfficiallyValidated: true
            )
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [a.id: a, b.id: b],
            edges: [edge]
        )

        let collection = GeoJSONBuilder.routeFeatures(
            edges: [edge],
            skierLabel: "A",
            colorHex: "#FFFFFF",
            graph: graph,
            initialEdgeFraction: 0.5
        )
        let features = try XCTUnwrap(collection["features"] as? [[String: Any]])
        let geometry = try XCTUnwrap(features.first?["geometry"] as? [String: Any])
        let coordinates = try XCTUnwrap(geometry["coordinates"] as? [[Double]])

        XCTAssertEqual(coordinates.first?[0] ?? 0, -106, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.first?[1] ?? 0, 39.995, accuracy: 0.000_01)
        XCTAssertEqual(coordinates.last?[1] ?? 0, 39.99, accuracy: 0.000_001)
    }
}
