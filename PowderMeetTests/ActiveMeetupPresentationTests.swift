import SwiftUI
import XCTest
@testable import PowderMeet

/// Render smoke tests with retained attachments for human visual review.
/// Size assertions are not a substitute for reviewing truncation in images.
@MainActor
final class ActiveMeetupPresentationTests: XCTestCase {
    func testMeetupPresentationAtStandardTextSize() throws {
        try renderScenarios(size: .large, label: "standard")
    }

    func testMeetupPresentationAtAccessibilityTextSize() throws {
        try renderScenarios(size: .accessibility3, label: "accessibility")
    }

    func testUnconfirmedArrivalAtStandardTextSize() throws {
        try renderScenarios(size: .large, label: "unconfirmed-standard", remoteArrivalAccuracy: 150)
    }

    func testUnconfirmedArrivalAtAccessibilityTextSize() throws {
        try renderScenarios(size: .accessibility3, label: "unconfirmed-accessibility", remoteArrivalAccuracy: 150)
    }

    private func renderScenarios(size: DynamicTypeSize, label: String, remoteArrivalAccuracy: Double? = nil) throws {
        let start = GraphNode(id: "start", coordinate: .init(latitude: 50.1, longitude: -122.9), elevation: 2_000, kind: .junction)
        let end = GraphNode(id: "meet", coordinate: .init(latitude: 50.09, longitude: -122.9), elevation: 1_500, kind: .midStation)
        let edge = GraphEdge(
            id: "run", sourceID: start.id, targetID: end.id, kind: .run,
            geometry: [start.coordinate, end.coordinate],
            attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 1_000,
                trailName: "Lower Olympic Connector", isGroomed: true, isOpen: true)
        )
        let graph = MountainGraph(resortID: "test", nodes: [start.id: start, end.id: end], edges: [edge])
        var friend = UserProfile.defaultProfile(id: UUID())
        friend.displayName = "Alexandria"
        let me = UserProfile.defaultProfile(id: UUID())
        let result = MeetingResult(
            meetingNode: end, pathA: [edge], pathB: [edge], timeA: 240, timeB: remoteArrivalAccuracy == nil ? 310 : 0,
            alternates: [], meetingDisplayName: "Whistler Village Gondola · Mid-Station"
        )
        let friendLocation = remoteArrivalAccuracy.map { accuracy in
            RealtimeLocationService.FriendLocation(userId: friend.id, displayName: friend.displayName,
                resortId: "test", latitude: end.coordinate.latitude, longitude: end.coordinate.longitude,
                capturedAt: .now, nearestNodeId: end.id, accuracyMeters: accuracy)
        }
        for (state, stateLabel) in [(ActiveRouteRecoveryState.ready, "ready"), (.recalculating, "recalculating"), (.unavailable, "unavailable")] {
            let tracker = RouteProgressTracker(path: [edge], graph: graph, meetingNodeId: end.id)
            let session = ActiveMeetSession(
                id: UUID(), friendProfile: friend, localRole: .sender, meetingResult: result,
                meetingNodeId: end.id, datasetIdentity: .init(resortID: "test", datasetVersion: "fixture"),
                startedAt: .distantPast, routePlanStartedAt: .distantPast,
                routeRecoveryState: state, routeTracker: tracker
            )
            let view = VStack(spacing: 24) {
                CompactRouteSummary(
                    session: session, graph: graph,
                    navigationVM: NavigationViewModel(tracker: tracker, profile: me, graph: graph),
                    friendSignalQuality: friendLocation == nil ? nil : .live,
                    friendLocation: friendLocation,
                    onEnd: {}
                )
                ActiveMeetupCardView(session: session, graph: graph,
                    friendSignalQuality: friendLocation == nil ? nil : .live, friendLocation: friendLocation,
                    onViewOnMap: {}, onEndMeetup: {})
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 16)
            .frame(width: 370)
            .background(HUDTheme.mapBackground)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 100)
            XCTAssertLessThan(image.size.height, 1_400)
            let attachment = XCTAttachment(image: image)
            attachment.name = "meetup-\(label)-\(stateLabel)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
