//
//  GeohashTests.swift
//  PowderMeetTests
//
//  Geohash encode/decode determinism and basic neighbor-lookup shape.
//  Live position partitioning relies on these primitives — a regression
//  here breaks friend-channel routing silently.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class GeohashTests: XCTestCase {

    func testEncodeKnownPoint() {
        // Ground truth from geohash.org for (47.6062, -122.3321) precision 6
        // → "c23nb6".
        let h = Geohash.encode(latitude: 47.6062, longitude: -122.3321, precision: 6)
        XCTAssertEqual(h, "c23nb6")
    }

    func testEncodeIsDeterministic() {
        // Same lat/lon must always produce the same hash. Rapid-fire
        // GPS broadcasts on the same coord shouldn't churn between
        // adjacent cells.
        let a = Geohash.encode(latitude: 39.6, longitude: -106.36, precision: 6)
        let b = Geohash.encode(latitude: 39.6, longitude: -106.36, precision: 6)
        XCTAssertEqual(a, b)
    }

    func testEncodePrecisionMonotonic() {
        // Higher precision strictly extends lower precision (geohash is
        // a prefix code).
        let p5 = Geohash.encode(latitude: 39.6, longitude: -106.36, precision: 5)
        let p6 = Geohash.encode(latitude: 39.6, longitude: -106.36, precision: 6)
        let p7 = Geohash.encode(latitude: 39.6, longitude: -106.36, precision: 7)
        XCTAssertTrue(p6.hasPrefix(p5))
        XCTAssertTrue(p7.hasPrefix(p6))
    }

    func testDecodeBoundsRoundTripsThroughCell() {
        // The decoded bounding box for an encoded cell must contain
        // the original point.
        let lat = 47.6062, lon = -122.3321
        let h = Geohash.encode(latitude: lat, longitude: lon, precision: 6)
        guard let bounds = Geohash.decodeBounds(h) else {
            return XCTFail("decodeBounds returned nil for \(h)")
        }
        XCTAssertGreaterThanOrEqual(lat, bounds.sw.latitude)
        XCTAssertLessThanOrEqual(lat, bounds.ne.latitude)
        XCTAssertGreaterThanOrEqual(lon, bounds.sw.longitude)
        XCTAssertLessThanOrEqual(lon, bounds.ne.longitude)
    }

    func testDecodeBoundsRejectsInvalidChar() {
        // Standard geohash alphabet excludes a, i, l, o.
        XCTAssertNil(Geohash.decodeBounds("aaaaaa"))
    }
}
