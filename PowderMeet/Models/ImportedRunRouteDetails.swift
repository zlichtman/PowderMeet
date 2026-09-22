import Foundation

/// A readable projection of persisted attribution, never a new match or a
/// source of learned pace. The primary trail name stays frozen on the record.
struct ImportedRunRouteDetails: Equatable {
    struct Section: Identifiable, Equatable {
        let id: String
        let name: String?
        let segmentIDs: [String]
        var title: String { name ?? "Unnamed trail section" }
    }

    enum UnavailableReason: Equatable {
        case noTopology, recordedDatasetNotLoaded, incompleteSequence

        var explanation: String {
            switch self {
            case .noTopology:
                return "This activity has no complete recorded route match. A suggested or nearby trail name is not an ordered route."
            case .recordedDatasetNotLoaded:
                return "The mountain version used for this recording is not loaded. Route sections will not be guessed from a different mountain or version."
            case .incompleteSequence:
                return "The saved segment sequence cannot be fully resolved as a connected downhill route. Missing sections have not been skipped or joined."
            }
        }
    }

    let sections: [Section]
    let unavailableReason: UnavailableReason?
    static func unavailable(_ reason: UnavailableReason) -> Self {
        Self(sections: [], unavailableReason: reason)
    }
}

/// Build the naming index once per loaded immutable dataset, not once per
/// activity row or sheet render. No network requests or persistence writes.
struct ImportedRunRouteIndex {
    let dataset: MountainDataset
    private let naming: MountainNaming

    init(dataset: MountainDataset) {
        self.dataset = dataset
        naming = MountainNaming(dataset.graph)
    }

    func details(for run: ImportedRunRecord) -> ImportedRunRouteDetails {
        let status = ImportedRunMatchStatus(method: run.matchMethod, confidence: run.matchConfidence,
            dataset: run.datasetVersion, edgeID: run.edgeId, segments: run.matchedSegmentIds)
        guard ["polyline_sequence", RecordedPaceEvidence.routeOnlyMethod].contains(run.matchMethod ?? ""),
              status != .unverified, let ids = run.matchedSegmentIds, !ids.isEmpty else {
            return .unavailable(.noTopology)
        }
        guard run.resortId == dataset.resortID, run.datasetVersion == dataset.version.identifier else {
            return .unavailable(.recordedDatasetNotLoaded)
        }

        var sections: [ImportedRunRouteDetails.Section] = []
        var previous: GraphEdge?
        var previousIdentity: String?
        for (index, id) in ids.enumerated() {
            guard let edge = dataset.graph.edge(byID: id), edge.kind == .run,
                  dataset.graph.nodes[edge.sourceID] != nil,
                  dataset.graph.nodes[edge.targetID] != nil,
                  previous == nil || previous?.targetID == edge.sourceID else {
                return .unavailable(.incompleteSequence)
            }
            // Historical traversal is not invalidated by today's closure.
            // Collapse only adjacent fragments of the same group AND label;
            // revisiting a trail later remains a separate ordered section.
            let name = ImportedRunNameQuality.evidenceBackedTrailName(for: edge, naming: naming)
            let group = edge.attributes.trailGroupId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = group.flatMap { $0.isEmpty ? nil : "group:\($0)" } ?? "edge:\(edge.id)"
            if previousIdentity == identity, let last = sections.last, last.name == name {
                sections[sections.count - 1] = .init(id: last.id, name: name, segmentIDs: last.segmentIDs + [id])
            } else {
                sections.append(.init(id: "\(index):\(id)", name: name, segmentIDs: [id]))
            }
            previousIdentity = identity
            previous = edge
        }
        return .init(sections: sections, unavailableReason: nil)
    }
}
