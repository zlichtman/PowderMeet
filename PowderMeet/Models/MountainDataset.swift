//
//  MountainDataset.swift
//  PowderMeet
//
//  Immutable mountain topology and its separately timestamped operational
//  status. `MountainGraph` remains the routing/render compatibility shape;
//  callers derive it from these values instead of mutating the dataset.
//

import Foundation

nonisolated struct MountainDatasetVersion: Codable, Hashable, Sendable {
    let manifestVersion: Int?
    let graphVersion: String
    let contentSHA256: String

    var identifier: String {
        let manifest = manifestVersion.map(String.init) ?? "legacy"
        return "m\(manifest)-\(graphVersion)-\(contentSHA256)"
    }

    /// Parses the exact immutable identity stamped onto meet requests,
    /// imported runs, and learned edge speeds. Graph versions may contain
    /// hyphens (for example legacy v9-s3), so parsing is anchored at the
    /// manifest prefix and 64-character SHA suffix rather than a fixed split.
    init?(identifier: String) {
        let components = identifier.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard components.count >= 3,
              let manifestToken = components.first,
              manifestToken.first == "m",
              let shaToken = components.last,
              shaToken.utf8.count == 64,
              shaToken.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }

        let manifestText = manifestToken.dropFirst()
        if manifestText == "legacy" {
            manifestVersion = nil
        } else if let parsed = Int(manifestText), parsed > 0 {
            manifestVersion = parsed
        } else {
            return nil
        }

        let versionComponents = components.dropFirst().dropLast()
        let parsedGraphVersion = versionComponents.joined(separator: "-")
        guard !parsedGraphVersion.isEmpty,
              parsedGraphVersion.utf8.allSatisfy({
                  (48...57).contains($0)
                      || (65...90).contains($0)
                      || (97...122).contains($0)
                      || $0 == 45
              }) else {
            return nil
        }
        graphVersion = parsedGraphVersion
        contentSHA256 = String(shaToken)
    }

    init(
        manifestVersion: Int?,
        graphVersion: String,
        contentSHA256: String
    ) {
        self.manifestVersion = manifestVersion
        self.graphVersion = graphVersion
        self.contentSHA256 = contentSHA256
    }
}

nonisolated struct MountainDataset: Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case canonicalServer
        case legacySnapshot
        case legacyOverpass
    }

    let resortID: String
    let version: MountainDatasetVersion
    let snapshotDate: String?
    let source: Source
    let graph: MountainGraph
    let rendezvousCatalog: RendezvousCatalog

    init(
        resortID: String,
        version: MountainDatasetVersion,
        snapshotDate: String?,
        source: Source,
        graph: MountainGraph,
        rendezvousPoints: [RendezvousPoint]? = nil
    ) {
        precondition(graph.resortID == resortID, "Dataset resort must match graph resort")
        self.resortID = resortID
        self.version = version
        self.snapshotDate = snapshotDate
        self.source = source
        self.graph = graph
        self.rendezvousCatalog = rendezvousPoints.map {
            RendezvousCatalog(points: $0, graph: graph)
        } ?? .derived(from: graph)
    }

    enum CodingKeys: String, CodingKey {
        case resortID, version, snapshotDate, source, graph, rendezvousCatalog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resortID = try container.decode(String.self, forKey: .resortID)
        version = try container.decode(MountainDatasetVersion.self, forKey: .version)
        snapshotDate = try container.decodeIfPresent(String.self, forKey: .snapshotDate)
        source = try container.decode(Source.self, forKey: .source)
        let decodedGraph = try container.decode(MountainGraph.self, forKey: .graph)
        guard decodedGraph.resortID == resortID else {
            throw DecodingError.dataCorruptedError(
                forKey: .graph,
                in: container,
                debugDescription: "Dataset resort must match graph resort"
            )
        }
        graph = decodedGraph
        let decoded = try container.decodeIfPresent(
            RendezvousCatalog.self,
            forKey: .rendezvousCatalog
        )
        rendezvousCatalog = decoded.map {
            RendezvousCatalog(points: $0.points, graph: decodedGraph)
        } ?? .derived(from: decodedGraph)
    }

    /// Compatibility projection for existing routing/render consumers.
    /// The immutable topology remains untouched; only a copy receives fresh,
    /// dataset-matched operational status.
    func routingGraph(applying status: MountainStatus?, at date: Date = .now) -> MountainGraph {
        guard let status,
              status.resortID == resortID,
              status.datasetVersion == version,
              status.isUsable(at: date) else {
            return graph
        }

        var projected = graph
        for index in projected.edges.indices {
            let edge = projected.edges[index]
            guard let state = status.segmentStates[edge.id] else { continue }
            let attributes = edge.attributes.enriched(
                waitTimeMinutes: state.waitMinutes,
                isOpen: state.isOpen
            )
            projected.edges[index] = edge.withAttributes(attributes)
        }
        projected.rebuildIndices()
        return projected
    }
}

nonisolated struct MountainStatus: Codable, Sendable {
    enum OperatingMode: String, Codable, Sendable {
        case active
        case offSeason
    }

    enum Source: String, Codable, Sendable {
        case canonicalSidecar
        case legacyDeviceEnrichment
    }

    struct SegmentState: Codable, Equatable, Sendable {
        let isOpen: Bool
        let waitMinutes: Double?
    }

    let resortID: String
    let datasetVersion: MountainDatasetVersion
    let observedAt: Date
    let expiresAt: Date
    let source: Source
    let operatingMode: OperatingMode
    /// 0...1 confidence in the identity mapping and source freshness.
    let confidence: Double
    /// Stable graph segment/lift ID → current operational state.
    let segmentStates: [String: SegmentState]

    init(
        resortID: String,
        datasetVersion: MountainDatasetVersion,
        observedAt: Date,
        expiresAt: Date,
        source: Source,
        operatingMode: OperatingMode = .active,
        confidence: Double,
        segmentStates: [String: SegmentState]
    ) {
        self.resortID = resortID
        self.datasetVersion = datasetVersion
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.source = source
        self.operatingMode = operatingMode
        self.confidence = confidence
        self.segmentStates = segmentStates
    }

    enum CodingKeys: String, CodingKey {
        case resortID, datasetVersion, observedAt, expiresAt, source
        case operatingMode, confidence, segmentStates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resortID = try c.decode(String.self, forKey: .resortID)
        datasetVersion = try c.decode(MountainDatasetVersion.self, forKey: .datasetVersion)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        source = try c.decode(Source.self, forKey: .source)
        operatingMode = try c.decodeIfPresent(OperatingMode.self, forKey: .operatingMode) ?? .active
        confidence = try c.decode(Double.self, forKey: .confidence)
        segmentStates = try c.decode([String: SegmentState].self, forKey: .segmentStates)
    }

    func isUsable(at date: Date = .now) -> Bool {
        confidence > 0 && observedAt <= date && observedAt <= expiresAt && date <= expiresAt
    }

    func isRoutable(at date: Date = .now) -> Bool {
        operatingMode == .active && isUsable(at: date)
    }
}
