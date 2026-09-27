import CoreLocation
import XCTest
import UIKit
@testable import PowderMeet

final class ManeuverIconResolverTests: XCTestCase {
    @MainActor
    func testPausedGuidanceDoesNotFrameAnUnverifiedRoute() {
        let run = edge("run", from: (40.01, -106), to: (40, -106), group: "run")
        let graph = MountainGraph(resortID: "test", nodes: [:], edges: [run])
        let camera = RecordingCamera()
        let director = NavigationDirector(
            tracker: RouteProgressTracker(path: [run], graph: graph), graph: graph, camera: camera
        )
        let location = CLLocationCoordinate2D(latitude: 40.005, longitude: -106.002)
        director.handle(.deviated(currentNodeId: run.sourceID), currentLocation: location, allowRouteFraming: false)
        XCTAssertEqual(camera.frameCount, 0)
        XCTAssertTrue(director.flashAmber, "The warning remains visible even when route framing is suppressed")
        director.handle(.deviated(currentNodeId: run.sourceID), currentLocation: location, allowRouteFraming: true)
        XCTAssertEqual(camera.frameCount, 1)
    }

    @MainActor
    private final class RecordingCamera: CameraController {
        var frameCount = 0
        func frame(coordinates: [CLLocationCoordinate2D], padding: UIEdgeInsets,
                   duration: TimeInterval, bearing: CLLocationDirection?) {
            frameCount += 1
        }
    }

    func testTransitionDirectionFollowsGeometry() {
        let south = edge("south", from: (40.01, -106), to: (40, -106), group: "a")
        let east = edge("east", from: (40, -106), to: (40, -105.99), group: "b")
        let west = edge("west", from: (40, -106), to: (40, -106.01), group: "c")
        let continueSouth = edge("straight", from: (40, -106), to: (39.99, -106), group: "d")

        XCTAssertEqual(ManeuverIconResolver.turnDirection(from: south, to: east), .left)
        XCTAssertEqual(ManeuverIconResolver.turnDirection(from: south, to: west), .right)
        XCTAssertEqual(ManeuverIconResolver.turnDirection(from: south, to: continueSouth), .straight)
        XCTAssertEqual(ManeuverIconResolver.symbolName(for: south, next: east), "arrow.turn.down.left")
        XCTAssertEqual(ManeuverIconResolver.symbolName(for: south, next: west), "arrow.turn.down.right")
    }

    func testSameTrailContinuesDownWithoutFalseTurn() {
        let first = edge("first", from: (40.01, -106), to: (40, -106), group: "same")
        let second = edge("second", from: (40, -106), to: (40, -105.99), group: "same")
        XCTAssertEqual(ManeuverIconResolver.symbolName(for: first, next: second), "arrow.down")
        XCTAssertEqual(ManeuverIconResolver.verb(for: first), "SKI")
    }

    func testTraverseUsesSkiSpecificLanguageAndSymbol() {
        let traverse = GraphEdge(
            id: "connector",
            sourceID: "a",
            targetID: "b",
            kind: .traverse,
            geometry: [],
            attributes: EdgeAttributes(lengthMeters: 100, isOpen: true)
        )
        let profile = UserProfile.defaultProfile(id: UUID())
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [:],
            edges: [traverse]
        )
        let instruction = RouteInstructionBuilder.build(
            from: [traverse],
            profile: profile,
            context: context,
            naming: MountainNaming(graph)
        ).first

        XCTAssertEqual(
            ManeuverIconResolver.symbolName(for: traverse, next: nil),
            "figure.skiing.crosscountry"
        )
        XCTAssertEqual(ManeuverIconResolver.verb(for: traverse), "TRAVERSE")
        XCTAssertTrue(instruction?.displayText.hasPrefix("Traverse ") == true)
    }

    private func edge(
        _ id: String,
        from: (Double, Double),
        to: (Double, Double),
        group: String
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: "\(id)-a",
            targetID: "\(id)-b",
            kind: .run,
            geometry: [
                .init(latitude: from.0, longitude: from.1),
                .init(latitude: to.0, longitude: to.1)
            ],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 100,
                trailName: id,
                isOpen: true,
                isOfficiallyValidated: true,
                trailGroupId: group
            )
        )
    }
}
