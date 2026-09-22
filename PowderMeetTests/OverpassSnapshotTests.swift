import XCTest
@testable import PowderMeet

final class OverpassSnapshotTests: XCTestCase {
    private let kinds = [["piste:type": "downhill"], ["piste:type": "connection"], ["aerialway": "chair_lift"]]
    private let entry = ResortEntry(id: "fixture", name: "Fixture",
        bounds: BoundingBox(minLat: 40, maxLat: 40.003, minLon: -106.001, maxLon: -106),
        region: "CO", country: "USA")

    private func namedSource(_ ways: [[String: Any]], reversed: Bool = false) throws -> Data {
        var elements: [[String: Any]] = (1...8).map { id in
            ["type": "node", "id": id, "lat": 40.008 - Double(id) * 0.001, "lon": -106]
        }
        elements += ways
        return try JSONSerialization.data(withJSONObject: ["elements": reversed ? Array(elements.reversed()) : elements])
    }

    private func namedWay(_ id: Int, _ nodes: [Int], _ name: String? = nil,
                          difficulty: String = "easy", ref: String? = nil) -> [String: Any] {
        var tags = ["piste:type": "downhill", "piste:difficulty": difficulty]
        tags["name"] = name
        tags["piste:ref"] = ref
        return ["type": "way", "id": id, "tags": tags, "nodes": nodes]
    }

