//
//  HaversineTests.swift
//  PowderMeetTests
//
//  `haversine(from:to:)` is the distance primitive used by trail length
//  computation, friend-position coarse fingerprinting, and the
//  bounding-box diagonal helper. Pinning the math here means a unit
//  swap (km/m) or a sign error in the formula gets caught before it
//  silently corrupts every length on the map.
//

import XCTest
@testable import PowderMeet

final class HaversineTests: XCTestCase {

    func testZeroDistance() {
        let a = Coordinate(lat: 39.6, lon: -106.36)
        XCTAssertEqual(haversine(from: a, to: a), 0, accuracy: 1e-6)
    }

    func testSymmetric() {
        let a = Coordinate(lat: 39.6, lon: -106.36)
        let b = Coordinate(lat: 39.7, lon: -106.30)
        let ab = haversine(from: a, to: b)
        let ba = haversine(from: b, to: a)
        XCTAssertEqual(ab, ba, accuracy: 1e-6)
    }

    func testKnownPairOrderOfMagnitude() {
        // Vail Village to Beaver Creek base is ~13km as the crow flies.
        let vail = Coordinate(lat: 39.6403, lon: -106.3742)
        let bc = Coordinate(lat: 39.6042, lon: -106.5165)
        let d = haversine(from: vail, to: bc)
        XCTAssertGreaterThan(d, 10_000)
        XCTAssertLessThan(d, 16_000)
    }

    func testOneMeterStepResolves() {
        // ~1m of latitude north should produce ~1m haversine distance.
        // 1 deg lat ≈ 111_320 m, so 1m ≈ 1/111_320 deg.
        let a = Coordinate(lat: 0, lon: 0)
        let b = Coordinate(lat: 1.0 / 111_320.0, lon: 0)
        XCTAssertEqual(haversine(from: a, to: b), 1.0, accuracy: 0.05)
    }
}
