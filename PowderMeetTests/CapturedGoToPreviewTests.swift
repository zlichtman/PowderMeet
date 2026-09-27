//
//  CapturedGoToPreviewTests.swift
//  PowderMeetTests
//
//  Opt-in audit of the pre-release Go To preview on real exported source
//  graphs, mirroring DestinationRouteSheet exactly: every catalog landmark,
//  the auto-picked start lift that reaches it over open edges, and the
//  timeless strict `pathTo` the preview runs. Rehearsal evidence only — not
//  canonical review, live status, or navigation approval.
//

import XCTest
@testable import PowderMeet

final class CapturedGoToPreviewTests: XCTestCase {
    func testGoToPreviewAcrossCapturedResortGraphs() throws {
        guard let directory = ProcessInfo.processInfo.environment["POWDERMEET_ROUTE_AUDIT_DIRECTORY"] else {
            throw XCTSkip("Set POWDERMEET_ROUTE_AUDIT_DIRECTORY to exported source graphs")
        }
        let root = URL(fileURLWithPath: directory)
        let requested = ProcessInfo.processInfo.environment["POWDERMEET_GO_TO_RESORTS"]?
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        struct Manifest: Decodable { let resorts: [String] }
        let resorts = try requested ?? JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        ).resorts

        var report: [[String: Any]] = []
        for id in resorts {
            let graph = try JSONDecoder().decode(
                MountainGraph.self,
                from: Data(contentsOf: root.appendingPathComponent(id + ".json"))
            )
            let catalog = RendezvousCatalog.derived(from: graph)
            let destinations = LandmarkRoutePolicy.orderedDestinations(catalog.points)
            let starts = destinations.filter { $0.kind == .liftBase || $0.kind == .midStation }

            for preset in ["intermediate", "expert"] {
                var skier = UserProfile.defaultProfile(
                    id: UUID(uuidString: "D3A00000-0000-4000-8000-000000000003")!
                )
                skier.applyPreset(preset)
                var routed = 0
                var noStart: [String] = []
                var noPath: [String] = []
                for point in destinations {
                    let reachable = LandmarkRoutePolicy.nodesReaching(
                        destinationNodeID: point.nodeID,
                        edges: graph.edges
                    )
                    guard let start = starts.first(where: {
                        $0.nodeID != point.nodeID && reachable.contains($0.nodeID)
                    }) else {
                        noStart.append(point.displayName ?? point.nodeID)
                        continue
                    }
                    let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
                    solver.solveTime = nil
                    if let route = solver.pathTo(
                        target: point.nodeID,
                        from: .node(start.nodeID),
                        skier: skier
                    ), !route.path.isEmpty {
                        XCTAssertEqual(route.path.first?.sourceID, start.nodeID)
                        XCTAssertEqual(route.path.last?.targetID, point.nodeID)
                        routed += 1
                    } else {
                        noPath.append(point.displayName ?? point.nodeID)
                    }
                }
                report.append([
                    "resort_id": id, "skier": preset,
                    "destinations": destinations.count, "routed": routed,
                    "no_connected_start": noStart, "no_strict_path": noPath,
                ])
                print("[GoToPreview] \(id) \(preset): \(routed)/\(destinations.count) routed; "
                      + "\(noStart.count) without a connected start, \(noPath.count) without a strict path")
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Go To preview audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        try data.write(to: root.appendingPathComponent("go-to-preview-results.json"), options: .atomic)
    }
}
