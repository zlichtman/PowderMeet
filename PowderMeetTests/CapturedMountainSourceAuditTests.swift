import XCTest
import CryptoKit
@testable import PowderMeet

/// Explicit local data audit. Ordinary CI never downloads a mountain, reads
/// an account, or starts a snapshot build as a side effect of this test.
final class CapturedMountainSourceAuditTests: XCTestCase {
    func testCapturedWhistlerSourceBuildsDeterministicallyAndRetainsInputIdentity() async throws {
        guard let path = ProcessInfo.processInfo.environment["POWDERMEET_MOUNTAIN_AUDIT_DIRECTORY"] else {
            throw XCTSkip("Set POWDERMEET_MOUNTAIN_AUDIT_DIRECTORY to an explicit local capture")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let osm = try Data(contentsOf: root.appendingPathComponent("whistler-osm.json"))
        let elevations = try Data(contentsOf: root.appendingPathComponent("terrain-rgb/elevations.json"))
        let manifestData = try Data(contentsOf: root.appendingPathComponent("terrain-rgb/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["sourceSHA256"] as? String, sha(osm))
        XCTAssertEqual(manifest["elevationSHA256"] as? String, sha(elevations))
        let required = try XCTUnwrap(manifest["requiredCoordinates"] as? Int)
        let samples = try JSONDecoder().decode([String: Double].self, from: elevations)
        XCTAssertGreaterThan(required, 0)
        XCTAssertEqual(samples.count, required)
        XCTAssertEqual(manifest["resolvedCoordinates"] as? Int, required)
        XCTAssertTrue(samples.values.allSatisfy { $0.isFinite })
        let sourceTimestamp = try XCTUnwrap(manifest["sourceOSMTimestamp"] as? String)
        let sourceDate = String(sourceTimestamp.prefix(10))
        let entry = try XCTUnwrap(ResortEntry.catalog.first { $0.id == "whistler" })
        let data = try await OverpassService().buildFromSnapshot(osmData: osm, elevationData: elevations, entry: entry)
        let requiredKeys = Set((data.trails.flatMap(\.coordinates) + data.lifts.flatMap(\.coordinates)
            + (data.connections ?? []).flatMap(\.coordinates)).map { String(format: "%.6f,%.6f", $0.lat, $0.lon) })
        XCTAssertEqual(requiredKeys, Set(samples.keys), "Completeness means the exact source coordinates, not just an equal count")
        let graph = GraphBuilder.buildGraph(from: data, resortID: entry.id)
        try MountainGraphIntegrity.validateCanonical(graph, expectedResortID: entry.id)
        let repeatGraph = GraphBuilder.buildGraph(from: data, resortID: entry.id)
        XCTAssertEqual(graph.fingerprint, repeatGraph.fingerprint, "Repeated builds of identical decoded inputs must agree")

        // Different element ordering must not create a different mountain.
        var reordered = try XCTUnwrap(JSONSerialization.jsonObject(with: osm) as? [String: Any])
        let elements = try XCTUnwrap(reordered["elements"] as? [[String: Any]])
        reordered["elements"] = Array(elements.reversed())
        let alternateData = try await OverpassService().buildFromSnapshot(
            osmData: JSONSerialization.data(withJSONObject: reordered), elevationData: elevations, entry: entry)
        let alternate = GraphBuilder.buildGraph(from: alternateData, resortID: entry.id)
        let alternateTrails = Dictionary(uniqueKeysWithValues: alternateData.trails.map { ($0.id, $0) })
        let nameChanges = data.trails.sorted { $0.id < $1.id }.compactMap { trail -> String? in
            guard let other = alternateTrails[trail.id], trail.name != other.name else { return nil }
            return "\(trail.id): \(trail.name ?? "<unnamed>") -> \(other.name ?? "<unnamed>")"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let alternateEdges = Dictionary(uniqueKeysWithValues: alternate.edges.map { ($0.id, $0) })
        let changedEdges = try graph.edges.sorted { $0.id < $1.id }.filter { edge in
            guard let other = alternateEdges[edge.id] else { return true }
            return try encoder.encode(edge) != encoder.encode(other)
        }
        let changedNodes = try graph.nodes.values.sorted { $0.id < $1.id }.filter { node in
            guard let other = alternate.nodes[node.id] else { return true }
            return try encoder.encode(node) != encoder.encode(other)
        }
        let differences = XCTAttachment(string: "Changed source names: \(nameChanges.count)\n"
            + nameChanges.joined(separator: "\n") + "\nChanged edges: \(changedEdges.count)\n"
            + changedEdges.prefix(30).map(\.id).joined(separator: ", ")
            + "\nChanged nodes: \(changedNodes.count)\n"
            + changedNodes.prefix(30).map { "\($0.id): \($0.kind) -> \(String(describing: alternate.nodes[$0.id]?.kind))" }.joined(separator: "\n"))
        differences.name = "Source ordering differences"
        differences.lifetime = .keepAlways
        add(differences)
        for edge in changedEdges.prefix(3) {
            let pair = ["forward": edge, "reversed": alternateEdges[edge.id]!]
            let detail = XCTAttachment(data: try encoder.encode(pair), uniformTypeIdentifier: "public.json")
            detail.name = "Ordering edge detail - \(edge.id)"
            detail.lifetime = .keepAlways
            add(detail)
        }
        XCTAssertEqual(graph.fingerprint, alternate.fingerprint, "The source record order is not mountain identity")

        let version = MountainDatasetVersion(manifestVersion: nil,
            graphVersion: MountainRepository.expectedLegacyVersion,
            contentSHA256: sha(Data(graph.fingerprint.utf8)))
        let dataset = MountainDataset(resortID: entry.id, version: version,
            snapshotDate: sourceDate, source: .legacySnapshot, graph: graph)
        let envelope = CachedMountainDataset(dataset: dataset, cachedAt: Date())
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(CachedMountainDataset.self, from: encoded)
        XCTAssertEqual(decoded.dataset.version, version)
        XCTAssertEqual(decoded.dataset.snapshotDate, sourceDate)
        XCTAssertEqual(decoded.graphFingerprint, graph.fingerprint)
        XCTAssertEqual(decoded.graph.fingerprint, graph.fingerprint, "JSON round trips must preserve the actual graph fingerprint")
        let artifact = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        artifact.name = "Fresh Whistler audit dataset"
        artifact.lifetime = .keepAlways
        add(artifact)
        let liftCount = graph.edges.filter { $0.kind == .lift }.count
        let lines = ["Source SHA: \(sha(osm))", "Elevation SHA: \(sha(elevations))",
            "Source timestamp: \(sourceTimestamp)", "Version: \(version.identifier)",
            "Fingerprint: \(graph.fingerprint)", "Source ways: \(data.trails.count) trails / \(data.lifts.count) lifts",
            "Built edges: \(graph.runs.count) runs / \(liftCount) lifts",
            "Demo trail groups (including unnamed): \(RoutingTestSheet.trailEntries(in: graph).count)",
            "Rendezvous candidates: \(dataset.rendezvousCatalog.points.count)",
            "Unreviewed local audit only; no published canonical manifest or live operating status."]
        let report = XCTAttachment(string: lines.joined(separator: "\n"))
        report.name = "Fresh mountain source audit"
        report.lifetime = .keepAlways
        add(report)
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
