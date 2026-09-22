import CoreLocation
import XCTest
@testable import PowderMeet

final class GraphElevationProfileTests: XCTestCase {
    func testStraightSourceSegmentCannotAcquireNegativeAspectVariance() {
        // Attitash OSM way 1361942429 exposed floating-point normalization drift.
        let result = GraphBuilder.computeAspect(coords: [
            CLLocationCoordinate2D(latitude: 44.0795068, longitude: -71.233771),
            CLLocationCoordinate2D(latitude: 44.0797602, longitude: -71.233748)
        ])
        XCTAssertTrue(result.aspect.isFinite)
        XCTAssertGreaterThanOrEqual(result.variance, 0)
        XCTAssertLessThanOrEqual(result.variance, 1)
        XCTAssertEqual(result.variance, 0, accuracy: 1e-12)
        let opposed = GraphBuilder.computeAspect(coords: [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.01, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0)
        ])
        XCTAssertGreaterThan(opposed.variance, 0.999)
    }

    func testSharedLiftTransferStationRetainsBothRolesInAnyInsertionOrder() {
        let coordinate = Coordinate(lat: 50.09, lon: -122.95, ele: 1500, sourceNodeID: 1)
        let orders: [[GraphNode.NodeKind]] = [
            [.liftBase, .liftTop], [.liftTop, .liftBase],
            [.liftTop, .liftBase, .liftTop], [.midStation, .liftBase, .liftTop],
            [.liftBase, .trailHead, .liftTop, .junction]
        ]
        for order in orders {
            var nodes: [String: GraphNode] = [:]
            for kind in order {
                GraphBuilder.ensureNode(&nodes, id: "src:1", coord: coordinate, elevation: 1500, kind: kind)
            }
            XCTAssertEqual(nodes["src:1"]?.kind, .midStation)
            XCTAssertEqual(nodes["src:1"]?.elevation, 1500)
        }
    }

    func testGraphLengthAndPitchShareThePureSourceDistanceMetric() {
        let a = Coordinate(lat: 50.0988267, lon: -122.9498394, ele: 1035)
        let b = Coordinate(lat: 50.0984179, lon: -122.9490292, ele: 1042.1)
        let geometry = [a, b].map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let length = haversine(from: a, to: b)
        for _ in 0..<8 {
            XCTAssertEqual(GraphBuilder.polylineLength(geometry), length)
            XCTAssertEqual(GraphBuilder.computeMaxGradient([a, b]), atan(abs(1042.1 - 1035) / length) * 180 / .pi)
        }
    }

    func testEmptyOrSingletonGeometryHasNoFabricatedDistanceOrPitch() {
        let coordinate = Coordinate(lat: 50, lon: -123, ele: 1000)
        XCTAssertEqual(GraphBuilder.polylineLength([]), 0)
        XCTAssertEqual(GraphBuilder.polylineLength([CLLocationCoordinate2D(latitude: 50, longitude: -123)]), 0)
        XCTAssertEqual(GraphBuilder.computeMaxGradient([]), 0)
        XCTAssertEqual(GraphBuilder.computeMaxGradient([coordinate]), 0)
    }

    private let elevations = [1100.0, 1098, 1096, 1050, 1049, 1048, 1047, 990, 900]

    private func fixture(reverseWays: Bool = false) -> MountainGraph {
        let coordinates = elevations.enumerated().map { index, elevation in
            Coordinate(lat: 40.002 - Double(index) * 0.0002, lon: -106,
                       ele: elevation, sourceNodeID: Int64(index + 1))
        }
        func trail(_ id: Int64, _ name: String, _ coordinates: [Coordinate]) -> Trail {
            Trail(id: id, name: name, difficulty: .blue, grooming: nil,
                  coordinates: coordinates, lit: false, ref: nil, isOpen: true)
        }
        let trails = [trail(1, "Main", coordinates), trail(2, "Crossing", [
            Coordinate(lat: coordinates[4].lat, lon: -106.001, ele: 1070, sourceNodeID: 20),
            coordinates[4],
            Coordinate(lat: coordinates[4].lat, lon: -105.999, ele: 1020, sourceNodeID: 21)
        ])]
        let data = ResortData(name: "Elevation fixture",
            bounds: BoundingBox(minLat: 40, maxLat: 40.001, minLon: -106, maxLon: -105.999),
            trails: reverseWays ? Array(trails.reversed()) : trails, lifts: [], pois: [],
            fetchDate: Date(timeIntervalSince1970: 0), graphBuildHints: nil)
        return GraphBuilder.buildGraph(from: data, resortID: "elevation")
    }

    func testSourceElevationsSurviveBothSplittingStages() throws {
        let graph = fixture()
        XCTAssertEqual(graph.nodes["src:5"]?.elevation, 1049)
        let main = graph.edges.filter { $0.id.hasPrefix("t1_") }
        XCTAssertEqual(main.count, 4)
        for edge in main {
            for id in [edge.sourceID, edge.targetID] {
                let node = try XCTUnwrap(graph.nodes[id])
                let index = Int(((40.002 - node.coordinate.latitude) / 0.0002).rounded())
                XCTAssertEqual(node.elevation, elevations[index], accuracy: 0.001)
            }
        }
        XCTAssertTrue(main.contains { $0.attributes.maxGradient > $0.attributes.averageGradient + 5 })
        XCTAssertEqual(fixture(reverseWays: true).nodes["src:5"]?.elevation, 1049)
    }

    func testShortSteepPitchStillBlocksAnExplicitGradientLimitAfterSplitting() {
        let graph = fixture()
        var skier = UserProfile.defaultProfile(id: UUID())
        skier.applyPreset("expert")
        let solver = MeetingPointSolver(graph: graph)
        XCTAssertNotNil(solver.pathTo(target: "src:9", from: "src:1", skier: skier))
        skier.maxComfortableGradientDegrees = 50
        XCTAssertNil(solver.pathTo(target: "src:9", from: "src:1", skier: skier))
    }

    func testMissingSamplesUseDistanceBetweenNearestKnownAnchors() {
        let geometry = [40.001, 40.0009, 40.0008, 40.0].map {
            CLLocationCoordinate2D(latitude: $0, longitude: -106)
        }
        let profile = GraphBuilder.elevationProfile(geometry: geometry,
            raw: [100, 90, nil, 0], from: 100, to: 0)
        XCTAssertEqual(profile[2], 80, accuracy: 0.001)
        XCTAssertEqual(profile[1], 90)
        let invalid = GraphBuilder.elevationProfile(geometry: geometry,
            raw: [100, 90, .nan, 0], from: 100, to: 0)
        XCTAssertEqual(invalid[2], 80, accuracy: 0.001)
    }

    func testReversedSourceKeepsElevationAlignedWithGeometry() {
        let geometry = [40.0, 40.0008, 40.0009, 40.001].map {
            CLLocationCoordinate2D(latitude: $0, longitude: -106)
        }
        let profile = GraphBuilder.elevationProfile(geometry: geometry,
            raw: [0, nil, 90, 100], from: 0, to: 100)
        XCTAssertEqual(profile[1], 80, accuracy: 0.001)
        XCTAssertEqual(profile[2], 90)
    }
}
