import XCTest
@testable import PowderMeet

final class BidirectionalLiftTests: XCTestCase {
    private func graph(bidirectional: Bool) -> MountainGraph {
        let coords = (1...3).map { id in
            Coordinate(lat: 40 + Double(id - 1) * 0.001, lon: -106,
                       ele: Double(id * 100), sourceNodeID: Int64(id))
        }
        let lift = Lift(id: 10, name: "Gondola", type: .gondola, coordinates: coords,
                        capacity: nil, occupancy: nil, isOpen: true, isBidirectional: bidirectional)
        let trail = Trail(id: 20, name: "Run", difficulty: .blue, grooming: nil,
            coordinates: [coords[1], Coordinate(lat: 40.001, lon: -105.999, ele: 150, sourceNodeID: 4)],
            lit: false, ref: nil, isOpen: true)
        let data = ResortData(name: "Two-way", bounds: BoundingBox(minLat: 40, maxLat: 40.0001,
            minLon: -106, maxLon: -105.9999), trails: [trail], lifts: [lift], pois: [],
            fetchDate: Date(timeIntervalSince1970: 0), graphBuildHints: nil)
        return GraphBuilder.buildGraph(from: data, resortID: "two-way")
    }

    func testExplicitTwoWayLiftBoardsAtBothEndsWithOneQueueEach() throws {
        let graph = graph(bidirectional: true)
        let lifts = graph.edges.filter { $0.kind == .lift }
        XCTAssertEqual(lifts.count, 4)
        for reversed in [false, true] {
            let lane = lifts.filter { $0.id.hasSuffix("_rev") == reversed }
            let entries = lane.filter { $0.attributes.chargesLiftWait == true }
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.sourceID, reversed ? "src:3" : "src:1")
        }
        for reverse in lifts.filter({ $0.id.hasSuffix("_rev") }) {
            let forward = try XCTUnwrap(lifts.first { $0.id == String(reverse.id.dropLast(4)) })
            XCTAssertEqual(reverse.sourceID, forward.targetID)
            XCTAssertEqual(reverse.targetID, forward.sourceID)
            XCTAssertEqual(reverse.geometry.map(\.latitude), forward.geometry.reversed().map(\.latitude))
            XCTAssertEqual(reverse.attributes.rideTimeSeconds, forward.attributes.rideTimeSeconds)
        }
        try MountainGraphIntegrity.validateCanonical(graph, expectedResortID: "two-way")
        XCTAssertFalse(self.graph(bidirectional: false).edges.contains { $0.id.hasSuffix("_rev") })
    }
    func testPreviewOverlayAllocatesFullRideOncePerDirection() throws {
        var graph = graph(bidirectional: true)
        let overlay = try JSONDecoder().decode(CuratedResort.self, from: Data(#"""
        {"resortId":"two-way","version":1,"lifts":[{"name":"Reviewed Gondola",
        "osmWayIds":["10"],"rideTimeSeconds":600,"verticalRise":200,
        "weekdayWaitMinutes":8,"weekendWaitMinutes":12}]}
        """#.utf8))
        CuratedResortLoader.applyOverlay(overlay, to: &graph)
        for reversed in [false, true] {
            let lane = graph.edges.filter { $0.kind == .lift && $0.id.hasSuffix("_rev") == reversed }
            XCTAssertTrue(lane.allSatisfy { $0.attributes.trailName == "Reviewed Gondola" })
            XCTAssertEqual(lane.reduce(0) { $0 + ($1.attributes.rideTimeSeconds ?? 0) }, 600, accuracy: 1e-8)
            XCTAssertEqual(lane.reduce(0) { $0 + ($1.attributes.weekdayWaitMinutes ?? 0) }, 8)
        }
        try MountainGraphIntegrity.validateCanonical(graph, expectedResortID: "two-way")
    }

}