    func testConflictingNamesNeverFloodAnUnnamedChainOrDependOnInputOrder() async throws {
        let ways = [namedWay(10, [1, 2], "Alpine"), namedWay(20, [2, 3]),
                    namedWay(30, [3, 4]), namedWay(40, [4, 5], "Creek")]
        for reverse in [false, true] {
            let data = try await OverpassService().buildFromSnapshot(osmData: namedSource(ways, reversed: reverse),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertNil(data.trails.first { $0.id == 20 }?.name)
            XCTAssertNil(data.trails.first { $0.id == 30 }?.name)
            XCTAssertEqual(data.trails.first { $0.id == 10 }?.name, "Alpine")
            XCTAssertEqual(data.trails.first { $0.id == 40 }?.name, "Creek")
        }
    }

    func testUnambiguousNonbranchingContinuationKeepsItsTrailName() async throws {
        for closingName in [String?.none, "Alpine"] {
            var ways = [namedWay(10, [1, 2], "Alpine"), namedWay(20, [2, 3]), namedWay(30, [3, 4])]
            if let closingName { ways.append(namedWay(40, [4, 5], closingName)) }
            for reverse in [false, true] {
                let data = try await OverpassService().buildFromSnapshot(osmData: namedSource(ways, reversed: reverse),
                    elevationData: Data("{}".utf8), entry: entry)
                XCTAssertEqual(data.trails.first { $0.id == 20 }?.name, "Alpine")
                XCTAssertEqual(data.trails.first { $0.id == 30 }?.name, "Alpine")
            }
        }
    }

    func testNamesDoNotCrossBranchesInteriorJunctionsDifficultyOrExplicitReferences() async throws {
        let cases = [
            [namedWay(10, [1, 2], "Alpine"), namedWay(20, [2, 3]), namedWay(30, [2, 4], "Alpine")],
            [namedWay(10, [1, 2, 3], "Alpine"), namedWay(20, [2, 4])],
            [namedWay(10, [1, 2], "Alpine"), namedWay(20, [2, 3], difficulty: "advanced")],
            [namedWay(10, [1, 2], "Alpine"), namedWay(20, [2, 3], ref: "T42")]
        ]
        for ways in cases {
            let data = try await OverpassService().buildFromSnapshot(osmData: namedSource(ways),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertNil(data.trails.first { $0.id == 20 }?.name)
        }
    }

    func testOnlyExplicitTwoWaySourcePermissionEnablesReturnLiftTravel() async throws {
        for direction in [String?.none, "yes", "-1", "no"] {
            var tags = ["aerialway": "gondola"]
            tags["oneway"] = direction
            let data = try await OverpassService().buildFromSnapshot(
                osmData: source(tags: tags, nodes: [1, 2, 3]),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertEqual(data.lifts.first?.isBidirectional, direction == "no")
        }
    }

    func testPrivateRoutesCannotBeReopenedByOperatingStatus() async throws {
        for kind in kinds {
            for access in ["private", "no"] {
                var tags = kind; tags["access"] = access; tags["piste:status"] = "open"
                let data = try await OverpassService().buildFromSnapshot(
                    osmData: source(tags: tags, nodes: [1, 2, 3]),
                    elevationData: Data("{}".utf8), entry: entry)
                XCTAssertEqual(data.trails.count + data.lifts.count + (data.connections ?? []).count, 0)
            }
            var tags = kind; tags["access"] = "private"; tags["ski"] = "yes"
            let data = try await OverpassService().buildFromSnapshot(
                osmData: source(tags: tags, nodes: [1, 2, 3]),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertEqual(data.trails.count + data.lifts.count + (data.connections ?? []).count, 1)
        }
    }

    func testPisteFootprintsNeverBecomePerimeterRoutes() async throws {
        for type in ["downhill", "connection"] {
            for refs in [[1, 2, 3, 1], [999]] {
                let data = try await OverpassService().buildFromSnapshot(
                    osmData: source(tags: ["piste:type": type, "area": "yes"], nodes: refs),
                    elevationData: Data("{}".utf8), entry: entry)
                XCTAssertTrue(data.trails.isEmpty)
                XCTAssertTrue((data.connections ?? []).isEmpty)
            }
            let line = try await OverpassService().buildFromSnapshot(
                osmData: source(tags: ["piste:type": type, "area": "no"], nodes: [1, 2, 3]),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertEqual(line.trails.count + (line.connections ?? []).count, 1)
        }
    }

    func testNonRoutingAerialwaysAndMixedPisteTagsMatchCanonicalParser() async throws {
        for aerialway in ["station", "zip_line"] {
            for nodes in [[1, 2, 3], [999]] {
                let data = try await OverpassService().buildFromSnapshot(
                    osmData: source(tags: ["aerialway": aerialway], nodes: nodes),
                    elevationData: Data("{}".utf8), entry: entry)
                XCTAssertTrue(data.lifts.isEmpty)
                XCTAssertTrue(data.trails.isEmpty)
            }
        }
        for type in ["downhill", "connection", "nordic"] {
            let data = try await OverpassService().buildFromSnapshot(
                osmData: source(tags: ["piste:type": type, "aerialway": "chair_lift"], nodes: [1, 2, 3]),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertTrue(data.lifts.isEmpty)
            XCTAssertEqual(data.trails.count, type == "downhill" ? 1 : 0)
            XCTAssertEqual((data.connections ?? []).count, type == "connection" ? 1 : 0)
        }
    }

    func testExplicitClosuresSurviveSnapshotParsing() async throws {
        for tags in kinds {
            for closed in [true, false] {
                var tags = tags
                tags["piste:status"] = closed ? "closed" : "open"
                tags["opening_hours"] = closed ? "closed" : "24/7"
                let data = try await OverpassService().buildFromSnapshot(
                    osmData: source(tags: tags, nodes: [1, 2, 3]),
                    elevationData: Data("{}".utf8), entry: entry)
                let flags = data.trails.map(\.isOpen) + data.lifts.map(\.isOpen)
                    + (data.connections ?? []).map(\.isOpen)
                XCTAssertEqual(flags, [!closed])
            }
        }
    }

    private func source(tags: [String: String], nodes: [Int], latitude: Double = 40.001) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["elements": [
            ["type": "node", "id": 1, "lat": 40.002, "lon": -106],
            ["type": "node", "id": 2, "lat": latitude, "lon": -106],
            ["type": "node", "id": 3, "lat": 40, "lon": -106],
            ["type": "way", "id": 10, "tags": tags, "nodes": nodes],
            ["type": "way", "id": 20, "tags": ["highway": "service"], "nodes": [999]]
        ]])
    }

    private func elevationSource(tags: [String: String], latitudes: [Double], elevations: [String?]) throws -> Data {
        var elements: [[String: Any]] = latitudes.enumerated().map { index, latitude in
            var node: [String: Any] = ["type": "node", "id": index + 1, "lat": latitude, "lon": -106]
            if let elevation = elevations[index] { node["tags"] = ["ele": elevation] }
            return node
        }
        elements.append(["type": "way", "id": 10, "tags": tags, "nodes": Array(1...latitudes.count)])
        return try JSONSerialization.data(withJSONObject: ["elements": elements])
    }

    private func coordinates(_ data: ResortData) throws -> [Coordinate] {
        try XCTUnwrap((data.trails.map(\.coordinates) + data.lifts.map(\.coordinates)
            + (data.connections ?? []).map(\.coordinates)).first)
    }

    func testTerrainSamplesAreAppliedBeforeAnyInterpolation() async throws {
        for tags in kinds {
            let source = try elevationSource(tags: tags, latitudes: [40.002, 40.0019, 40],
                elevations: ["1100", nil, "900"])
            let data = try await OverpassService().buildFromSnapshot(osmData: source,
                elevationData: Data("{\"40.001900,-106.000000\":1099}".utf8), entry: entry)
            let result = try coordinates(data)
            XCTAssertEqual(result.map(\.ele), [1100, 1099, 900], "Interpolation must never block an available terrain sample")
            XCTAssertEqual(result.map(\.sourceNodeID), [1, 2, 3])
        }
    }

    func testResidualElevationGapsInterpolateByDistanceBetweenNearestSamples() async throws {
        for tags in kinds {
            let source = try elevationSource(tags: tags, latitudes: [40.002, 40.0019, 40.0018, 40],
                elevations: ["1100", nil, nil, "900"])
            let data = try await OverpassService().buildFromSnapshot(osmData: source,
                elevationData: Data("{\"40.001900,-106.000000\":1090}".utf8), entry: entry)
            let result = try coordinates(data)
            XCTAssertEqual(try XCTUnwrap(result[1].ele), 1090, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(result[2].ele), 1080, accuracy: 0.001)
        }
    }

    func testInvalidSourceElevationDoesNotBlockTerrainSampleAndMissingStaysUnknown() async throws {
        for tags in kinds {
            let source = try elevationSource(tags: tags, latitudes: [40.002, 40.0019, 40],
                elevations: ["1100", "nan", "900"])
            let data = try await OverpassService().buildFromSnapshot(osmData: source,
                elevationData: Data("{\"40.001900,-106.000000\":1099}".utf8), entry: entry)
            XCTAssertEqual(try coordinates(data).map(\.ele), [1100, 1099, 900])
            let unknown = try await OverpassService().buildFromSnapshot(
                osmData: elevationSource(tags: tags, latitudes: [40.002, 40.0019, 40], elevations: [nil, nil, nil]),
                elevationData: Data("{}".utf8), entry: entry)
            XCTAssertTrue(try coordinates(unknown).allSatisfy { $0.ele == nil })
        }
    }

    func testSnapshotTerrainPitchSurvivesIntoSkierRouteEligibility() async throws {
        let heights = [1100.0, 1098, 1096, 1050, 1049, 1048, 1047, 990, 900]
        let latitudes = heights.indices.map { 40.002 - Double($0) * 0.0002 }
        let raw: [String?] = heights.indices.map { $0 == 0 || $0 == 8 ? String(heights[$0]) : nil }
        let source = try elevationSource(tags: ["piste:type": "downhill", "piste:difficulty": "intermediate"],
            latitudes: latitudes, elevations: raw)
        let samples = Dictionary(uniqueKeysWithValues: heights.indices.map {
            (String(format: "%.6f,-106.000000", latitudes[$0]), heights[$0])
        })
        let data = try await OverpassService().buildFromSnapshot(osmData: source,
            elevationData: JSONSerialization.data(withJSONObject: samples), entry: entry)
        let graph = GraphBuilder.buildGraph(from: data, resortID: entry.id)
        var skier = UserProfile.defaultProfile(id: UUID())
        skier.applyPreset("expert")
        let solver = MeetingPointSolver(graph: graph)
        XCTAssertNotNil(solver.pathTo(target: "src:9", from: "src:1", skier: skier))
        skier.maxComfortableGradientDegrees = 50
        XCTAssertNil(solver.pathTo(target: "src:9", from: "src:1", skier: skier),
            "A real short steep pitch must not disappear between snapshot loading and routing")
    }

    func testMissingInteriorAndEndpointNodesRejectEveryRoutingWayKind() async throws {
        for tags in kinds {
            for nodes in [[1, 99, 3], [99, 2, 3], [1, 2, 99]] {
                do {
                    _ = try await OverpassService().buildFromSnapshot(osmData: source(tags: tags, nodes: nodes),
                        elevationData: Data("{}".utf8), entry: entry)
                    XCTFail("Must not bridge missing node 99 in way 10")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("10"))
                }
            }
        }
    }

    func testShortAndInvalidCoordinateWaysReject() async throws {
        for tags in kinds {
            for nodes in [[], [1], [1, 2, 3]] {
                do {
                    _ = try await OverpassService().buildFromSnapshot(osmData: source(tags: tags, nodes: nodes, latitude: 91),
                        elevationData: Data("{}".utf8), entry: entry)
                    XCTFail("Incomplete or invalid route must fail")
                } catch { XCTAssertTrue(error.localizedDescription.contains("10")) }
            }
        }
    }

    func testCompleteSourcePreservesVerticesAndIgnoresUnrelatedIncompleteWays() async throws {
        for tags in kinds {
            let data = try await OverpassService().buildFromSnapshot(osmData: source(tags: tags, nodes: [1, 2, 3]),
                elevationData: Data("{\"40.001000,-106.000000\":1049}".utf8), entry: entry)
            let routes = data.trails.map(\.coordinates) + data.lifts.map(\.coordinates) + (data.connections ?? []).map(\.coordinates)
            XCTAssertEqual(routes.count, 1)
            XCTAssertEqual(routes.first?.map(\.sourceNodeID), [1, 2, 3])
            XCTAssertEqual(routes.first?[1].ele, 1049)
        }
    }
}
