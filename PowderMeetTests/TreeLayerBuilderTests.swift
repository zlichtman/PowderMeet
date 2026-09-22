import XCTest
import CoreLocation
@testable import PowderMeet

final class TreeLayerBuilderTests: XCTestCase {
    private let bounds = BoundingBox(
        minLat: 40.000,
        maxLat: 40.006,
        minLon: -106.006,
        maxLon: -106.000
    )

    private func entry(treeLine: Double) -> ResortEntry {
        ResortEntry(
            id: "tree-test",
            name: "Tree Test",
            bounds: bounds,
            region: "CO",
            country: "USA",
            treeLineMeters: treeLine
        )
    }

    private func graph(elevation: Double) -> MountainGraph {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 40.000, longitude: -106.006),
            CLLocationCoordinate2D(latitude: 40.000, longitude: -106.000),
            CLLocationCoordinate2D(latitude: 40.006, longitude: -106.006),
            CLLocationCoordinate2D(latitude: 40.006, longitude: -106.000),
        ]
        let nodes = Dictionary(uniqueKeysWithValues: coordinates.enumerated().map { index, coordinate in
            let node = GraphNode(
                id: "node-\(index)",
                coordinate: coordinate,
                elevation: elevation,
                kind: .junction
            )
            return (node.id, node)
        })
        return MountainGraph(resortID: "tree-test", nodes: nodes, edges: [])
    }

    func testTreesAreOmittedAboveTheResortTreeLine() {
        let collection = TreeLayerBuilder.generateFeatureCollection(
            entry: entry(treeLine: 2_400),
            graph: graph(elevation: 3_000),
            snowyHint: false
        )

        XCTAssertTrue(collection.features.isEmpty)
    }

    func testTreesRemainBelowTheResortTreeLine() {
        let collection = TreeLayerBuilder.generateFeatureCollection(
            entry: entry(treeLine: 2_400),
            graph: graph(elevation: 2_000),
            snowyHint: false
        )

        XCTAssertFalse(collection.features.isEmpty)
    }

    func testTreesAreNotInventedWithoutNearbyElevationEvidence() {
        let farNode = GraphNode(
            id: "far",
            coordinate: CLLocationCoordinate2D(latitude: 41, longitude: -107),
            elevation: 2_000,
            kind: .junction
        )
        let graph = MountainGraph(
            resortID: "tree-test",
            nodes: [farNode.id: farNode],
            edges: []
        )
        let collection = TreeLayerBuilder.generateFeatureCollection(
            entry: entry(treeLine: 2_400),
            graph: graph,
            snowyHint: false
        )

        XCTAssertTrue(collection.features.isEmpty)
    }
}
