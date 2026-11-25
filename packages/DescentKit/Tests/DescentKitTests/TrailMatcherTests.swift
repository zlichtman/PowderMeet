import Foundation
import MountainCore
import Testing
@testable import DescentKit

/// The map matcher on small synthetic graphs.
struct TrailMatcherTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ lat: Double) -> TrackPoint {
        TrackPoint(lat: lat, lon: -106, elevationM: lat * 10_000)
    }

    private func timedPoint(_ lat: Double, second: TimeInterval) -> TrackPoint {
        TrackPoint(lat: lat, lon: -106, elevationM: lat * 10_000, timestamp: origin.addingTimeInterval(second))
    }

    private func run(
        _ id: EdgeID, _ source: NodeID, _ target: NodeID, _ geometry: [(lat: Double, lon: Double)],
        group: GroupID? = nil, name: String? = nil
    ) -> Edge {
        Edge(
            id: id, from: source, to: target, kind: .run, group: group, name: name, difficulty: .blue,
            geometry: geometry.map { GeoPoint(lon: $0.lon, lat: $0.lat, eleM: 0) },
            lengthM: 0, verticalM: 0
        )
    }

    private func edge(id: EdgeID, source: NodeID, target: NodeID, from: Double, to: Double) -> Edge {
        run(id, source, target, [(from, -106), (to, -106)])
    }

    private func corridorEdge(id: String, x: Double, top: Double, bottom: Double) -> Edge {
        run(EdgeID(id), NodeID("\(id)-top"), NodeID("\(id)-bottom"),
            [(top / 111_132, -106 + x / 111_320), (bottom / 111_132, -106 + x / 111_320)])
    }

    private func corridorPoint(x: Double, y: Double, second: Double) -> TrackPoint {
        TrackPoint(lat: y / 111_132, lon: -106 + x / 111_320, timestamp: origin.addingTimeInterval(second))
    }

    private func matcher(_ edges: [Edge]) -> TrailMatcher {
        let nodeIDs = Set(edges.flatMap { [$0.from, $0.to] })
        let nodes = nodeIDs.map { Node(id: $0, lon: -106, lat: 0, eleM: 0, kind: .junction) }
        return TrailMatcher(graph: Graph(nodes: nodes, edges: edges))
    }

    private func placed(_ matcher: TrailMatcher, _ points: [TrackPoint]) -> TrailMatch? {
        guard case .success(let match) = matcher.evaluate(points), match.coverage >= TrailMatcher.minimumCoverage
        else { return nil }
        return match
    }

    @Test func projectsOntoPolylineInteriorRatherThanOnlyVertices() throws {
        let matcher = matcher([edge(id: "long", source: "top", target: "bottom", from: 0.01, to: 0)])
        let result = try #require(placed(matcher, [point(0.006), point(0.005), point(0.004)]))
        #expect(result.segmentIDs == ["long"])
        #expect(result.meanDistanceMeters < 1)
        #expect(result.confidence > 0.9)
    }

    @Test func returnsTheSegmentSequenceInTravelOrder() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let result = try #require(placed(matcher([lower, upper]), [
            point(0.009), point(0.007), point(0.0055), point(0.0045), point(0.003), point(0.001),
        ]))
        #expect(result.segmentIDs == ["upper", "lower"])
        #expect(result.transitions.successor == 1)
        #expect(result.confidence >= 0.75)
    }

    /// A shared-node-only rule rejects this whole descent (`noConnectedTransition`): two
    /// ways that meet on the ground but share no node, which is most of the
    /// junctions in the published bundles.
    @Test func trailsThatTouchWithoutASharedNodeStillMatch() throws {
        let upper = edge(id: "upper", source: "top", target: "mid-a", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid-b", target: "bottom", from: 0.005, to: 0)
        let result = try #require(placed(matcher([upper, lower]), [point(0.009), point(0.007), point(0.004), point(0.001)]))
        #expect(result.segmentIDs == ["upper", "lower"])
        #expect(result.transitions.jump == 1)
    }

    @Test func graphContinuationBreaksATieWithAnOverlappingDeadEnd() throws {
        let decoy = edge(id: "a-decoy", source: "other-top", target: "dead-end", from: 0.01, to: 0.005)
        let upper = edge(id: "z-upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let points = [point(0.009), point(0.007), point(0.004), point(0.002)]
        for edges in [[decoy, upper, lower], [lower, upper, decoy]] {
            #expect(try #require(placed(matcher(edges), points)).segmentIDs == ["z-upper", "lower"])
        }
    }

    @Test func nearbyTrailsDoNotStealADescentFromTheOneItFollows() throws {
        let actual = corridorEdge(id: "actual", x: 0, top: 400, bottom: 0)
        let nearby = (0..<12).map { corridorEdge(id: "decoy-\($0)", x: 25 + Double($0) / 10, top: 100, bottom: 0) }
        let points = (0...16).map { corridorPoint(x: 0, y: 380 - Double($0) * 22, second: Double($0) * 3) }
        for edges in [[actual] + nearby, Array(([actual] + nearby).reversed())] {
            let match = try #require(placed(matcher(edges), points))
            #expect(match.segmentIDs == [actual.id])
        }
    }

    @Test func equallyFittingParallelTrailsAreResolvedTheSameWayWhateverTheOrder() throws {
        let edges = [corridorEdge(id: "left", x: -10, top: 350, bottom: 0),
                     corridorEdge(id: "right", x: 10, top: 350, bottom: 0)]
        let points = (0...10).map { corridorPoint(x: 0, y: 300 - Double($0) * 25, second: Double($0) * 5) }
        let first = try #require(placed(matcher(edges), points))
        let second = try #require(placed(matcher(edges.reversed()), points))
        #expect(first.segmentIDs.count == 1)
        #expect(first.segmentIDs == second.segmentIDs)
    }

    @Test func travelAgainstADirectedRunIsNotPlacedOnIt() {
        let matcher = matcher([edge(id: "down", source: "top", target: "bottom", from: 0.001, to: 0)])
        let northbound = (0...20).map { TrackPoint(lat: Double($0) * 0.00004, lon: -106) }
        #expect(placed(matcher, northbound) == nil)
        #expect(placed(matcher, Array(northbound.reversed())) != nil)
    }

    @Test func climbingIsNotADescent() {
        let matcher = matcher([edge(id: "downhill", source: "top", target: "bottom", from: 0.01, to: 0)])
        let uphill = [point(0.001), point(0.004), point(0.007), point(0.009)]
        #expect(matcher.evaluate(uphill).failure == .invalidDescent)
        #expect(matcher.approximateEdge(for: uphill) == nil)
    }

    @Test func rejectionsDistinguishInputGeometryAndCoverage() {
        let matcher = matcher([edge(id: "run", source: "top", target: "bottom", from: 0.01, to: 0)])
        #expect(matcher.evaluate([]).failure == .invalidDescent)
        #expect(self.matcher([]).evaluate([point(0.02), point(0.018)]).failure == .noTrailGeometry)
        let far = [point(0.02), point(0.018), point(0.016)]
        #expect(placed(matcher, far) == nil)
    }

    @Test func oppositeHairpinLegIsNotForwardTravelOnTheNearestLeg() throws {
        let hairpin = run("hairpin", "start", "finish", [(0, 0), (0.001, 0), (0.001, 0.00036), (0, 0.00036)])
        let matcher = matcher([hairpin])
        func points(lon: Double) -> [TrackPoint] {
            (0..<7).map {
                TrackPoint(lat: 0.0008 - Double($0) * 0.0001, lon: lon,
                           timestamp: origin.addingTimeInterval(Double($0) * 3))
            }
        }
        #expect(placed(matcher, points(lon: 0)) == nil)
        let correct = try #require(placed(matcher, points(lon: 0.00036)))
        #expect(correct.segmentIDs == [hairpin.id])
        #expect(!correct.edgePaces.isEmpty)
    }

    @Test func directionFollowsTheCarvingTrendNotEachTurn() throws {
        let trail = edge(id: "carving", source: "top", target: "bottom", from: 0.01, to: 0)
        let matcher = matcher([trail])
        for timed in [false, true] {
            let points = (0..<81).map { index in
                TrackPoint(lat: 0.009 - Double(index) * 3 / 111_132,
                           lon: -106 + 10 * sin(Double(index) * .pi / 4) / 111_320,
                           timestamp: timed ? origin.addingTimeInterval(Double(index)) : nil)
            }
            #expect(try #require(placed(matcher, points)).segmentIDs == [trail.id])
            let reversed = points.reversed().enumerated().map { index, point in
                TrackPoint(lat: point.lat, lon: point.lon,
                           timestamp: timed ? origin.addingTimeInterval(Double(index)) : nil)
            }
            #expect(placed(matcher, reversed) == nil)
        }
    }

    // MARK: - Pace

    /// Three fast intervals wholly on the upper edge, one cross-boundary
    /// interval that must be left out, and three slower ones on the lower edge.
    private var twoPacePoints: [TrackPoint] {
        [
            timedPoint(0.0095, second: 0), timedPoint(0.0090, second: 5),
            timedPoint(0.0085, second: 10), timedPoint(0.0080, second: 15),
            timedPoint(0.0048, second: 20), timedPoint(0.0046, second: 25),
            timedPoint(0.0044, second: 30), timedPoint(0.0042, second: 35),
        ]
    }

    @Test func attributesDifferentPaceToEachExactEdge() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let result = try #require(placed(matcher([upper, lower]), twoPacePoints))
        #expect(result.segmentIDs == ["upper", "lower"])
        #expect(result.edgePaces.map(\.edgeID) == ["upper", "lower"])
        let upperPace = try #require(result.edgePaces.first)
        let lowerPace = try #require(result.edgePaces.last)
        #expect(upperPace.speedMS > lowerPace.speedMS * 2)
        #expect(abs(upperPace.durationS - 15) < 0.001)
        #expect(abs(lowerPace.durationS - 15) < 0.001)
    }

    @Test func sparseMultiEdgeTrackKeepsTheRouteWithoutInventingPace() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let result = try #require(placed(matcher([upper, lower]), [
            timedPoint(0.008, second: 0), timedPoint(0.004, second: 60),
        ]))
        #expect(result.segmentIDs == ["upper", "lower"])
        #expect(result.edgePaces.isEmpty)
    }

    @Test func backwardMovementCannotInflateLearnedDownhillPace() throws {
        let trail = edge(id: "downhill", source: "top", target: "bottom", from: 0.01, to: 0)
        var points = (0..<12).map { index in
            TrackPoint(lat: 0.009 - Double(index) * 0.0002, lon: -106,
                       timestamp: origin.addingTimeInterval(Double(index) * 5))
        }
        points.append(TrackPoint(lat: 0.0074, lon: -106, timestamp: origin.addingTimeInterval(60)))
        points.append(TrackPoint(lat: 0.0080, lon: -106, timestamp: origin.addingTimeInterval(65)))
        let observation = try #require(placed(matcher([trail]), points)?.edgePaces.first)
        let expectedSpeed = GPXSpeedStats.movingAverageSpeed(Array(points.prefix(12)))
        #expect(abs(observation.durationS - 55) < 0.001)
        #expect(abs(observation.speedMS - expectedSpeed) < 0.001)
    }

    @Test func tinyTerminalJitterCannotTrainSkiPace() throws {
        let matcher = matcher([edge(id: "run", source: "top", target: "base", from: 0.01, to: 0)])
        let moving = (0...7).map { timedPoint(0.009 - Double($0) * 0.0005, second: Double($0) * 5) }
        let arrival = timedPoint(0.005, second: 40)
        let stopped = (1...6).map { index in
            timedPoint(0.005 - Double(index) * 0.02 / 111_132, second: 40 + Double(index))
        }
        let before = try #require(placed(matcher, moving + [arrival])?.edgePaces.first)
        let after = try #require(placed(matcher, moving + [arrival] + stopped)?.edgePaces.first)
        #expect(abs(after.durationS - before.durationS) < 0.000001)
        #expect(abs(after.distanceM - before.distanceM) < 0.000001)
    }

    @Test func movingIntervalsAndAverageSharePausePolicy() {
        let points = [
            timedPoint(0.0090, second: 0), timedPoint(0.0085, second: 5), timedPoint(0.0085, second: 10),
            timedPoint(0.0085, second: 20), timedPoint(0.0080, second: 25),
        ]
        let intervals = GPXSpeedStats.movingIntervals(points)
        let distance = intervals.reduce(0) { $0 + $1.distanceM }
        let duration = intervals.reduce(0) { $0 + $1.durationS }
        #expect(intervals.map(\.startIndex) == [0, 3])
        #expect(abs(GPXSpeedStats.movingAverageSpeed(points) - distance / duration) < 0.000_001)
    }

    // MARK: - Public surface

    private func bundle(_ edges: [Edge], groups: [MountainCore.Group] = []) throws -> ResortBundle {
        let nodeIDs = Set(edges.flatMap { [$0.from, $0.to] })
        let document = BundleDocument(
            resortID: "test", name: "Test", timezone: "America/Denver",
            bbox: BoundingBox(minLon: -107, minLat: -1, maxLon: -105, maxLat: 1),
            center: Coordinate(lon: -106, lat: 0),
            source: .init(extractID: "test", osmExtractAt: origin, manifestVersion: 1),
            builtAt: origin,
            nodes: nodeIDs.map { Node(id: $0, lon: -106, lat: 0, eleM: 0, kind: .junction) },
            edges: edges, groups: groups, rendezvous: []
        )
        return ResortBundle(id: try #require(BundleID(String(repeating: "a", count: 64))), document: document)
    }

    private func descent(_ points: [TrackPoint]) -> Descent {
        Descent(source: .gpx, startedAt: points[0].timestamp ?? origin,
                endedAt: points[points.count - 1].timestamp ?? origin, points: points)
    }

    @Test func matchReportsEachEdgeWithTimesAndPace() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let bundle = try bundle([upper, lower])
        let match = TrailMatcher.match(descent: descent(twoPacePoints), in: bundle)

        #expect(match.bundleID == bundle.id)
        #expect(match.matcherVersion == MatcherVersion)
        #expect(match.failure == nil)
        #expect(match.matched.map(\.edgeID) == ["upper", "lower"])
        #expect(match.primaryEdgeID == "lower" || match.primaryEdgeID == "upper")
        #expect(match.coverage == 1)
        #expect((0.75...1).contains(match.confidence))

        let first = try #require(match.matched.first)
        let second = try #require(match.matched.last)
        #expect(first.enterAt == origin)
        #expect(first.exitAt == origin.addingTimeInterval(20))
        #expect(second.enterAt == first.exitAt)
        #expect(second.exitAt == origin.addingTimeInterval(35))
        #expect(abs(first.movingS - 15) < 0.001)
        #expect(abs(first.stoppedS - 5) < 0.001)

        let keys = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any]
        ).keys
        #expect(Set(keys) == ["edge_id", "enter_at", "exit_at", "moving_s", "stopped_s", "length_m", "peak_speed_ms"])
    }

    @Test func sectionsNameEachTrailInOrderWithAnOffMapStretchBetween() throws {
        // Two edges of one trail, then 40 s well away from the map, then another trail.
        let groupID = GroupID("ridge")
        let ridgeUpper = run("ridge-1", "top", "mid", [(0.010, -106), (0.007, -106)], group: groupID)
        let ridgeLower = run("ridge-2", "mid", "low", [(0.007, -106), (0.005, -106)], group: groupID)
        let gully = run("gully", "g-top", "g-bottom", [(0.003, -106), (0, -106)], name: "Gully")
        let groups = [MountainCore.Group(id: groupID, kind: .trail, name: "Ridge", edgeIDs: [ridgeUpper.id, ridgeLower.id])]
        let bundle = try bundle([ridgeUpper, ridgeLower, gully], groups: groups)
        var points: [TrackPoint] = []
        var second = 0.0
        func add(_ lat: Double, _ lon: Double) {
            points.append(TrackPoint(lat: lat, lon: lon, elevationM: lat * 10_000, timestamp: origin.addingTimeInterval(second)))
            second += 4
        }
        for lat in stride(from: 0.0098, through: 0.0052, by: -0.0004) { add(lat, -106) }
        for lat in stride(from: 0.0048, through: 0.0034, by: -0.0002) { add(lat, -106.003) }
        for lat in stride(from: 0.0028, through: 0.0004, by: -0.0004) { add(lat, -106) }

        let match = TrailMatcher.match(descent: descent(points), in: bundle)
        #expect(match.isMatched)
        #expect(match.sections.map(\.kind) == [.run, .offMap, .run])
        #expect(match.sections.map(\.name) == ["Ridge", nil, "Gully"])
        #expect(match.sections[0].edgeIDs == ["ridge-1", "ridge-2"])
        #expect(match.sections.first?.enterAt == points.first?.timestamp)
        #expect(match.sections.last?.exitAt == points.last?.timestamp)
        for (a, b) in zip(match.sections, match.sections.dropFirst()) { #expect(a.exitAt == b.enterAt) }
        #expect(match.primaryEdgeID != nil)
    }

    @Test func unmatchedDescentCarriesItsReasonAndNoEdges() throws {
        let bundle = try bundle([edge(id: "run", source: "top", target: "bottom", from: 0.01, to: 0)])
        let points = [timedPoint(0.02, second: 0), timedPoint(0.018, second: 10), timedPoint(0.016, second: 20)]
        let match = TrailMatcher.match(descent: descent(points), in: bundle)
        #expect(!match.isMatched)
        #expect(match.confidence == 0)
        #expect(match.failure == .insufficientCoverage(matched: 0, sampled: 3))
        #expect(match.sections.map(\.kind) == [.offMap])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
