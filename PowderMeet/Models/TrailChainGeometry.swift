//
//  TrailChainGeometry.swift
//  PowderMeet
//
//  Shared ordering + chaining of graph edges for map GeoJSON, sun overlay,
//  and trail-group endpoints (picker / HUD alignment).
//

import Foundation
import CoreLocation

// `nonisolated` — trail-chain geometry helpers are called from
// MountainGraph extensions that compute off-main-actor.
nonisolated enum TrailChainGeometry {

    /// Orders edges in a group into a connected chain by walking shared endpoints.
    static func orderEdgeChain(_ edges: [GraphEdge]) -> [GraphEdge] {
        guard edges.count > 1 else { return edges }

        // Graph blobs normally emit a stable edge order, but this helper is
        // also used by legacy/cache inputs and should not make geometry depend
        // on array insertion order. Edge IDs are canonical and unique.
        let stableEdges = edges.sorted { $0.id < $1.id }
        var nodeToEdges: [String: [GraphEdge]] = [:]
        for edge in stableEdges {
            nodeToEdges[edge.sourceID, default: []].append(edge)
            nodeToEdges[edge.targetID, default: []].append(edge)
        }
        for nodeID in nodeToEdges.keys {
            nodeToEdges[nodeID]?.sort { $0.id < $1.id }
        }

        var used: Set<String> = []
        var ordered: [GraphEdge] = []
        ordered.reserveCapacity(stableEdges.count)

        while used.count < stableEdges.count {
            let unusedEdges = stableEdges.filter { !used.contains($0.id) }
            guard !unusedEdges.isEmpty else { break }

            // Recompute degree in the remaining subgraph. A terminal gives a
            // natural chain start; cycles/branches fall back to stable node ID.
            var remainingDegree: [String: Int] = [:]
            for edge in unusedEdges {
                remainingDegree[edge.sourceID, default: 0] += 1
                remainingDegree[edge.targetID, default: 0] += 1
            }
            let startNode = remainingDegree
                .filter { $0.value == 1 }
                .map(\.key)
                .sorted()
                .first
                ?? remainingDegree.keys.sorted().first!

            var currentNode = startNode
            while let next = nodeToEdges[currentNode]?
                .first(where: { !used.contains($0.id) }) {
                ordered.append(next)
                used.insert(next.id)
                currentNode = next.sourceID == currentNode
                    ? next.targetID
                    : next.sourceID
            }
        }

        return ordered
    }

    /// Concatenates edge geometries as `[lon, lat]` pairs, deduping shared vertices.
    /// - Parameter graph: When set, the first edge’s polyline is oriented so the vertex
    ///   closest to the directed edge’s `sourceID` is first — OSM way order is not
    ///   always `source`→`target` along the stored geometry.
    static func chainGeometryLonLat(
        _ edges: [GraphEdge],
        orientingWith graph: MountainGraph? = nil
    ) -> [[Double]] {
        guard !edges.isEmpty else { return [] }
        var rawCoords: [[Double]] = []

        for (i, edge) in edges.enumerated() {
            var coords = edge.geometry.map { [$0.longitude, $0.latitude] }

            if i == 0, coords.count >= 2, let g = graph, let sNode = g.nodes[edge.sourceID] {
                let s = CLLocation(latitude: sNode.coordinate.latitude, longitude: sNode.coordinate.longitude)
                let first = CLLocation(latitude: coords[0][1], longitude: coords[0][0])
                let lastIdx = coords.count - 1
                let last = CLLocation(latitude: coords[lastIdx][1], longitude: coords[lastIdx][0])
                if s.distance(from: last) < s.distance(from: first) {
                    coords.reverse()
                }
            }

            if i > 0,
               let lastPoint = rawCoords.last,
               let firstPoint = coords.first,
               let lastPointRev = coords.last,
               coords.count >= 2 {
                let distForward = abs(lastPoint[0] - firstPoint[0]) + abs(lastPoint[1] - firstPoint[1])
                let distReverse = abs(lastPoint[0] - lastPointRev[0]) + abs(lastPoint[1] - lastPointRev[1])

                if distReverse < distForward {
                    coords.reverse()
                }
            }

            if i == 0 {
                rawCoords.append(contentsOf: coords)
            } else if let last = rawCoords.last, let first = coords.first,
                      abs(last[0] - first[0]) < 1e-6, abs(last[1] - first[1]) < 1e-6 {
                rawCoords.append(contentsOf: coords.dropFirst())
            } else {
                rawCoords.append(contentsOf: coords)
            }
        }

        return rawCoords
    }

    /// Same path as the map’s route LineString, as core-location pairs (handy for camera fit).
    static func chainCoordinatesCLLocation(
        _ edges: [GraphEdge],
        orientingWith graph: MountainGraph? = nil
    ) -> [CLLocationCoordinate2D] {
        let lonLat = chainGeometryLonLat(edges, orientingWith: graph)
        return lonLat.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }

    /// Degree-1 nodes in the subgraph induced by `ordered` edges; used for top/bottom.
    static func chainTerminalNodes(ordered: [GraphEdge]) -> [String] {
        var deg: [String: Int] = [:]
        for e in ordered {
            deg[e.sourceID, default: 0] += 1
            deg[e.targetID, default: 0] += 1
        }
        return deg.filter { $0.value == 1 }.map(\.key).sorted()
    }
}
