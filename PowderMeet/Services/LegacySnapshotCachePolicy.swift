/// A preview cache is usable only for the requested immutable snapshot and
/// current builder. Old geometry must not hide a corrected mountain map.
nonisolated enum LegacySnapshotCachePolicy {
    static func matches(_ dataset: MountainDataset, resortID: String,
                        snapshotDate: String, graphVersion: String) -> Bool {
        dataset.source == .legacySnapshot
            && dataset.resortID == resortID
            && dataset.graph.resortID == resortID
            && dataset.snapshotDate == snapshotDate
            && dataset.version.graphVersion == graphVersion
    }
}
