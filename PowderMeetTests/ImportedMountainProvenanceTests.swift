import XCTest
@testable import PowderMeet

final class ImportedMountainProvenanceTests: XCTestCase {
    private func fixture(source: MountainDataset.Source, date: String? = "2026-04-28") -> MountainDataset {
        let node = GraphNode(id: "base", coordinate: .init(latitude: 40, longitude: -106),
            elevation: 900, kind: .liftBase)
        let top = GraphNode(id: "top", coordinate: .init(latitude: 40.002, longitude: -106),
            elevation: 1100, kind: .trailHead)
        let edge = GraphEdge(id: "run", sourceID: top.id, targetID: node.id, kind: .run,
            geometry: [top.coordinate, node.coordinate],
            attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 220, verticalDrop: 200,
                trailName: "Test Run", isOpen: true))
        return MountainDataset(resortID: "fixture", version: MountainDatasetVersion(
            manifestVersion: source == .canonicalServer ? 7 : nil,
            graphVersion: source == .canonicalServer ? "v12" : "v9-s3",
            contentSHA256: String(repeating: "a", count: 64)), snapshotDate: date, source: source,
            graph: MountainGraph(resortID: "fixture", nodes: [node.id: node, top.id: top], edges: [edge]),
            rendezvousPoints: [RendezvousPoint(id: node.id, nodeID: node.id, kind: .liftBase,
                displayName: "Reviewed stop", confidence: 0.9, quality: 0.8)])
    }

    private func changedGraph(_ original: MountainDataset) -> MountainGraph {
        var graph = original.graph
        graph.nodes["extra"] = GraphNode(id: "extra", coordinate: .init(latitude: 40.001, longitude: -106),
            elevation: 1000, kind: .trailHead)
        graph.rebuildIndices()
        return graph
    }

    func testUnchangedCachedGraphKeepsExactSourceIdentityAndUnknownDate() {
        for source in [MountainDataset.Source.legacySnapshot, .legacyOverpass] {
            for date in ["2026-04-28", nil] {
                let original = fixture(source: source, date: date)
                let result = original.applyingLegacyEnrichment(original.graph)
                XCTAssertEqual(result.version, original.version)
                XCTAssertEqual(result.snapshotDate, original.snapshotDate)
                XCTAssertEqual(result.source, source)
                XCTAssertEqual(result.graph.fingerprint, original.graph.fingerprint)
            }
        }
    }

    func testEnrichmentChangesContentIdentityWithoutPretendingToRebuildSource() {
        let original = fixture(source: .legacySnapshot)
        let graph = changedGraph(original)
        let result = original.applyingLegacyEnrichment(graph)
        XCTAssertEqual(result.version.graphVersion, "v9-s3")
        XCTAssertEqual(result.version.manifestVersion, original.version.manifestVersion)
        XCTAssertEqual(result.snapshotDate, "2026-04-28")
        XCTAssertEqual(result.source, .legacySnapshot)
        XCTAssertNotEqual(result.version.contentSHA256, original.version.contentSHA256)
        XCTAssertEqual(result.version.contentSHA256, Data(graph.fingerprint.utf8).sha256Hex)
        XCTAssertEqual(result.graph.fingerprint, graph.fingerprint)
        XCTAssertEqual(result.rendezvousCatalog.points.count, 1)
        XCTAssertEqual(result.rendezvousCatalog, original.rendezvousCatalog)
    }

    func testCanonicalIdentityAndGraphCannotBeRewrittenByImportEnrichment() {
        let original = fixture(source: .canonicalServer)
        let result = original.applyingLegacyEnrichment(changedGraph(original))
        XCTAssertEqual(result.version, original.version)
        XCTAssertEqual(result.graph.fingerprint, original.graph.fingerprint)
        XCTAssertEqual(result.snapshotDate, original.snapshotDate)
        XCTAssertEqual(result.source, .canonicalServer)
    }
}
