//
//  GPXParserTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class GPXParserTests: XCTestCase {
    func testPrefixedGPXParsesTrackNamePointsAndExtensionSpeed() throws {
        let xml = """
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/1"
               xmlns:vendor="http://example.com/vendor">
          <g:trk>
            <g:name>Vail Day</g:name>
            <g:trkseg>
              <g:trkpt lat="39.6400" lon="-106.3740">
                <g:ele>3000</g:ele>
                <g:time>2026-01-02T15:00:00Z</g:time>
                <g:extensions><vendor:speed>8.5</vendor:speed></g:extensions>
              </g:trkpt>
              <g:trkpt lat="39.6395" lon="-106.3740">
                <g:ele>2990</g:ele>
                <g:time>2026-01-02T15:00:10Z</g:time>
              </g:trkpt>
            </g:trkseg>
          </g:trk>
        </g:gpx>
        """
        let data = try XCTUnwrap(xml.data(using: .utf8))

        let activity = GPXParser.parseUnified(
            data: data,
            sourceFileHash: "prefixed"
        )

        XCTAssertEqual(activity.resortName, "Vail Day")
        XCTAssertEqual(activity.segments.count, 1)
        let segment = try XCTUnwrap(activity.segments.first)
        XCTAssertEqual(segment.points.count, 2)
        XCTAssertEqual(segment.points.first?.speed, 8.5)
        XCTAssertEqual(segment.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(segment.boundary, .providerHint)
        try ActivityImportTrailMatchAssertions.assertResolvesConcreteTrail(
            segment.points
        )
    }

    func testContentDetectionAcceptsPrefixedGPXAndTCXWithoutExtensions() throws {
        let unknownURL = URL(fileURLWithPath: "/tmp/activity")
        let gpx = try XCTUnwrap(
            "<ns:gpx xmlns:ns=\"urn:gpx\"><ns:trk></ns:trk></ns:gpx>"
                .data(using: .utf8)
        )
        let tcx = try XCTUnwrap(
            "<ns:TrainingCenterDatabase xmlns:ns=\"urn:tcx\"></ns:TrainingCenterDatabase>"
                .data(using: .utf8)
        )

        XCTAssertEqual(ActivityFileFormat.detect(url: unknownURL, data: gpx), .gpx)
        XCTAssertEqual(ActivityFileFormat.detect(url: unknownURL, data: tcx), .tcx)
    }

    func testMalformedSuffixRejectsAlreadyParsedTrack() throws {
        let xml = """
        <gpx>
          <trk>
            <name>Partial Run</name>
            <trkseg>
              <trkpt lat="39" lon="-106">
                <ele>3000</ele>
                <time>2026-01-02T15:00:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
          <broken>
        """
        let data = try XCTUnwrap(xml.data(using: .utf8))

        let activity = GPXParser.parseUnified(
            data: data,
            sourceFileHash: "malformed"
        )

        XCTAssertTrue(activity.segments.isEmpty)
        XCTAssertTrue(GPXParser.parse(data: data).isEmpty)
    }
}
