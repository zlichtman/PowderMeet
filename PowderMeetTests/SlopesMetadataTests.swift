//
//  SlopesMetadataTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class SlopesMetadataTests: XCTestCase {
    func testPrefixedMetadataPreservesSIStatsAndTimezone() throws {
        let xml = """
        <s:Activity xmlns:s="urn:slopes" runCount="1"
          locationName="Vail"
          start="2026-01-10 11:00:00 -0600"
          end="2026-01-10 12:00:00 -0600"
          duration="3600" distance="4000" vertical="600" topSpeed="15">
          <s:actions>
            <s:Action type="Lift" numberOfType="1"
              start="2026-01-10 11:00:00 -0600"
              end="2026-01-10 11:10:00 -0600"
              duration="600"/>
            <s:Action type="Run" numberOfType="1"
              start="2026-01-10 11:10:00 -0600"
              end="2026-01-10 11:15:00 -0600"
              duration="300" topSpeed="14" avgSpeed="8"
              distance="1200" vertical="300"/>
          </s:actions>
        </s:Activity>
        """

        let metadata = try unwrap(
            SlopesMetadataParser.parse(data: Data(xml.utf8))
        )
        let run = try XCTUnwrap(metadata.runs.first)
        let expectedStart = try XCTUnwrap(
            ISO8601Parser.parse("2026-01-10T17:10:00Z")
        )

        XCTAssertEqual(metadata.header.locationName, "Vail")
        XCTAssertEqual(metadata.actions.count, 2)
        XCTAssertEqual(metadata.runs.count, 1)
        XCTAssertEqual(run.start, expectedStart)
        XCTAssertEqual(run.durationSeconds, 300)
        XCTAssertEqual(run.topSpeedMS, 14)
        XCTAssertEqual(run.avgSpeedMS, 8)
        XCTAssertEqual(run.distanceMeters, 1200)
        XCTAssertEqual(run.verticalMeters, 300)
    }

    func testDeclaredRunCountMismatchFailsClosed() {
        let xml = """
        <Activity runCount="2">
          <actions>
            <Action type="Run" numberOfType="1"
              start="2026-01-10 11:10:00 -0600"
              end="2026-01-10 11:15:00 -0600"/>
          </actions>
        </Activity>
        """

        if case .success = SlopesMetadataParser.parse(data: Data(xml.utf8)) {
            XCTFail("Mismatched run count must not produce partial metadata")
        }
    }

    func testInvalidActionBoundaryFailsClosed() {
        let xml = """
        <Activity runCount="1">
          <actions>
            <Action type="Run" numberOfType="1"
              start="2026-01-10 11:10:00 -0600"/>
          </actions>
        </Activity>
        """

        if case .success = SlopesMetadataParser.parse(data: Data(xml.utf8)) {
            XCTFail("An invalid action must reject authoritative segmentation")
        }
    }

    private func unwrap(
        _ result: Result<SlopesMetadata, SlopesMetadataError>
    ) throws -> SlopesMetadata {
        switch result {
        case .success(let metadata):
            return metadata
        case .failure(let error):
            throw error
        }
    }
}
