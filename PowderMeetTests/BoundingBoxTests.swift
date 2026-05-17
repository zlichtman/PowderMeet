//
//  BoundingBoxTests.swift
//  PowderMeetTests
//
//  Covers `BoundingBox.contains` (which `TrailMatcher.identifyResort`
//  calls from a nonisolated context — the recent Swift 6 isolation
//  warning that motivated marking the method `nonisolated`), plus
//  derived helpers (center, overpassBBox, diagonalMeters).
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class BoundingBoxTests: XCTestCase {

    private let vail = BoundingBox(minLat: 39.59, maxLat: 39.66, minLon: -106.43, maxLon: -106.30)

    func testContainsHitInside() {
        XCTAssertTrue(vail.contains(.init(latitude: 39.62, longitude: -106.36)))
    }

    func testContainsMissOutsideLat() {
        XCTAssertFalse(vail.contains(.init(latitude: 38.0, longitude: -106.36)))
    }

    func testContainsMissOutsideLon() {
        XCTAssertFalse(vail.contains(.init(latitude: 39.62, longitude: -100.0)))
    }

    func testContainsBoundaryInclusive() {
        // Equality on each axis should land inside — `>=` / `<=` semantics.
        XCTAssertTrue(vail.contains(.init(latitude: vail.minLat, longitude: vail.minLon)))
        XCTAssertTrue(vail.contains(.init(latitude: vail.maxLat, longitude: vail.maxLon)))
    }

    func testCenterIsAxisMidpoint() {
        let c = vail.center
        XCTAssertEqual(c.lat, (vail.minLat + vail.maxLat) / 2, accuracy: 1e-9)
        XCTAssertEqual(c.lon, (vail.minLon + vail.maxLon) / 2, accuracy: 1e-9)
    }

    func testOverpassBBoxFormat() {
        // Overpass QL bbox order is south,west,north,east — not the
        // GeoJSON-style west,south,east,north. Asserting the literal
        // catches an axis swap that would silently return the wrong
        // resort.
        XCTAssertEqual(vail.overpassBBox, "39.59,-106.43,39.66,-106.3")
    }

    func testDiagonalMetersIsPositiveAndOrderOfMagnitude() {
        // Vail's bounding box is roughly 8km tall x 11km wide ~> ~13km diagonal.
        let d = vail.diagonalMeters
        XCTAssertGreaterThan(d, 5_000)
        XCTAssertLessThan(d, 30_000)
    }

    func testCatalogResortsHaveValidBounds() {
        // Every catalog entry should have a non-degenerate bounding box.
        // A swap (min > max) would silently make `contains` always-false
        // and break GPS auto-detect resort.
        for entry in ResortEntry.catalog {
            XCTAssertLessThan(entry.bounds.minLat, entry.bounds.maxLat,
                              "bad lat range for \(entry.id)")
            XCTAssertLessThan(entry.bounds.minLon, entry.bounds.maxLon,
                              "bad lon range for \(entry.id)")
        }
    }
}
