import Foundation
import CryptoKit

nonisolated extension MountainDataset {
    /// Enrichment is not a new source snapshot or a run of the current builder.
    /// Preserve provenance; only a changed legacy graph receives a new content hash.
    /// Canonical datasets are immutable and must never be locally overlaid.
    func applyingLegacyEnrichment(_ enrichedGraph: MountainGraph) -> MountainDataset {
        guard source != .canonicalServer,
              enrichedGraph.fingerprint != graph.fingerprint else { return self }
        return MountainDataset(
            resortID: resortID,
            version: MountainDatasetVersion(
                manifestVersion: version.manifestVersion,
                graphVersion: version.graphVersion,
                contentSHA256: Data(enrichedGraph.fingerprint.utf8).sha256Hex
            ),
            snapshotDate: snapshotDate,
            source: source,
            graph: enrichedGraph,
            rendezvousPoints: rendezvousCatalog.points
        )
    }
}
