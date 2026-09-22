import SwiftUI
import CryptoKit
import XCTest
@testable import PowderMeet

@MainActor
final class CapturedRoutePresentationTests: XCTestCase {
    func testActualAppChromeAndResortRehearsals() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POWDERMEET_ROUTE_AUDIT_DIRECTORY"] else {
            throw XCTSkip("Opt in with local source graphs to render a real route rehearsal")
        }
        let root = URL(fileURLWithPath: directory)
        for resortID in ["whistler", "breckenridge", "niseko"] {
            try await capture(resortID: resortID, root: root)
        }
    }

    private func capture(resortID: String, root: URL) async throws {
        let graphData = try Data(contentsOf: root.appendingPathComponent(resortID + ".json"))
        let graph = try JSONDecoder().decode(MountainGraph.self, from: graphData)
        struct Row: Decodable { let resort_id: String; let starts: [String]? }
        let rows = try JSONDecoder().decode([Row].self,
            from: Data(contentsOf: root.appendingPathComponent("iphone-route-results.json")))
        let starts = try XCTUnwrap(rows.first { $0.resort_id == resortID }?.starts)
        var a = UserProfile.defaultProfile(id: UUID())
        var b = UserProfile.defaultProfile(id: UUID())
        a.applyPreset("expert"); b.applyPreset("expert")
        let solver = MeetingPointSolver(graph: graph)
        var result = try XCTUnwrap(solver.solve(skierA: a, positionA: starts[0], skierB: b, positionB: starts[1]))
        result.solveAttempt = .nonCanonicalDataset
        let entry = try XCTUnwrap(ResortEntry.catalog.first { $0.id == resortID })
        let manager = ResortDataManager()
        manager.currentEntry = entry
        manager.currentGraph = graph
        manager.currentSnapshotStats = graph.makeResortStats(resortId: entry.id, snapshotDate: "")
        manager.currentDataset = MountainDataset(resortID: entry.id,
            version: .init(manifestVersion: nil, graphVersion: MountainRepository.expectedLegacyVersion,
                contentSHA256: SHA256.hash(data: graphData).map { String(format: "%02x", $0) }.joined()),
            snapshotDate: nil, source: .legacySnapshot, graph: graph)
        let coordinator = ContentCoordinator()
        coordinator.selectedEntry = entry
        coordinator.meetingResult = result
        coordinator.routeAnimationTrigger = 1
        let view = ContentView(coordinator: coordinator, startsServices: false)
            .environment(manager).environment(SupabaseManager.shared)
            .environment(ActivityImportSession()).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        for _ in 0..<100 {
            if coordinator.mapBridge.cinemaDirector != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertNotNil(coordinator.mapBridge.cinemaDirector, "Map style must actually load")
        try await Task.sleep(for: .seconds(3))
        let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(rendered.pngData())
        try png.write(to: root.appendingPathComponent(resortID + "-app-rehearsal.png"))
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Actual branded app - \(entry.name) source route rehearsal"
        attachment.lifetime = .keepAlways; add(attachment)
        if ProcessInfo.processInfo.environment["POWDERMEET_RECORD_REHEARSAL"] == "1" {
            try Data(resortID.utf8).write(to: root.appendingPathComponent("recording-ready"), options: .atomic)
            try await Task.sleep(for: .seconds(3))
            coordinator.routeAnimationTrigger += 1
            try await Task.sleep(for: .seconds(15))
        }
        XCTAssertGreaterThan(result.pathA.count, 0)
        XCTAssertGreaterThan(result.pathB.count, 0)
        XCTAssertEqual(result.solveAttempt, .nonCanonicalDataset)
    }
}
