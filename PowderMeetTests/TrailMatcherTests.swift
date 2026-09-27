//
//  TrailMatcherTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class TrailMatcherTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ latitude: Double) -> GPXTrackPoint {
        GPXTrackPoint(latitude: latitude, longitude: -106, elevation: latitude * 10_000)
    }

    private func timedPoint(_ latitude: Double, second: TimeInterval) -> GPXTrackPoint {
        GPXTrackPoint(
            latitude: latitude,
            longitude: -106,
            elevation: latitude * 10_000,
            timestamp: origin.addingTimeInterval(second)
        )
    }

    private func edge(
        id: String,
        source: String,
        target: String,
        from: Double,
        to: Double
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source,
            targetID: target,
            kind: .run,
            geometry: [
                CLLocationCoordinate2D(latitude: from, longitude: -106),
                CLLocationCoordinate2D(latitude: to, longitude: -106)
            ],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: abs(from - to) * 111_132,
                isOpen: true
            )
        )
    }

    private func graph(edges: [GraphEdge]) -> MountainGraph {
        let nodeIDs = Set(edges.flatMap { [$0.sourceID, $0.targetID] })
        let nodes = Dictionary(uniqueKeysWithValues: nodeIDs.map {
            ($0, GraphNode(
                id: $0,
                coordinate: .init(latitude: 0, longitude: -106),
                elevation: 0,
                kind: .junction
            ))
        })
        return MountainGraph(resortID: "test", nodes: nodes, edges: edges)
    }

    func testOptInEvidencePreservesOutcomeAndTracksSkippedSamples() throws {
        let trail = edge(id: "run", source: "top", target: "bottom", from: 0.01, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let run = SegmentedRun(points: [point(0.02), point(0.009), point(0.008),
                                        point(0.007), point(0.006)], isLift: false)
        var samples: [TrailMatchSampleEvidence] = []
        let traced = try matcher.evaluateRunTopology(run, recordSample: { samples.append($0) }).get()
        let plain = try XCTUnwrap(matcher.matchRunTopology(run))
        XCTAssertEqual(traced.segmentIDs, plain.segmentIDs)
        XCTAssertEqual(traced.confidence, plain.confidence)
        XCTAssertEqual(samples.count, run.points.count)
        XCTAssertNil(samples[0].candidateFrameIndex)
        XCTAssertTrue(samples[0].candidates.isEmpty)
        XCTAssertEqual(samples[1].candidateFrameIndex, 0)
        XCTAssertEqual(samples[1].sampleIndex, 1)
        XCTAssertEqual(samples[1].latitude, run.points[1].latitude)
        let candidate = try XCTUnwrap(samples[1].candidates.first)
        XCTAssertEqual(candidate.edgeID, trail.id)
        XCTAssertLessThan(candidate.distanceMeters, 1)
        XCTAssertGreaterThan(candidate.alongMeters, 100)
        XCTAssertNoThrow(try JSONEncoder().encode(samples))
    }

    func testProjectsOntoPolylineInteriorRatherThanOnlyVertices() throws {
        let longEdge = edge(id: "long", source: "top", target: "bottom", from: 0.01, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [longEdge]))
        let run = SegmentedRun(
            points: [point(0.006), point(0.005), point(0.004)],
            isLift: false
        )

        let result = try XCTUnwrap(matcher.matchRunTopology(run))
        XCTAssertEqual(result.segmentIDs, ["long"])
        XCTAssertLessThan(result.meanDistanceMeters, 1)
        XCTAssertGreaterThan(result.confidence, 0.9)
    }

    func testDenseNearbyTrailsCannotEvictOnlyConnectedContinuation() throws {
        let actual = corridorEdge(id: "actual", x: 0, top: 350, bottom: 0)
        let nearby = (0..<12).map { corridorEdge(id: "decoy-\($0)", x: 20 + Double($0) / 10, top: 100, bottom: 0) }
        let positions: [(Double, Double)] = [(0, 300), (0, 260), (0, 220), (0, 180),
            (5, 140), (10, 100), (15, 80), (20, 60), (20, 40), (20, 20)]
        let points = positions.enumerated().map { corridorPoint(x: $0.element.0, y: $0.element.1, second: Double($0.offset) * 5) }
        for edges in [[actual] + nearby, Array(([actual] + nearby).reversed())] {
            var trace: [TrailMatchSampleEvidence] = []
            let match = try TrailMatcher(graph: graph(edges: edges)).evaluateRunTopology(
                SegmentedRun(points: points, isLift: false), recordSample: { trace.append($0) }).get()
            XCTAssertEqual(match.segmentIDs, [actual.id])
            XCTAssertTrue(trace.contains { $0.candidates.count > 8 })
            XCTAssertEqual(Set(match.edgePaceObservations.map(\.edgeId)), [actual.id])
        }
        XCTAssertNil(TrailMatcher(graph: graph(edges: nearby)).matchRunTopology(
            SegmentedRun(points: points, isLift: false)), "Do not invent a missing approach")
    }

    func testLaterEvidenceCanResolveAnInitiallyNinthRankedTrail() throws {
        let actual = corridorEdge(id: "actual", x: 0, top: 400, bottom: 0)
        let nearby = (0..<12).map { corridorEdge(id: "decoy-\($0)", x: 20 + Double($0) / 10, top: 400, bottom: 150) }
        let points = (0...10).map { i in
            corridorPoint(x: max(0, 20 - Double(i) * 3), y: 300 - Double(i) * 30, second: Double(i) * 5)
        }
        for edges in [[actual] + nearby, Array(([actual] + nearby).reversed())] {
            let result = try TrailMatcher(graph: graph(edges: edges)).evaluateRunTopology(
                SegmentedRun(points: points, isLift: false)).get()
            XCTAssertEqual(result.segmentIDs, [actual.id])
        }
    }

    private func corridorEdge(id: String, x: Double, top: Double, bottom: Double) -> GraphEdge {
        GraphEdge(id: id, sourceID: "\(id)-top", targetID: "\(id)-bottom", kind: .run,
            geometry: [.init(latitude: top / 111132, longitude: -106 + x / 111320),
                       .init(latitude: bottom / 111132, longitude: -106 + x / 111320)],
            attributes: EdgeAttributes(difficulty: .blue, lengthMeters: top - bottom, trailName: id, isOpen: true))
    }

    func testDenseTerminalCandidatesCannotEvictTheRecordedArrivalEdge() throws {
        let actual = corridorEdge(id: "actual", x: 0, top: 350, bottom: 0)
        let nearby = (0..<12).map { corridorEdge(id: "decoy-\($0)", x: 20 + Double($0) / 10, top: 25, bottom: 0) }
        let moving = (0...8).map { i in
            corridorPoint(x: Double(i) * 2.5, y: 300 - Double(i) * 35, second: Double(i) * 5)
        }
        let stopped = (41...50).map { corridorPoint(x: 20, y: 20, second: Double($0)) }
        let matcher = TrailMatcher(graph: graph(edges: nearby + [actual]))
        let baseline = try matcher.evaluateRunTopology(SegmentedRun(points: moving, isLift: false)).get()
        let padded = try matcher.evaluateRunTopology(SegmentedRun(points: moving + stopped, isLift: false)).get()
        XCTAssertEqual(padded.segmentIDs, [actual.id])
        XCTAssertEqual(padded.edgePaceObservations, baseline.edgePaceObservations)
    }

    func testManyEquallyScoredCompleteRoutesRemainDeterministicallyAmbiguous() throws {
        let edges = (0..<64).map { corridorEdge(id: String(format: "trail-%02d", $0), x: 0, top: 350, bottom: 0) }
        let points = (0...10).map { corridorPoint(x: 0, y: 300 - Double($0) * 25, second: Double($0) * 5) }
        for ordering in [edges, Array(edges.reversed()), Array(edges.dropFirst(19)) + Array(edges.prefix(19))] {
            let result = TrailMatcher(graph: graph(edges: ordering)).evaluateRunTopology(
                SegmentedRun(points: points, isLift: false))
            guard case .failure(.ambiguousConnectedRoutes(let best, let alternative)) = result else {
                return XCTFail("A stable tie-break cannot identify the trail or train pace")
            }
            XCTAssertEqual(best, ["trail-00"])
            XCTAssertEqual(alternative, ["trail-01"])
        }
    }

    func testIndistinguishableParallelTrailsCannotSupplyTrustedPace() {
        let edges = [corridorEdge(id: "left", x: -10, top: 350, bottom: 0),
                     corridorEdge(id: "right", x: 10, top: 350, bottom: 0)]
        let points = (0...10).map { corridorPoint(x: 0, y: 300 - Double($0) * 25, second: Double($0) * 5) }
        let matcher = TrailMatcher(graph: graph(edges: edges))
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: points, isLift: false)),
                     "A stable ID is not evidence that one equally fitting trail was skied")
        XCTAssertNotNil(matcher.bestEffortNameMatch(for: SegmentedRun(points: points, isLift: false)),
                        "The import can still carry an explicitly approximate name")
        XCTAssertGreaterThan(matcher.movingSpeed(for: points), 0,
                             "Raw activity metrics remain independent of trail attribution")
    }

    private func corridorPoint(x: Double, y: Double, second: Double) -> GPXTrackPoint {
        GPXTrackPoint(latitude: y / 111132, longitude: -106 + x / 111320,
                      timestamp: origin.addingTimeInterval(second))
    }

    func testRepeatedTerminalFixCannotSwitchOntoAnotherIncomingTrail() throws {
        let incoming = edge(id: "north", source: "north-top", target: "base", from: 0.001, to: 0)
        let other = GraphEdge(id: "west", sourceID: "west-top", targetID: "base", kind: .run,
            geometry: [.init(latitude: 0, longitude: -106.001), .init(latitude: 0, longitude: -106)],
            attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 111, isOpen: true))
        let positions: [(Double, Double)] = [(80, 0), (60, 0), (40, 0), (20, 0), (5, -4), (1, -3)]
        var points = positions.enumerated().map { index, position in
            GPXTrackPoint(latitude: position.0 / 111132, longitude: -106 + position.1 / 111320,
                          timestamp: origin.addingTimeInterval(Double(index) * 2))
        }
        points += (12...20).map { timedPoint(0, second: Double($0)) }
        for edges in [[incoming, other], [other, incoming]] {
            var trace: [TrailMatchSampleEvidence] = []
            let result = try TrailMatcher(graph: graph(edges: edges)).evaluateRunTopology(
                SegmentedRun(points: points, isLift: false), recordSample: { trace.append($0) }).get()
            XCTAssertEqual(result.segmentIDs, [incoming.id])
            XCTAssertTrue(trace.suffix(9).allSatisfy { $0.isTerminalStationary && $0.heading == nil })
            XCTAssertTrue(trace.prefix(6).allSatisfy { !$0.isTerminalStationary })
            XCTAssertEqual(points.count, trace.count, "Keep raw position evidence, including the stop")
        }
    }

    func testTerminalStopDoesNotSupplyMovingCoverageOrAWholeRun() {
        let trail = edge(id: "run", source: "top", target: "base", from: 0.001, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let stopped = (0...20).map { timedPoint(0, second: Double($0)) }
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: stopped, isLift: false)))
        // Most of the actual movement is outside the mapped trail. Repeated
        // on-trail fixes must not manufacture 70% coverage of that movement.
        let approach = (0...5).map { timedPoint(0.006 - Double($0) * 0.001, second: Double($0)) }
        let padded = approach + (6...100).map { timedPoint(0, second: Double($0)) }
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: padded, isLift: false)))
    }

    func testTerminalStopCannotJumpToAnOutgoingEdgeWithoutMovement() {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.005, to: 0.003)
        let lower = edge(id: "lower", source: "mid", target: "base", from: 0.003, to: 0)
        let approach = (0..<8).map { timedPoint(0.0044 - Double($0) * 0.0001, second: Double($0)) }
        let stopped = (8...15).map { timedPoint(0.0001, second: Double($0)) }
        let matcher = TrailMatcher(graph: graph(edges: [upper, lower]))
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: approach + stopped, isLift: false)),
                     "A stationary frame cannot introduce a new edge even at a legal directed junction")
        guard case .failure(.unmatchedTerminalStop(let matched, let sampled)) =
                TrailMatcher(graph: graph(edges: [upper])).evaluateRunTopology(
                    SegmentedRun(points: approach + stopped, isLift: false)) else {
            return XCTFail("An off-map stop must be reported separately from moving coverage")
        }
        XCTAssertEqual(matched, 0)
        XCTAssertEqual(sampled, stopped.count)
    }

    func testTerminalPlateauNeedsACompleteClockNotJustRepeatedCoordinates() {
        let trail = edge(id: "run", source: "top", target: "base", from: 0.001, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let approach = [timedPoint(0.0008, second: 0), timedPoint(0.0004, second: 2)]
        let clocks: [[TimeInterval?]] = [
            [nil, nil, nil], [4, 4, 4], [10, 9, 8], [4, 40, 80], [4, 5, 6]
        ]
        for times in clocks {
            let points = approach + times.map { time in
                GPXTrackPoint(latitude: 0, longitude: -106, timestamp: time.map { origin.addingTimeInterval($0) })
            }
            var trace: [TrailMatchSampleEvidence] = []
            _ = matcher.evaluateRunTopology(SegmentedRun(points: points, isLift: false), recordSample: { trace.append($0) })
            XCTAssertFalse(trace.contains { $0.isTerminalStationary })
        }
    }

    func testSlowSkiingStillNeedsForwardDirection() throws {
        let trail = edge(id: "run", source: "top", target: "base", from: 0.001, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let forward = (0..<30).map { index in
            GPXTrackPoint(latitude: 0.0008 - Double(index) * 0.5 / 111132, longitude: -106,
                          timestamp: origin.addingTimeInterval(Double(index)))
        }
        var trace: [TrailMatchSampleEvidence] = []
        XCTAssertNoThrow(try matcher.evaluateRunTopology(SegmentedRun(points: forward, isLift: false),
            recordSample: { trace.append($0) }).get())
        XCTAssertFalse(trace.contains { $0.isTerminalStationary })
        let reverse = forward.reversed().enumerated().map { index, point in
            GPXTrackPoint(latitude: point.latitude, longitude: point.longitude,
                          timestamp: origin.addingTimeInterval(Double(index)))
        }
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: reverse, isLift: false)))
    }

    func testLongTerminalWaitCannotChangeThePrimaryTrail() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "base", from: 0.005, to: 0)
        let moving = [0.009, 0.008, 0.007, 0.006, 0.0055, 0.004, 0.002].enumerated().map {
            timedPoint($0.element, second: Double($0.offset) * 10)
        }
        let stopped = (0...1000).map { timedPoint(0.001, second: 70 + Double($0)) }
        let match = try XCTUnwrap(TrailMatcher(graph: graph(edges: [upper, lower])).matchRunTopology(
            SegmentedRun(points: moving + stopped, isLift: false)))
        XCTAssertEqual(match.segmentIDs, [upper.id, lower.id])
        XCTAssertEqual(match.primaryEdge.id, upper.id)
    }

    func testTinyTerminalJitterCannotTrainSkiPace() throws {
        let trail = edge(id: "run", source: "top", target: "base", from: 0.01, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let moving = (0...7).map { timedPoint(0.009 - Double($0) * 0.0005, second: Double($0) * 5) }
        let arrival = timedPoint(0.005, second: 40)
        // Six seconds is shorter than the general speed-stat pause window,
        // but these repeated fixes (with centimetre jitter) have no direction.
        let stopped = (1...6).map { index in
            timedPoint(0.005 - Double(index) * 0.02 / 111132, second: 40 + Double(index))
        }
        let baseline = try XCTUnwrap(matcher.matchRunTopology(
            SegmentedRun(points: moving + [arrival], isLift: false)))
        let padded = try XCTUnwrap(matcher.matchRunTopology(
            SegmentedRun(points: moving + [arrival] + stopped, isLift: false)))
        let before = try XCTUnwrap(baseline.edgePaceObservations.first)
        let after = try XCTUnwrap(padded.edgePaceObservations.first)
        XCTAssertEqual(after.durationS, before.durationS, accuracy: 0.000001)
        XCTAssertEqual(after.distanceM, before.distanceM, accuracy: 0.000001)
        XCTAssertEqual(after.speedMs, before.speedMs, accuracy: 0.000001)
    }

    func testOppositeHairpinLegCannotReplaceTheNearestWrongWaySegment() throws {
        // Two legs are within the 60 m corridor, but belong to opposite
        // directions. Southbound on the west leg is NOT the east-leg descent.
        let coordinates = [(0.0, 0.0), (0.001, 0.0), (0.001, 0.00036), (0.0, 0.00036)]
        let hairpin = GraphEdge(id: "hairpin", sourceID: "start", targetID: "finish", kind: .run,
                                geometry: coordinates.map { .init(latitude: $0.0, longitude: $0.1) },
                                attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 263, isOpen: true))
        let matcher = TrailMatcher(graph: graph(edges: [hairpin]))
        func points(longitude: Double) -> [GPXTrackPoint] {
            (0..<7).map { GPXTrackPoint(latitude: 0.0008 - Double($0) * 0.0001,
                                       longitude: longitude, timestamp: origin.addingTimeInterval(Double($0) * 3)) }
        }
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: points(longitude: 0), isLift: false)),
                     "A farther aligned leg must not manufacture a forward match for the nearest wrong-way leg")
        let correct = try XCTUnwrap(matcher.matchRunTopology(
            SegmentedRun(points: points(longitude: 0.00036), isLift: false)))
        XCTAssertEqual(correct.segmentIDs, [hairpin.id])
        XCTAssertGreaterThan(correct.confidence, 0.9)
        XCTAssertFalse(correct.edgePaceObservations.isEmpty)
    }

    func testLocalDirectionFollowsCarvingTrendRatherThanEachSidewaysTurn() throws {
        let trail = edge(id: "carving", source: "top", target: "bottom", from: 0.01, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        for timed in [false, true] {
            let points = (0..<81).map { index in
                GPXTrackPoint(latitude: 0.009 - Double(index) * 3 / 111132,
                              longitude: -106 + 10 * sin(Double(index) * .pi / 4) / 111320,
                              timestamp: timed ? origin.addingTimeInterval(Double(index)) : nil)
            }
            let match = try XCTUnwrap(matcher.matchRunTopology(SegmentedRun(points: points, isLift: false)))
            XCTAssertEqual(match.segmentIDs, [trail.id])
            XCTAssertGreaterThan(match.confidence, 0.8)
            let reversed = Array(points.reversed()).enumerated().map { index, point in
                GPXTrackPoint(latitude: point.latitude, longitude: point.longitude,
                              timestamp: timed ? origin.addingTimeInterval(Double(index)) : nil)
            }
            XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: reversed, isLift: false)),
                         "Smoothing must retain travel direction, including without elevation")
        }
    }

    func testSwitchbackUsesLocalDirectedBearingAcrossSegments() throws {
        let (edges, points) = switchbackFixture()
        for inputEdges in [edges, Array(edges.reversed())] {
            let match = try XCTUnwrap(TrailMatcher(graph: graph(edges: inputEdges))
                .matchRunTopology(SegmentedRun(points: points, isLift: false)))
            XCTAssertEqual(match.segmentIDs, ["outbound", "return"])
            XCTAssertGreaterThan(match.confidence, 0.8)
        }
    }

    func testSwitchbackWorksInsideOnePolylineAndRejectsReverseWithoutElevation() throws {
        let (edges, points) = switchbackFixture()
        let bent = GraphEdge(id: "bent", sourceID: "top", targetID: "bottom", kind: .run,
            geometry: edges[0].geometry + edges[1].geometry.dropFirst(),
            attributes: edges[0].attributes)
        let matcher = TrailMatcher(graph: graph(edges: [bent]))
        XCTAssertEqual(try XCTUnwrap(matcher.matchRunTopology(
            SegmentedRun(points: points, isLift: false))).segmentIDs, ["bent"])
        XCTAssertNil(matcher.matchRunTopology(
            SegmentedRun(points: Array(points.reversed()), isLift: false)))
    }

    private func switchbackFixture() -> ([GraphEdge], [GPXTrackPoint]) {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0.010, longitude: -106),
            CLLocationCoordinate2D(latitude: 0.009, longitude: -105.990),
            CLLocationCoordinate2D(latitude: 0.008, longitude: -106)
        ]
        let edges = (0..<2).map { index in
            GraphEdge(id: index == 0 ? "outbound" : "return",
                sourceID: index == 0 ? "top" : "turn",
                targetID: index == 0 ? "turn" : "bottom", kind: .run,
                geometry: [coordinates[index], coordinates[index + 1]],
                attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 1_100,
                    trailName: "Switchback", isOpen: true))
        }
        let points = (0...20).map { index in
            let segment = min(index / 10, 1)
            let fraction = Double(index - segment * 10) / 10
            let a = coordinates[segment], b = coordinates[segment + 1]
            return GPXTrackPoint(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: a.longitude + (b.longitude - a.longitude) * fraction)
        }
        return (edges, points)
    }

    func testDenseReverseFixesCannotBypassDirectionWithMissingElevation() throws {
        let trail = edge(id: "down", source: "top", target: "bottom", from: 0.001, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let uphill = (0...20).map { index in
            GPXTrackPoint(latitude: Double(index) * 0.00001, longitude: -106)
        }
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: uphill, isLift: false)))
        XCTAssertNotNil(matcher.matchRunTopology(SegmentedRun(points: Array(uphill.reversed()), isLift: false)))
        let stationary = Array(repeating: uphill[10], count: 20)
        XCTAssertNil(matcher.matchRunTopology(SegmentedRun(points: stationary, isLift: false)))
    }

    func testReturnsFullDirectedContiguousSegmentSequence() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [lower, upper]))
        let run = SegmentedRun(
            points: [
                point(0.009), point(0.007), point(0.0055),
                point(0.0045), point(0.003), point(0.001)
            ],
            isLift: false
        )

        let result = try XCTUnwrap(matcher.matchRunTopology(run))
        XCTAssertEqual(result.segmentIDs, ["upper", "lower"])
        XCTAssertGreaterThanOrEqual(result.confidence, 0.75)
    }

    func testAttributesDifferentPaceToEachExactEdge() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [upper, lower]))
        let run = SegmentedRun(
            points: [
                // Three fast, fully upper-edge intervals.
                timedPoint(0.0095, second: 0),
                timedPoint(0.0090, second: 5),
                timedPoint(0.0085, second: 10),
                timedPoint(0.0080, second: 15),
                // The cross-boundary interval is intentionally too fast and
                // must be omitted. Three slower lower-edge intervals remain.
                timedPoint(0.0048, second: 20),
                timedPoint(0.0046, second: 25),
                timedPoint(0.0044, second: 30),
                timedPoint(0.0042, second: 35)
            ],
            isLift: false
        )

        let result = try XCTUnwrap(matcher.matchRunTopology(run))
        XCTAssertEqual(result.segmentIDs, ["upper", "lower"])
        XCTAssertEqual(result.edgePaceObservations.map(\.edgeId), ["upper", "lower"])
        let upperPace = try XCTUnwrap(result.edgePaceObservations.first)
        let lowerPace = try XCTUnwrap(result.edgePaceObservations.last)
        XCTAssertGreaterThan(upperPace.speedMs, lowerPace.speedMs * 2)
        XCTAssertEqual(upperPace.durationS, 15, accuracy: 0.001)
        XCTAssertEqual(lowerPace.durationS, 15, accuracy: 0.001)
        XCTAssertGreaterThan(upperPace.distanceM, lowerPace.distanceM * 2)
    }

    func testSparseMultiEdgeTrackKeepsTopologyWithoutInventingPace() throws {
        let upper = edge(id: "upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [upper, lower]))
        let run = SegmentedRun(
            points: [
                timedPoint(0.008, second: 0),
                timedPoint(0.004, second: 60)
            ],
            isLift: false
        )

        let result = try XCTUnwrap(matcher.matchRunTopology(run))
        XCTAssertEqual(result.segmentIDs, ["upper", "lower"])
        XCTAssertTrue(result.edgePaceObservations.isEmpty)
    }

    func testBackwardMovementCannotInflateLearnedDownhillPace() throws {
        let trail = edge(id: "downhill", source: "top", target: "bottom", from: 0.01, to: 0)
        var points = (0..<12).map { index in
            GPXTrackPoint(latitude: 0.009 - Double(index) * 0.0002,
                longitude: -106, timestamp: origin.addingTimeInterval(Double(index) * 5))
        }
        // The overall descent still matches. Two faster backward intervals
        // at its end must not train the skier's forward downhill pace.
        points.append(GPXTrackPoint(latitude: 0.0074, longitude: -106,
            timestamp: origin.addingTimeInterval(60)))
        points.append(GPXTrackPoint(latitude: 0.0080, longitude: -106,
            timestamp: origin.addingTimeInterval(65)))
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        let match = try XCTUnwrap(matcher.matchRunTopology(SegmentedRun(points: points, isLift: false)))
        let observation = try XCTUnwrap(match.edgePaceObservations.first)
        let forwardPoints = Array(points.prefix(12))
        let expectedSpeed = GPXSpeedStats.movingAverageSpeed(forwardPoints)
        XCTAssertEqual(observation.durationS, 55, accuracy: 0.001)
        XCTAssertEqual(observation.speedMs, expectedSpeed, accuracy: 0.001)
        XCTAssertLessThan(observation.speedMs, GPXSpeedStats.movingAverageSpeed(points))
    }

    func testMovingIntervalsAndAverageSharePausePolicy() {
        let points = [
            timedPoint(0.0090, second: 0),
            timedPoint(0.0085, second: 5),
            timedPoint(0.0085, second: 10),
            timedPoint(0.0085, second: 20),
            timedPoint(0.0080, second: 25)
        ]

        let intervals = GPXSpeedStats.movingIntervals(points)
        let distance = intervals.reduce(0) { $0 + $1.distanceM }
        let duration = intervals.reduce(0) { $0 + $1.durationS }

        XCTAssertEqual(intervals.map(\.startIndex), [0, 3])
        XCTAssertEqual(
            GPXSpeedStats.movingAverageSpeed(points),
            distance / duration,
            accuracy: 0.000_001
        )
    }

    func testBackupV5RoundTripsEdgePaceEvidence() throws {
        let payload = Data(#"""
        {
          "speed_ms": 8,
          "duration_s": 20,
          "vertical_m": 100,
          "distance_m": 160,
          "max_grade_deg": 22,
          "run_at": 0,
          "dedup_hash": "backup-edge-observation",
          "edge_observations": [
            {
              "edge_id": "edge-a",
              "conditions_fp": "default",
              "speed_ms": 8,
              "peak_speed_ms": 10,
              "duration_s": 20,
              "distance_m": 160
            }
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(ImportedRunBackup.self, from: payload)
        let observation = try XCTUnwrap(decoded.edgePaceObservations?.first)
        XCTAssertEqual(observation.edgeId, "edge-a")
        XCTAssertEqual(observation.speedMs, 8)

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        let observations = try XCTUnwrap(object["edge_observations"] as? [[String: Any]])
        XCTAssertEqual(observations.first?["edge_id"] as? String, "edge-a")
    }

    func testRejectsDiscontinuousAttribution() {
        let upper = edge(id: "upper", source: "top", target: "mid-a", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid-b", target: "bottom", from: 0.005, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [upper, lower]))
        let run = SegmentedRun(
            points: [point(0.009), point(0.007), point(0.004), point(0.001)],
            isLift: false
        )

        XCTAssertNil(matcher.matchRunTopology(run))
        guard case .failure(.noConnectedTransition(let frame, let previous, let next)) = matcher.evaluateRunTopology(run) else {
            return XCTFail("Disconnected geometry must report a topology failure")
        }
        XCTAssertEqual(frame, 2)
        XCTAssertEqual(previous, ["upper"])
        XCTAssertEqual(next, ["lower"])
    }

    func testRejectionDiagnosticsDistinguishInputGeometryAndCoverage() {
        let trail = edge(id: "run", source: "top", target: "bottom", from: 0.01, to: 0)
        let matcher = TrailMatcher(graph: graph(edges: [trail]))
        guard case .failure(.invalidDescent) = matcher.evaluateRunTopology(
            SegmentedRun(points: [], isLift: false)) else {
            return XCTFail("Empty input must not be reported as a graph disconnection")
        }
        let farRun = SegmentedRun(points: [point(0.02), point(0.018), point(0.016)], isLift: false)
        guard case .failure(.insufficientCoverage(let matched, let sampled)) = matcher.evaluateRunTopology(farRun) else {
            return XCTFail("A distant track must report insufficient coverage")
        }
        XCTAssertEqual(matched, 0)
        XCTAssertEqual(sampled, 3)
        guard case .failure(.noTrailGeometry) = TrailMatcher(graph: graph(edges: []))
            .evaluateRunTopology(farRun) else {
            return XCTFail("An empty graph must report missing geometry")
        }
    }

    func testConnectedSequenceDisambiguatesAnOverlappingDeadEnd() throws {
        let decoy = edge(id: "a-decoy", source: "other-top", target: "dead-end", from: 0.01, to: 0.005)
        let upper = edge(id: "z-upper", source: "top", target: "mid", from: 0.01, to: 0.005)
        let lower = edge(id: "lower", source: "mid", target: "bottom", from: 0.005, to: 0)
        let points = [point(0.009), point(0.007), point(0.004), point(0.002)]
        for edges in [[decoy, upper, lower], [lower, upper, decoy]] {
            let match = try XCTUnwrap(TrailMatcher(graph: graph(edges: edges))
                .matchRunTopology(SegmentedRun(points: points, isLift: false)))
            XCTAssertEqual(match.segmentIDs, ["z-upper", "lower"])
            XCTAssertFalse(match.segmentIDs.contains("a-decoy"))
        }
    }

    func testRejectsReverseUphillAttributionToDirectedRun() {
        let downhill = edge(
            id: "downhill",
            source: "top",
            target: "bottom",
            from: 0.01,
            to: 0
        )
        let matcher = TrailMatcher(graph: graph(edges: [downhill]))
        let uphillTrack = SegmentedRun(
            points: [
                point(0.001),
                point(0.004),
                point(0.007),
                point(0.009)
            ],
            isLift: false
        )

        XCTAssertNil(matcher.matchRunTopology(uphillTrack))
        XCTAssertNil(matcher.bestEffortNameMatch(for: uphillTrack))
    }

    func testEqualGeometryAmbiguityIsStableAcrossGraphEdgeOrder() throws {
        let a = edge(id: "a", source: "top", target: "bottom", from: 0.01, to: 0)
        let b = edge(id: "b", source: "top", target: "bottom", from: 0.01, to: 0)
        let run = SegmentedRun(
            points: [point(0.009), point(0.007), point(0.004), point(0.001)],
            isLift: false
        )

        for ordering in [[a, b], [b, a]] {
            guard case .failure(.ambiguousConnectedRoutes(let best, let alternative)) =
                TrailMatcher(graph: graph(edges: ordering)).evaluateRunTopology(run) else {
                return XCTFail("Identical geometry cannot identify a unique trail")
            }
            XCTAssertEqual(best, ["a"])
            XCTAssertEqual(alternative, ["b"])
        }
    }
}
