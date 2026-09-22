//
//  TCXParserTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class TCXParserTests: XCTestCase {
    func testPrefixedTCXParsesLapStatsAndExtensionSpeed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tcx:TrainingCenterDatabase xmlns:tcx="urn:garmin:tcx"
            xmlns:ext="urn:garmin:extensions">
          <tcx:Activities>
            <tcx:Activity Sport="Other">
              <tcx:Id>2026-01-02T15:00:00Z</tcx:Id>
              <tcx:Lap StartTime="2026-01-02T15:00:00Z">
                <tcx:TotalTimeSeconds>20</tcx:TotalTimeSeconds>
                <tcx:DistanceMeters>200</tcx:DistanceMeters>
                <tcx:MaximumSpeed>14</tcx:MaximumSpeed>
                <tcx:Track>
                  <tcx:Trackpoint>
                    <tcx:Time>2026-01-02T15:00:00Z</tcx:Time>
                    <tcx:Position>
                      <tcx:LatitudeDegrees>39</tcx:LatitudeDegrees>
                      <tcx:LongitudeDegrees>-106</tcx:LongitudeDegrees>
                    </tcx:Position>
                    <tcx:AltitudeMeters>3000</tcx:AltitudeMeters>
                    <tcx:Extensions><ext:TPX><ext:Speed>8</ext:Speed></ext:TPX></tcx:Extensions>
                  </tcx:Trackpoint>
                  <tcx:Trackpoint>
                    <tcx:Time>2026-01-02T15:00:20Z</tcx:Time>
                    <tcx:Position>
                      <tcx:LatitudeDegrees>38.999</tcx:LatitudeDegrees>
                      <tcx:LongitudeDegrees>-106</tcx:LongitudeDegrees>
                    </tcx:Position>
                    <tcx:AltitudeMeters>2980</tcx:AltitudeMeters>
                    <tcx:Extensions><ext:TPX><ext:Speed>12</ext:Speed></ext:TPX></tcx:Extensions>
                  </tcx:Trackpoint>
                </tcx:Track>
              </tcx:Lap>
            </tcx:Activity>
          </tcx:Activities>
        </tcx:TrainingCenterDatabase>
        """

        let activity = TCXParser.parseUnified(
            data: try XCTUnwrap(xml.data(using: .utf8)),
            sourceFileHash: "fixture"
        )
        let segment = try XCTUnwrap(activity.segments.first)

        XCTAssertEqual(activity.segments.count, 1)
        XCTAssertEqual(segment.durationSeconds, 20)
        XCTAssertEqual(segment.distanceMeters, 200)
        XCTAssertEqual(segment.avgSpeedMS, 10)
        XCTAssertEqual(segment.topSpeedMS, 14)
        XCTAssertEqual(segment.points.count, 2)
        XCTAssertEqual(try XCTUnwrap(segment.points[0].speed), 8)
        XCTAssertEqual(try XCTUnwrap(segment.points[1].speed), 12)
        XCTAssertEqual(segment.boundary, .providerHint)
        try ActivityImportTrailMatchAssertions.assertResolvesConcreteTrail(
            segment.points
        )
    }

    func testMalformedSuffixRejectsAlreadyParsedLap() throws {
        let xml = """
        <TrainingCenterDatabase>
          <Activities>
            <Activity>
              <Lap StartTime="2026-01-02T15:00:00Z">
                <TotalTimeSeconds>20</TotalTimeSeconds>
                <Track>
                  <Trackpoint>
                    <Time>2026-01-02T15:00:00Z</Time>
                    <Position>
                      <LatitudeDegrees>39</LatitudeDegrees>
                      <LongitudeDegrees>-106</LongitudeDegrees>
                    </Position>
                  </Trackpoint>
                </Track>
              </Lap>
              <Broken>
        """

        let activity = TCXParser.parseUnified(
            data: try XCTUnwrap(xml.data(using: .utf8)),
            sourceFileHash: "malformed"
        )

        XCTAssertTrue(activity.segments.isEmpty)
        XCTAssertTrue(
            TCXParser.parse(data: try XCTUnwrap(xml.data(using: .utf8))).isEmpty
        )
    }
}
