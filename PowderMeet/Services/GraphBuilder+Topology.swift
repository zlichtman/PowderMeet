//
//  GraphBuilder+Topology.swift
//  PowderMeet
//
//  Extension of GraphBuilder — long-edge splitting, trail-intersection detection, lift-top -> run matching.
//  Split out of GraphBuilder.swift (behavior-preserving code motion) so the
//  legacy on-device build pipeline is navigable by stage. File-private helpers
//  were promoted to internal to be visible across these extension files.
//

import Foundation
import CoreLocation

nonisolated extension GraphBuilder {
    /// Splits edges only where two distinct source ways share the same source
    /// vertex ID. This preserves real junctions while rejecting proximity,
    /// geometric crossing, and grade-separated false connections.
    static func splitEdgesAtSharedSourceVertices(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        sourceTopology: inout [String: SourceTopology]
    ) {
        var ownersByVertex: [Int64: Set<String>] = [:]
        for source in sourceTopology.values {
            for vertexID in Set(source.vertexIDs.compactMap { $0 }) {
                ownersByVertex[vertexID, default: []].insert(source.ownerID)
            }
        }
        let sharedVertices = Set(
            ownersByVertex.compactMap { vertexID, owners in
                owners.count > 1 ? vertexID : nil
            }
        )
        guard !sharedVertices.isEmpty else { return }

        var splitEdges: [GraphEdge] = []
        for edge in edges {
            guard let source = sourceTopology[edge.id],
                  source.vertexIDs.count == edge.geometry.count else {
                splitEdges.append(edge)
                continue
            }

            var splitIndices = [0]
            if source.vertexIDs.count > 2 {
                for index in 1..<(source.vertexIDs.count - 1) {
                    if let vertexID = source.vertexIDs[index], sharedVertices.contains(vertexID) {
                        splitIndices.append(index)
                    }
                }
            }
            splitIndices.append(edge.geometry.count - 1)
            var seen: Set<Int> = []
            let ordered = splitIndices.filter { seen.insert($0).inserted }.sorted()
            guard ordered.count > 2 else {
                splitEdges.append(edge)
                continue
            }

            let sourceElevation = nodes[edge.sourceID]?.elevation ?? 0
            let targetElevation = nodes[edge.targetID]?.elevation ?? 0
            let elevations = elevationProfile(geometry: edge.geometry, raw: source.elevations,
                                              from: sourceElevation, to: targetElevation)
            var nodeIDs: [String] = []
            for (position, index) in ordered.enumerated() {
                if position == 0 {
                    nodeIDs.append(edge.sourceID)
                } else if position == ordered.count - 1 {
                    nodeIDs.append(edge.targetID)
                } else {
                    let coordinate = edge.geometry[index]
                    let modelCoordinate = Coordinate(
                        lat: coordinate.latitude,
                        lon: coordinate.longitude
                    )
                    let id = source.vertexIDs[index].map(sourceVertexNodeID)
                        ?? "\(nodeID(for: modelCoordinate))_source_\(edge.id)_\(index)"
                    ensureNode(
                        &nodes,
                        id: id,
                        coord: modelCoordinate,
                        elevation: elevations[index],
                        kind: .junction
                    )
                    nodeIDs.append(id)
                }
            }

            for segment in 1..<ordered.count {
                let start = ordered[segment - 1]
                let end = ordered[segment]
                guard end > start, nodeIDs[segment - 1] != nodeIDs[segment] else { continue }
                let geometry = Array(edge.geometry[start...end])
                let length = polylineLength(geometry)
                let fromElevation = nodes[nodeIDs[segment - 1]]?.elevation ?? 0
                let toElevation = nodes[nodeIDs[segment]]?.elevation ?? 0
                let elevationChange = edge.kind == .traverse
                    ? toElevation - fromElevation
                    : abs(toElevation - fromElevation)
                let gradient = length > 0
                    ? atan(abs(elevationChange) / length) * 180 / .pi
                    : 0
                splitEdges.append(GraphEdge(
                    id: "\(edge.id)_vx\(segment)",
                    sourceID: nodeIDs[segment - 1],
                    targetID: nodeIDs[segment],
                    kind: edge.kind,
                    geometry: geometry,
                    attributes: segmentAttributes(
                        from: edge,
                        length: length,
                        elevationChange: elevationChange,
                        gradient: gradient,
                        maximumGradient: profileMaximumGradient(geometry: geometry,
                            elevations: Array(elevations[start...end])),
                        midpointElevation: (fromElevation + toElevation) / 2,
                        liftQueueEntry: edge.kind == .lift ? segment == 1 : nil
                    )
                ))
                sourceTopology["\(edge.id)_vx\(segment)"] = SourceTopology(
                    ownerID: source.ownerID,
                    vertexIDs: Array(source.vertexIDs[start...end]),
                    elevations: Array(elevations[start...end]).map { Optional($0) }
                )
            }
        }
        edges = splitEdges
    }

    static func segmentAttributes(
        from edge: GraphEdge,
        length: Double,
        elevationChange: Double,
        gradient: Double,
        maximumGradient: Double? = nil,
        midpointElevation: Double,
        liftQueueEntry: Bool? = nil
    ) -> EdgeAttributes {
        let attributes = edge.attributes
        let rideFraction = attributes.lengthMeters > 0 ? length / attributes.lengthMeters : 1
        return EdgeAttributes(
            difficulty: attributes.difficulty,
            lengthMeters: length,
            verticalDrop: elevationChange,
            averageGradient: gradient,
            maxGradient: maximumGradient ?? gradient,
            aspect: attributes.aspect,
            aspectVariance: attributes.aspectVariance,
            trailName: attributes.trailName,
            hasMoguls: attributes.hasMoguls,
            isGroomed: attributes.isGroomed,
            isGladed: attributes.isGladed,
            liftType: attributes.liftType,
            liftCapacity: attributes.liftCapacity,
            rideTimeSeconds: attributes.rideTimeSeconds.map { $0 * rideFraction },
            waitTimeMinutes: liftQueueEntry == false ? nil : attributes.waitTimeMinutes,
            weekdayWaitMinutes: liftQueueEntry == false ? nil : attributes.weekdayWaitMinutes,
            weekendWaitMinutes: liftQueueEntry == false ? nil : attributes.weekendWaitMinutes,
            chargesLiftWait: liftQueueEntry ?? attributes.chargesLiftWait,
            isOpen: attributes.isOpen,
            isOfficiallyValidated: attributes.isOfficiallyValidated,
            trailGroupId: attributes.trailGroupId,
            midpointElevation: midpointElevation,
            estimatedTrailWidthMeters: attributes.estimatedTrailWidthMeters,
            obstacleDensity: attributes.obstacleDensity,
            fallLineExposure: attributes.fallLineExposure,
            nightGroomedFlag: attributes.nightGroomedFlag,
            lastGroomedHoursAgo: attributes.lastGroomedHoursAgo,
            estimatedSurfaceCondition: attributes.estimatedSurfaceCondition
        )
    }

    /// Splits long trail geometry for route resolution. New nodes remain
    /// scoped to their source edge; this never infers nearby connections.
    static func splitLongEdges(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        maxSegmentLength: Double,
        sourceTopology: [String: SourceTopology] = [:]
    ) {
        var newEdges: [GraphEdge] = []
        var removeIds: Set<String> = []

        for edge in edges {
            guard edge.kind == .run else { continue } // Only split trail edges
            let length = edge.attributes.lengthMeters
            guard length > maxSegmentLength else { continue }
            guard edge.geometry.count >= 3 else { continue }

            let coords = edge.geometry
            let srcEle = nodes[edge.sourceID]?.elevation ?? 0
            let tgtEle = nodes[edge.targetID]?.elevation ?? 0
            let elevations = elevationProfile(geometry: coords,
                raw: sourceTopology[edge.id]?.elevations ?? [], from: srcEle, to: tgtEle)

            // Number of splits: ceil(length / maxSegmentLength) - 1
            let numSegments = max(2, Int(ceil(length / maxSegmentLength)))
            let stepSize = coords.count / numSegments

            guard stepSize >= 1 else { continue }

            // Create mid-point node IDs at evenly-spaced geometry indices
            var splitIndices: [Int] = [0]
            for seg in 1..<numSegments {
                let idx = min(seg * stepSize, coords.count - 1)
                if idx != splitIndices.last && idx != coords.count - 1 {
                    splitIndices.append(idx)
                }
            }
            splitIndices.append(coords.count - 1)

            guard splitIndices.count >= 3 else { continue } // need at least one mid-point

            // Create intermediate nodes
            var segmentNodeIds: [String] = [edge.sourceID]
            for i in 1..<(splitIndices.count - 1) {
                let midCoord = coords[splitIndices[i]]
                let coord = Coordinate(lat: midCoord.latitude, lon: midCoord.longitude)
                // Resolution-only nodes are edge scoped. A global coordinate
                // ID here would reconnect unrelated, grade-separated ways.
                let midNodeId = "\(nodeID(for: coord))_split_\(edge.id)_\(splitIndices[i])"

                // Skip if it would merge with source or target
                guard midNodeId != edge.sourceID && midNodeId != edge.targetID else { continue }

                let midEle = elevations[splitIndices[i]]

                if nodes[midNodeId] == nil {
                    nodes[midNodeId] = GraphNode(
                        id: midNodeId,
                        coordinate: midCoord,
                        elevation: midEle,
                        kind: .junction
                    )
                }
                segmentNodeIds.append(midNodeId)
            }
            segmentNodeIds.append(edge.targetID)

            // Remove duplicates (can happen if nodeIDs collide due to rounding)
            var deduped: [String] = []
            for id in segmentNodeIds {
                if deduped.last != id { deduped.append(id) }
            }
            guard deduped.count >= 3 else { continue } // need at least one split

            // Create sub-edges between consecutive segment nodes
            var prevIdx = 0
            for seg in 1..<deduped.count {
                // Find geometry index for this segment node
                let nextIdx: Int
                if seg == deduped.count - 1 {
                    nextIdx = coords.count - 1
                } else {
                    nextIdx = splitIndices[min(seg, splitIndices.count - 1)]
                }

                let geom = Array(coords[prevIdx...min(nextIdx, coords.count - 1)])
                let segLength = polylineLength(geom)
                let srcE = nodes[deduped[seg - 1]]?.elevation ?? 0
                let tgtE = nodes[deduped[seg]]?.elevation ?? 0
                let segDrop = abs(srcE - tgtE)
                let segAvgGrad = segLength > 0 ? atan(segDrop / segLength) * 180 / .pi : 0

                newEdges.append(GraphEdge(
                    id: "\(edge.id)_s\(seg)",
                    sourceID: deduped[seg - 1],
                    targetID: deduped[seg],
                    kind: edge.kind,
                    geometry: geom,
                    attributes: segmentAttributes(
                        from: edge,
                        length: segLength,
                        elevationChange: segDrop,
                        gradient: segAvgGrad,
                        maximumGradient: profileMaximumGradient(geometry: geom,
                            elevations: Array(elevations[prevIdx...nextIdx])),
                        midpointElevation: (srcE + tgtE) / 2
                    )
                ))

                prevIdx = nextIdx
            }

            removeIds.insert(edge.id)
        }

        if !removeIds.isEmpty {
            edges.removeAll { removeIds.contains($0.id) }
            edges.append(contentsOf: newEdges)
            print("[GraphBuilder] Split \(removeIds.count) long edges into \(newEdges.count) segments")
        }
    }

    // MARK: - Trail Intersection Detection

    /// Finds where trail geometries physically cross or pass within proximity,
    /// splits both trails at the crossing point, and creates a shared junction node.
    /// This turns isolated parallel trails into an interconnected web that matches
    /// how skiers actually navigate (turn from one trail onto another mid-run).
    ///
    /// Uses a spatial grid to bucket geometry points by cell, avoiding O(n^2)
    /// pairwise distance checks. Only edges with points in the same or adjacent
    /// grid cells are compared. Nearby intersections within 30m are grouped to
    /// avoid creating multiple junction nodes for the same physical crossing.
    @available(*, unavailable, message: "Trail intersections require curated connection evidence")
    static func detectTrailIntersections(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        proximityThreshold: Double
    ) {
        let runEdges = edges.filter { $0.kind == .run && $0.geometry.count >= 2 }
        guard runEdges.count >= 2 else { return }

        struct Intersection {
            let edgeA: String
            let edgeB: String
            let idxA: Int       // geometry index on edge A
            let idxB: Int       // geometry index on edge B
            let distance: Double
            let coordinate: CLLocationCoordinate2D
            let elevation: Double
        }

        let edgeIndex = Dictionary(uniqueKeysWithValues: runEdges.map { ($0.id, $0) })

        // --- Spatial grid: bucket each edge's geometry points into cells ---
        // Cell size ~50m ensures proximityThreshold (15m) fits within adjacent cells
        let cellSize = 0.0005 // ~55m at equator, ~40m at 45° lat

        // Map: cell key → set of edge IDs that have geometry points in that cell
        var cellToEdges: [String: Set<String>] = [:]
        for edge in runEdges {
            var cellsForEdge = Set<String>()
            for pt in edge.geometry {
                let cellKey = "\(Int(floor(pt.latitude / cellSize)))_\(Int(floor(pt.longitude / cellSize)))"
                cellsForEdge.insert(cellKey)
            }
            for cell in cellsForEdge {
                cellToEdges[cell, default: []].insert(edge.id)
            }
        }

        // Build candidate pairs: only compare edges that share the same or adjacent cells
        var candidatePairs = Set<String>() // "edgeIdA|edgeIdB" where A < B lexically
        for (cellKey, edgeIds) in cellToEdges {
            // Parse cell coordinates
            let parts = cellKey.split(separator: "_")
            guard parts.count == 2,
                  let cellLat = Int(parts[0]),
                  let cellLon = Int(parts[1]) else { continue }

            // Collect edges from this cell and all 8 neighbors
            var nearbyEdges = edgeIds
            for dLat in -1...1 {
                for dLon in -1...1 {
                    if dLat == 0 && dLon == 0 { continue }
                    let neighborKey = "\(cellLat + dLat)_\(cellLon + dLon)"
                    if let neighborEdges = cellToEdges[neighborKey] {
                        nearbyEdges.formUnion(neighborEdges)
                    }
                }
            }

            // Generate pairs from nearby edges
            let sorted = nearbyEdges.sorted()
            for i in 0..<sorted.count {
                for j in (i+1)..<sorted.count {
                    candidatePairs.insert("\(sorted[i])|\(sorted[j])")
                }
            }
        }

        var intersections: [Intersection] = []

        for pairKey in candidatePairs {
            let ids = pairKey.split(separator: "|").map(String.init)
            guard ids.count == 2,
                  let a = edgeIndex[ids[0]],
                  let b = edgeIndex[ids[1]] else { continue }

            // Skip edges that already share a node (already connected)
            if a.sourceID == b.sourceID || a.sourceID == b.targetID ||
               a.targetID == b.sourceID || a.targetID == b.targetID { continue }

            // Find closest point pair between the two geometries
            // Use stride to check every Nth point for performance on large geometries
            let strideA = max(1, a.geometry.count / 50)
            let strideB = max(1, b.geometry.count / 50)

            var bestDist = Double.infinity
            var bestIdxA = 0, bestIdxB = 0

            var idxA = 1  // skip endpoints (they're already nodes)
            while idxA < a.geometry.count - 1 {
                let ptA = a.geometry[idxA]
                var idxB = 1
                while idxB < b.geometry.count - 1 {
                    let ptB = b.geometry[idxB]
                    let dLat = ptA.latitude - ptB.latitude
                    let dLon = ptA.longitude - ptB.longitude
                    let approxM = sqrt(dLat * dLat + dLon * dLon) * 111_000
                    if approxM < bestDist {
                        bestDist = approxM
                        bestIdxA = idxA
                        bestIdxB = idxB
                    }
                    idxB += strideB
                }
                idxA += strideA
            }

            // Refine: check neighbors of best match for exact closest
            if bestDist < proximityThreshold * 3 {
                for da in -2...2 {
                    for db in -2...2 {
                        let ia = max(1, min(a.geometry.count - 2, bestIdxA + da))
                        let ib = max(1, min(b.geometry.count - 2, bestIdxB + db))
                        let ptA = a.geometry[ia]
                        let ptB = b.geometry[ib]
                        let locA = CLLocation(latitude: ptA.latitude, longitude: ptA.longitude)
                        let locB = CLLocation(latitude: ptB.latitude, longitude: ptB.longitude)
                        let dist = locA.distance(from: locB)
                        if dist < bestDist {
                            bestDist = dist
                            bestIdxA = ia
                            bestIdxB = ib
                        }
                    }
                }
            }

            guard bestDist < proximityThreshold else { continue }

            // Compute intersection midpoint
            let ptA = a.geometry[bestIdxA]
            let ptB = b.geometry[bestIdxB]
            let midCoord = CLLocationCoordinate2D(
                latitude: (ptA.latitude + ptB.latitude) / 2,
                longitude: (ptA.longitude + ptB.longitude) / 2
            )

            // Estimate elevation from nearby nodes
            let eleA = nodes[a.sourceID]?.elevation ?? 0
            let eleAEnd = nodes[a.targetID]?.elevation ?? 0
            let fracA = Double(bestIdxA) / Double(max(1, a.geometry.count - 1))
            let midEle = eleA + (eleAEnd - eleA) * fracA

            intersections.append(Intersection(
                edgeA: a.id, edgeB: b.id,
                idxA: bestIdxA, idxB: bestIdxB,
                distance: bestDist,
                coordinate: midCoord,
                elevation: midEle
            ))
        }

        guard !intersections.isEmpty else { return }

        // --- Group nearby intersections within 30m to avoid duplicate junction nodes ---
        // Sort by distance (closest crossings first)
        let sortedAll = intersections.sorted { $0.distance < $1.distance }
        var grouped: [Intersection] = []
        var usedCoords: [(CLLocationCoordinate2D, Double)] = [] // (coord, elevation) of accepted intersections

        let groupingRadius = 30.0
        for ix in sortedAll {
            let ixLoc = CLLocation(latitude: ix.coordinate.latitude, longitude: ix.coordinate.longitude)
            let tooClose = usedCoords.contains { existing in
                let existingLoc = CLLocation(latitude: existing.0.latitude, longitude: existing.0.longitude)
                return ixLoc.distance(from: existingLoc) < groupingRadius
            }
            if !tooClose {
                grouped.append(ix)
                usedCoords.append((ix.coordinate, ix.elevation))
            }
        }

        // Track which edges we've already split to avoid double-splitting
        var edgeSplits: [String: [(idx: Int, junctionId: String)]] = [:]
        var junctionCount = 0

        for ix in grouped {
            // Create junction node at the intersection point
            let coord = Coordinate(lat: ix.coordinate.latitude, lon: ix.coordinate.longitude)
            let junctionId = nodeID(for: coord)

            // Skip if this junction already exists (two intersections at same point)
            if nodes[junctionId] == nil {
                nodes[junctionId] = GraphNode(
                    id: junctionId,
                    coordinate: ix.coordinate,
                    elevation: ix.elevation,
                    kind: .junction
                )
                junctionCount += 1
            }

            edgeSplits[ix.edgeA, default: []].append((ix.idxA, junctionId))
            edgeSplits[ix.edgeB, default: []].append((ix.idxB, junctionId))
        }

        // Split edges at intersection points
        var newEdges: [GraphEdge] = []
        var removedIds = Set<String>()

        for (edgeId, splits) in edgeSplits {
            guard let edge = edgeIndex[edgeId] else { continue }
            guard !removedIds.contains(edgeId) else { continue }

            // Sort splits by geometry index
            let sortedSplits = splits.sorted { $0.idx < $1.idx }

            // Build segment node sequence: source → split1 → split2 → ... → target
            var segNodes: [(id: String, idx: Int)] = [(edge.sourceID, 0)]
            for s in sortedSplits {
                // Skip if junction is same as source/target
                if s.junctionId != edge.sourceID && s.junctionId != edge.targetID {
                    segNodes.append((s.junctionId, s.idx))
                }
            }
            segNodes.append((edge.targetID, edge.geometry.count - 1))

            // Deduplicate consecutive same IDs
            var deduped: [(id: String, idx: Int)] = []
            for sn in segNodes {
                if deduped.last?.id != sn.id { deduped.append(sn) }
            }

            guard deduped.count >= 3 else { continue } // need at least one split

            // Create sub-edges
            for i in 1..<deduped.count {
                let startIdx = deduped[i-1].idx
                let endIdx = deduped[i].idx
                guard endIdx > startIdx else { continue }

                let geom = Array(edge.geometry[startIdx...endIdx])
                let segLength = polylineLength(geom)
                let srcE = nodes[deduped[i-1].id]?.elevation ?? 0
                let tgtE = nodes[deduped[i].id]?.elevation ?? 0
                let segDrop = abs(srcE - tgtE)
                let segAvgGrad = segLength > 0 ? atan(segDrop / segLength) * 180 / .pi : 0
                let segMaxGrad = segAvgGrad

                newEdges.append(GraphEdge(
                    id: "\(edge.id)_ix\(i)",
                    sourceID: deduped[i-1].id,
                    targetID: deduped[i].id,
                    kind: edge.kind,
                    geometry: geom,
                    attributes: EdgeAttributes(
                        difficulty: edge.attributes.difficulty,
                        lengthMeters: segLength,
                        verticalDrop: segDrop,
                        averageGradient: segAvgGrad,
                        maxGradient: segMaxGrad,
                        aspect: edge.attributes.aspect,
                        trailName: edge.attributes.trailName,
                        hasMoguls: edge.attributes.hasMoguls,
                        isGroomed: edge.attributes.isGroomed,
                        isGladed: edge.attributes.isGladed,
                        isOpen: edge.attributes.isOpen
                    )
                ))
            }

            removedIds.insert(edgeId)
        }

        if !removedIds.isEmpty {
            edges.removeAll { removedIds.contains($0.id) }
            edges.append(contentsOf: newEdges)
        }

        print("[GraphBuilder] Detected \(grouped.count) trail intersections, created \(junctionCount) junction nodes")
    }

    // MARK: - Lift-Top → Run Matching

    /// Ensures every lift top node has at least one outgoing run edge.
    /// If a lift top is a dead-end (no runs leave from it), finds the nearest
    /// run start or junction within range and creates a traverse connection.
    /// Also ensures run bottoms connect to nearby lift bases.
    @available(*, unavailable, message: "Lift connections require curated source geometry")
    static func connectLiftTopsToruns(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        maxDistance: Double
    ) {
        // Build outgoing edge lookup
        var outgoing: [String: [GraphEdge]] = [:]
        for edge in edges {
            outgoing[edge.sourceID, default: []].append(edge)
        }

        var liftTopRepairCount = 0
        var runBottomRepairs = 0

        // --- Lift tops: must have outgoing runs ---
        let liftTopNodes = nodes.filter { $0.value.kind == .liftTop }
        for (nodeId, node) in liftTopNodes {
            let hasOutgoingRun = outgoing[nodeId]?.contains { $0.kind == .run } ?? false
            if hasOutgoingRun { continue }

            // Find nearest downhill node with outgoing edges.
            //
            // Hard rule: target must be strictly *below* the lift top. Skiing
            // from a top station is always downhill — attaching to a node
            // that's at or above the lift top creates a synthetic traverse
            // over impassable terrain. Real-world case we hit: Catskinner
            // Express top on Blackcomb had no run way sharing its exact node,
            // and the old `elevDiff < 30` allowed the repair to latch onto
            // the high end of Glacier Road (which is ~15m above), producing
            // a routing hallucination ("ski down Glacier Road") even though
            // that road is only reachable by riding up 7th Heaven first.
            //
            // If nothing below exists within `maxDistance`, we leave the
            // lift top as a dead-end rather than invent a bad edge.
            let minDescentMeters: Double = 5
            var bestTarget: String?
            var bestDist = Double.infinity
            let loc = CLLocation(latitude: node.coordinate.latitude,
                                 longitude: node.coordinate.longitude)

            for (candidateId, candidate) in nodes {
                guard candidateId != nodeId else { continue }
                // Target should have outgoing edges (not another dead-end)
                guard outgoing[candidateId]?.isEmpty == false else { continue }
                // Must be below the lift top by at least `minDescentMeters`.
                guard node.elevation - candidate.elevation >= minDescentMeters else { continue }

                let dist = loc.distance(from: CLLocation(
                    latitude: candidate.coordinate.latitude,
                    longitude: candidate.coordinate.longitude
                ))
                if dist < bestDist && dist < maxDistance {
                    bestDist = dist
                    bestTarget = candidateId
                }
            }

            if let target = bestTarget {
                let targetNode = nodes[target]!
                let geom = [node.coordinate, targetNode.coordinate]
                edges.append(GraphEdge(
                    id: "lt\(nodeId)_\(target)",
                    sourceID: nodeId, targetID: target,
                    kind: .traverse, geometry: geom,
                    attributes: EdgeAttributes(
                        lengthMeters: bestDist,
                        verticalDrop: max(0, targetNode.elevation - node.elevation)
                    )
                ))
                liftTopRepairCount += 1
            }
        }

        // --- Lift bases: must have incoming runs ---
        var incoming: [String: [GraphEdge]] = [:]
        for edge in edges {
            incoming[edge.targetID, default: []].append(edge)
        }

        let liftBaseNodes = nodes.filter { $0.value.kind == .liftBase }
        for (nodeId, node) in liftBaseNodes {
            let hasIncomingRun = incoming[nodeId]?.contains { $0.kind == .run } ?? false
            if hasIncomingRun { continue }

            // Find nearest run endpoint that's at higher elevation (runs end here)
            var bestSource: String?
            var bestDist = Double.infinity
            let loc = CLLocation(latitude: node.coordinate.latitude,
                                 longitude: node.coordinate.longitude)

            for (candidateId, candidate) in nodes {
                guard candidateId != nodeId else { continue }
                // Source should be higher (skier skis down to lift base)
                guard candidate.elevation > node.elevation - 30 else { continue }

                let dist = loc.distance(from: CLLocation(
                    latitude: candidate.coordinate.latitude,
                    longitude: candidate.coordinate.longitude
                ))
                if dist < bestDist && dist < maxDistance {
                    bestDist = dist
                    bestSource = candidateId
                }
            }

            if let source = bestSource {
                let sourceNode = nodes[source]!
                let geom = [sourceNode.coordinate, node.coordinate]
                edges.append(GraphEdge(
                    id: "lb\(source)_\(nodeId)",
                    sourceID: source, targetID: nodeId,
                    kind: .traverse, geometry: geom,
                    attributes: EdgeAttributes(
                        lengthMeters: bestDist,
                        verticalDrop: max(0, node.elevation - sourceNode.elevation)
                    )
                ))
                runBottomRepairs += 1
            }
        }

        let liftTopRepairs = liftTopRepairCount
        print("[GraphBuilder] Repaired \(liftTopRepairs) lift-top dead-ends, \(runBottomRepairs) run-bottom dead-ends")
    }

    /// Semantic priority for node kinds — higher = more important to keep.
    /// Lift stations are fixed infrastructure; junctions/trailEnds are inferred.
    static func kindPriority(_ kind: GraphNode.NodeKind) -> Int {
        switch kind {
        case .liftBase, .liftTop: return 3
        case .midStation:         return 2
        case .trailHead:          return 1
        case .trailEnd, .junction: return 0
        }
    }

    @available(*, unavailable, message: "Nearby nodes must not be merged without curated evidence")
    static func snapNearbyNodes(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        threshold: Double
    ) {
        let nodeList = Array(nodes.values)
        var mergeMap: [String: String] = [:]

        for i in 0..<nodeList.count {
            for j in (i+1)..<nodeList.count {
                let a = CLLocation(latitude: nodeList[i].coordinate.latitude,
                                   longitude: nodeList[i].coordinate.longitude)
                let b = CLLocation(latitude: nodeList[j].coordinate.latitude,
                                   longitude: nodeList[j].coordinate.longitude)
                if a.distance(from: b) < threshold {
                    // Keep the node with the more semantically important kind
                    let priI = kindPriority(nodeList[i].kind)
                    let priJ = kindPriority(nodeList[j].kind)
                    let keep: String
                    let remove: String
                    if priI >= priJ {
                        keep = nodeList[i].id
                        remove = nodeList[j].id
                    } else {
                        keep = nodeList[j].id
                        remove = nodeList[i].id
                    }
                    if mergeMap[remove] == nil && mergeMap[keep] == nil {
                        mergeMap[remove] = keep
                    }
                }
            }
        }

        // Resolve transitive chains: if A→B and B→C, then A→C
        func resolvedId(_ id: String) -> String {
            var current = id
            var seen = Set<String>()
            while let next = mergeMap[current], !seen.contains(next) {
                seen.insert(current)
                current = next
            }
            return current
        }

        // Move surviving nodes to the midpoint of all nodes merged into them
        var mergeGroups: [String: [String]] = [:]  // keepId → [removedIds]
        for (removeID, keepID) in mergeMap {
            let resolved = resolvedId(keepID)
            mergeGroups[resolved, default: []].append(removeID)
        }

        for (keepId, removedIds) in mergeGroups {
            guard let keepNode = nodes[keepId] else { continue }
            // Only adjust position if the surviving node is NOT a lift station
            // (lift stations have precise real-world positions)
            if kindPriority(keepNode.kind) >= 3 { continue }

            var totalLat = keepNode.coordinate.latitude
            var totalLon = keepNode.coordinate.longitude
            var totalEle = keepNode.elevation
            var count = 1.0

            for removeId in removedIds {
                if let removeNode = nodes[removeId] {
                    totalLat += removeNode.coordinate.latitude
                    totalLon += removeNode.coordinate.longitude
                    totalEle += removeNode.elevation
                    count += 1
                }
            }

            nodes[keepId] = GraphNode(
                id: keepId,
                coordinate: CLLocationCoordinate2D(
                    latitude: totalLat / count,
                    longitude: totalLon / count
                ),
                elevation: totalEle / count,
                kind: keepNode.kind
            )
        }

        edges = edges.map { edge in
            let newSource = resolvedId(edge.sourceID)
            let newTarget = resolvedId(edge.targetID)
            guard newSource != edge.sourceID || newTarget != edge.targetID else { return edge }
            return GraphEdge(id: edge.id, sourceID: newSource, targetID: newTarget,
                             kind: edge.kind, geometry: edge.geometry, attributes: edge.attributes)
        }

        // Remove self-loop edges that can occur when source and target merge to same node
        edges.removeAll { $0.sourceID == $0.targetID }

        for (removeID, _) in mergeMap { nodes.removeValue(forKey: removeID) }
    }

}
