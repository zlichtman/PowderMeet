//
//  LiveRecorderVicinityTests.swift
//  PowderMeetTests
//
//  Covers the resort-vicinity predicate that gates passive live
//  recording, so driving to the mountain with the toggle on can't
//  log garbage "runs" against the selected resort.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class LiveRecorderVicinityTests: XCTestCase {

    // Vail-ish bbox.
    private let vail = BoundingBox(minLat: 39.59, maxLat: 39.66,
                                   minLon: -106.43, maxLon: -106.30)

    func testInsideBboxRecords() {
        XCTAssertTrue(LiveRunRecorder.bbox(
            vail, contains: .init(latitude: 39.62, longitude: -106.36),
            bufferMeters: 1_000))
    }

    func testJustOutsideButWithinBufferRecords() {
        // ~500 m north of the bbox edge — base/parking still counts.
        XCTAssertTrue(LiveRunRecorder.bbox(
            vail, contains: .init(latitude: 39.6645, longitude: -106.36),
            bufferMeters: 1_000))
    }

    func testDrivingFarAwayDoesNotRecord() {
        // ~20 km away (highway to the mountain) — no recording.
        XCTAssertFalse(LiveRunRecorder.bbox(
            vail, contains: .init(latitude: 39.85, longitude: -106.36),
            bufferMeters: 1_000))
    }

    func testHysteresisWiderExitBuffer() {
        // ~1.5 km out: outside the 1 km enter band but inside the
        // 2 km exit band — a run skirting the edge isn't chopped.
        let edge = CLLocationCoordinate2D(latitude: 39.6735, longitude: -106.36)
        XCTAssertFalse(LiveRunRecorder.bbox(vail, contains: edge, bufferMeters: 1_000))
        XCTAssertTrue(LiveRunRecorder.bbox(vail, contains: edge, bufferMeters: 2_000))
    }
}
