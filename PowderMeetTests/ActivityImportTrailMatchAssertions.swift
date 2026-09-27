//
//  ActivityImportTrailMatchAssertions.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

/// Shared contract for every ski-file parser: parsing must preserve ordered
/// downhill geometry all the way into the same canonical trail matcher.
enum ActivityImportTrailMatchAssertions {
    static func assertResolvesConcreteTrail(
        _ points: [GPXTrackPoint],
        expectedName: String = "Parser Test Trail",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let first = try XCTUnwrap(points.first, file: file, line: line)
        let last = try XCTUnwrap(points.last, file: file, line: line)
        let top = GraphNode(
            id: "parser-test-top",
            coordinate: .init(latitude: first.latitude, longitude: first.longitude),
            elevation: first.elevation ?? 2_000,
            kind: .trailHead
        )
        let bottom = GraphNode(
            id: "parser-test-bottom",
            coordinate: .init(latitude: last.latitude, longitude: last.longitude),
            elevation: last.elevation ?? 1_900,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "parser-test-edge",
            sourceID: top.id,
            targetID: bottom.id,
            kind: .run,
            geometry: points.map {
                .init(latitude: $0.latitude, longitude: $0.longitude)
            },
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 100,
                verticalDrop: max(1, top.elevation - bottom.elevation),
                trailName: expectedName,
                isOpen: true,
                trailGroupId: "parser-test-trail"
            )
        )
        let graph = MountainGraph(
            resortID: "parser-test-resort",
            nodes: [top.id: top, bottom.id: bottom],
            edges: [edge]
        )
        let match = try XCTUnwrap(
            TrailMatcher(graph: graph).matchRunTopology(
                SegmentedRun(points: points, isLift: false)
            ),
            "The parser lost geometry needed for trail reconstruction",
            file: file,
            line: line
        )
        XCTAssertEqual(match.primaryEdge.id, edge.id, file: file, line: line)
        XCTAssertEqual(
            ImportedRunNameQuality.evidenceBackedTrailName(
                for: match.primaryEdge,
                naming: MountainNaming(graph)
            ),
            expectedName,
            file: file,
            line: line
        )
    }
}
