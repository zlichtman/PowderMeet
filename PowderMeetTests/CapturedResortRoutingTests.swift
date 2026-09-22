import XCTest
@testable import PowderMeet

/// Explicitly opted-in integration with real source graphs exported by the
/// server builder. Successful samples are rehearsal evidence, not a coverage
/// approval, current operating status, or permission to send live meetups.
final class CapturedResortRoutingTests: XCTestCase {
    func testProductionSolverAcrossCapturedResorts() throws {
        guard let directory = ProcessInfo.processInfo.environment["POWDERMEET_ROUTE_AUDIT_DIRECTORY"] else {
            throw XCTSkip("Set POWDERMEET_ROUTE_AUDIT_DIRECTORY to exported source graphs")
        }
        struct Manifest: Decodable { let resorts: [String] }
        let root = URL(fileURLWithPath: directory)
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var report: [[String: Any]] = []
        for id in manifest.resorts {
            let graph = try JSONDecoder().decode(MountainGraph.self,
                from: Data(contentsOf: root.appendingPathComponent(id + ".json")))
            try MountainGraphIntegrity.validateCanonical(graph, expectedResortID: id)
            var a = UserProfile.defaultProfile(id: UUID(uuidString: "D3A00000-0000-4000-8000-000000000001")!)
            var b = UserProfile.defaultProfile(id: UUID(uuidString: "D3A00000-0000-4000-8000-000000000002")!)
            a.applyPreset("expert"); b.applyPreset("expert")
            let catalog = RendezvousCatalog.derived(from: graph)
            let incoming = Dictionary(grouping: graph.edges.filter { $0.kind == .run && $0.attributes.isOpen }, by: \.targetID)
            var sampled = 0
            var success: MeetingResult?
            var starts: [String] = []
            // Distinct upstream points must converge on a real source lift base.
            // Restrict sample discovery to downhill edges; no synthetic links.
            for point in catalog.points.sorted(by: { $0.id < $1.id }) {
                var seen: Set<String> = [point.nodeID]
                var frontier = [point.nodeID]
                var candidates: [String] = []
                for _ in 0..<8 {
                    var next: [String] = []
                    for target in frontier {
                        for edge in (incoming[target] ?? []).sorted(by: { $0.id < $1.id }) {
                            if seen.insert(edge.sourceID).inserted {
                                next.append(edge.sourceID)
                                candidates.append(edge.sourceID)
                            }
                        }
                    }
                    frontier = next
                }
                guard candidates.count >= 2 else { continue }
                let pair = Array(candidates.suffix(2))
                let solver = MeetingPointSolver(graph: graph, rendezvousCatalog: catalog)
                sampled += 1
                if let result = solver.solve(skierA: a, positionA: pair[0], skierB: b, positionB: pair[1]),
                   !result.pathA.isEmpty, !result.pathB.isEmpty {
                    XCTAssertEqual(result.pathA.first?.sourceID, pair[0])
                    XCTAssertEqual(result.pathB.first?.sourceID, pair[1])
                    XCTAssertEqual(result.pathA.last?.targetID, result.meetingNode.id)
                    XCTAssertEqual(result.pathB.last?.targetID, result.meetingNode.id)
                    success = result; starts = pair; break
                }
                if sampled >= 4 { break }
            }
            var row: [String: Any] = ["resort_id": id, "nodes": graph.nodes.count,
                "edges": graph.edges.count, "rendezvous_candidates": catalog.points.count,
                "sampled_pairs": sampled, "rehearsal_route_found": success != nil,
                "canonical_reviewed": false, "live_status_tested": false]
            if let result = success {
                row["starts"] = starts; row["meeting_node"] = result.meetingNode.id
                row["path_a"] = result.pathA.map(\.id); row["path_b"] = result.pathB.map(\.id)
            }
            report.append(row)
            print("[ResortAcceptance] \(id): sample \(success == nil ? "UNRESOLVED" : "PASS")")
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("iphone-route-results.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Actual iPhone solver resort samples"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(report.count, manifest.resorts.count)
    }
}
