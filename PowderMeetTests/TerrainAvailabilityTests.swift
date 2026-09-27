import XCTest
import CoreLocation
@testable import PowderMeet

final class TerrainAvailabilityTests: XCTestCase {
    func testGroupedTerrainAvailabilityNeverHidesPartialClosure() {
        let open = edge("open", isOpen: true)
        let closed = edge("closed", isOpen: false)

        XCTAssertEqual(TerrainAvailability(edges: [open]), .open)
        XCTAssertEqual(TerrainAvailability(edges: [closed]), .closed)
        XCTAssertEqual(
            TerrainAvailability(edges: [open, closed, open]),
            .partiallyOpen(open: 2, total: 3)
        )
        XCTAssertEqual(
            TerrainAvailability(edges: [open, closed, open]).label,
            "PARTIAL · 2/3"
        )
    }

    private func edge(_ id: String, isOpen: Bool) -> GraphEdge {
        let a = CLLocationCoordinate2D(latitude: 40, longitude: -106)
        let b = CLLocationCoordinate2D(latitude: 39.99, longitude: -106)
        return GraphEdge(
            id: id,
            sourceID: "a",
            targetID: "b",
            kind: .run,
            geometry: [a, b],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 100,
                trailName: "Trail",
                isOpen: isOpen,
                isOfficiallyValidated: true
            )
        )
    }
}
