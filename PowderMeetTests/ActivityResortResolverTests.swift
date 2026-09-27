//
//  ActivityResortResolverTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class ActivityResortResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func resort(
        id: String,
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double
    ) -> ResortEntry {
        ResortEntry(
            id: id,
            name: id,
            bounds: BoundingBox(
                minLat: minLat,
                maxLat: maxLat,
                minLon: minLon,
                maxLon: maxLon
            ),
            region: "test",
            country: "test"
        )
    }

    private func point(_ lat: Double, _ lon: Double) -> GPXTrackPoint {
        GPXTrackPoint(latitude: lat, longitude: lon, timestamp: now)
    }

    private func segment(_ points: [GPXTrackPoint], number: Int) -> ParsedRunSegment {
        ParsedRunSegment(
            runNumber: number,
            startTime: now.addingTimeInterval(Double(number * 100)),
            endTime: now.addingTimeInterval(Double(number * 100 + 60)),
            durationSeconds: 60,
            topSpeedMS: 12,
            avgSpeedMS: 8,
            distanceMeters: 480,
            verticalMeters: 100,
            points: points
        )
    }

    func testMajorityOfRunFixesDeterminesResortInsteadOfFirstFix() {
        let alpha = resort(id: "alpha", minLat: 0, maxLat: 1, minLon: 0, maxLon: 1)
        let beta = resort(id: "beta", minLat: 10, maxLat: 11, minLon: 10, maxLon: 11)
        let points = [
            point(0.5, 0.5),
            point(10.2, 10.2),
            point(10.4, 10.4),
            point(10.6, 10.6)
        ]

        XCTAssertEqual(
            ActivityResortResolver.identifyResort(for: points, catalog: [alpha, beta])?.id,
            "beta"
        )
    }

    func testOverlappingBoundsResolutionDoesNotDependOnCatalogOrder() {
        let broad = resort(id: "broad", minLat: 0, maxLat: 2, minLon: 0, maxLon: 2)
        let precise = resort(id: "precise", minLat: 0.8, maxLat: 1.2, minLon: 0.8, maxLon: 1.2)
        let points = [point(0.95, 0.95), point(1.05, 1.05)]

        let forward = ActivityResortResolver.identifyResort(
            for: points,
            catalog: [broad, precise]
        )
        let reverse = ActivityResortResolver.identifyResort(
            for: points,
            catalog: [precise, broad]
        )

        XCTAssertEqual(forward?.id, "precise")
        XCTAssertEqual(reverse?.id, "precise")
    }

    func testOneContainerIsSplitIntoStablePerResortGroups() {
        let alpha = resort(id: "alpha", minLat: 0, maxLat: 1, minLon: 0, maxLon: 1)
        let beta = resort(id: "beta", minLat: 10, maxLat: 11, minLon: 10, maxLon: 11)
        let groups = ActivityResortResolver.group(
            [
                segment([point(10.2, 10.2), point(10.3, 10.3)], number: 1),
                segment([point(0.2, 0.2), point(0.3, 0.3)], number: 2),
                segment([], number: 3)
            ],
            fallbackResortId: "reported-name",
            catalog: [beta, alpha]
        )

        XCTAssertEqual(groups.map(\.resortId), ["alpha", "beta", "reported-name"])
        XCTAssertEqual(groups.map { $0.segments.count }, [1, 1, 1])
        XCTAssertNil(groups.last?.catalogEntry)
    }

    func testReportedCanonicalNameRecoversCatalogIdentityWithoutGPS() {
        let vail = ResortEntry(
            id: "vail",
            name: "Vail",
            bounds: BoundingBox(minLat: 0, maxLat: 1, minLon: 0, maxLon: 1),
            region: "CO",
            country: "USA",
            aliases: ["Vail Mountain"]
        )

        XCTAssertEqual(
            ActivityResortResolver.identifyResort(
                named: "  VAIL mountain! ",
                catalog: [vail]
            )?.id,
            "vail"
        )
    }
}
