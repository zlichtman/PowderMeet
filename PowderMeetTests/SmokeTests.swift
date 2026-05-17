//
//  SmokeTests.swift
//  PowderMeetTests
//
//  Smallest-possible test that proves the target compiles, links
//  against the host app via @testable import, and runs in the
//  simulator. Real coverage lives in the per-domain test files.
//

import XCTest
@testable import PowderMeet

final class SmokeTests: XCTestCase {
    func testTargetBuildsAndImportsHost() {
        // BoundingBox is one of the smallest concrete types in the
        // host app; if @testable import works, this compiles.
        let bb = BoundingBox(minLat: 39.5, maxLat: 39.7, minLon: -106.5, maxLon: -106.3)
        XCTAssertTrue(bb.minLat < bb.maxLat)
        XCTAssertTrue(bb.minLon < bb.maxLon)
    }
}
