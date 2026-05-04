//
//  GraphBuilder.swift
//  PowderMeet
//
//  Builds a MountainGraph from ResortData (trails + lifts with coordinates).
//  This eliminates the need for a second Overpass API call — the graph is
//  derived from the same data OverpassService already fetches.
//

import Foundation
import CoreLocation

// `nonisolated` — graph build runs detached, and helpers like
// `normalizedTrailKey` are called from MountainGraph extensions that
// are also nonisolated.
nonisolated enum GraphBuilder {

    /// Build a pathfinding graph from resort display data.
    /// Nodes are created at trail/lift endpoints and merged when within 30m.
    static func buildGraph(from resort: ResortData, resortID: String) -> MountainGraph {
        var nodes: [String: GraphNode] = [:]
        var edges: [GraphEdge] = []

        // MARK: - Process trails → run edges
        for trail in resort.trails {
            guard trail.coordinates.count >= 2 else { continue }

            let startCoord = trail.coordinates.first!
            let endCoord = trail.coordinates.last!
            // Use all coordinate elevations for more accurate vert
            let allElevations = trail.coordinates.compactMap { $0.ele }
            let startEle = startCoord.ele ?? allElevations.first ?? 0
            let endEle = endCoord.ele ?? allElevations.last ?? 0

            let startNodeID = nodeID(for: startCoord)
            let endNodeID = nodeID(for: endCoord)

            ensureNode(&nodes, id: startNodeID, coord: startCoord,
                       elevation: startEle, kind: .trailHead)
            ensureNode(&nodes, id: endNodeID, coord: endCoord,
                       elevation: endEle, kind: .trailEnd)

            // Direction: downhill (higher elevation → lower).
            // When endpoint elevations are equal or both zero, use the
            // max elevation along the coordinate chain to infer direction:
            // the end closer to the highest point is the top.
            let goesDownhill: Bool
            if startEle != endEle {
                goesDownhill = startEle >= endEle
            } else if allElevations.count >= 3,
                      let peakEle = allElevations.max(), peakEle > 0 {
                // Find which end is closer to the peak coordinate
                let peakIdx = allElevations.firstIndex(of: peakEle) ?? 0
                let midpoint = allElevations.count / 2
                // If peak is in first half, start is the top → goesDownhill = true
                goesDownhill = peakIdx <= midpoint
            } else {
                // No elevation data at all — keep OSM order (best guess)
                goesDownhill = true
            }
            let srcID = goesDownhill ? startNodeID : endNodeID
            let tgtID = goesDownhill ? endNodeID : startNodeID

            let clCoords = trail.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }
            let geom = goesDownhill ? clCoords : clCoords.reversed()
            let length = trail.lengthMeters
            // Net elevation change for average gradient (not inflated by undulations)
            let netDrop = abs(startEle - endEle)
            // Use max-min across all coordinates for total vertical drop (terrain profile)
            let maxEle = allElevations.max() ?? startEle
            let minEle = allElevations.min() ?? endEle
            let vDrop = max(netDrop, maxEle - minEle)
            let avgGrad = length > 0 ? atan(netDrop / length) * 180 / .pi : 0
            let maxGrad = computeMaxGradient(trail.coordinates)
            let (aspect, aspectVar) = computeAspect(coords: clCoords)
            let difficulty = trail.difficulty
            let name = trail.name ?? ""

            let edge = GraphEdge(
                id: "t\(trail.id)", sourceID: srcID, targetID: tgtID,
                kind: .run, geometry: geom,
                attributes: EdgeAttributes(
                    difficulty: difficulty, lengthMeters: length,
                    verticalDrop: vDrop, averageGradient: avgGrad,
                    maxGradient: maxGrad, aspect: aspect, aspectVariance: aspectVar,
                    trailName: trail.displayName,
                    hasMoguls: trail.grooming == "mogul",
                    isGroomed: Self.defaultGroomed(grooming: trail.grooming, difficulty: difficulty),
                    isGladed: Self.detectGladed(name: name),
                    isOpen: trail.isOpen,
                    midpointElevation: (startEle + endEle) / 2.0
                )
            )
            edges.append(edge)
        }

        // Run direction audit
        let runEdges = edges.filter { $0.kind == .run }
        let runsWithVert = runEdges.filter { $0.attributes.verticalDrop > 5 }.count
        let flatRuns = runEdges.filter { $0.attributes.verticalDrop <= 5 }.count
        print("[GraphBuilder] Runs: \(runEdges.count) total, \(runsWithVert) with vert, \(flatRuns) flat/unknown direction")

        // MARK: - Process lifts → lift edges
        for lift in resort.lifts {
            guard lift.coordinates.count >= 2 else { continue }

            let rawStartCoord = lift.coordinates.first!
            let rawEndCoord = lift.coordinates.last!
            let liftElevations = lift.coordinates.compactMap { $0.ele }
            let rawStartEle = rawStartCoord.ele ?? liftElevations.first ?? 0
            let rawEndEle = rawEndCoord.ele ?? liftElevations.last ?? 0

            // OSM doesn't guarantee coordinate order — lifts may be digitized
            // top-to-bottom. Always orient base (low) → top (high) so the
            // directed edge points uphill, matching real lift travel.
            // When elevations are equal (e.g. DEM not yet loaded), keep OSM order.
            let isReversed = rawStartEle > rawEndEle && rawStartEle != rawEndEle
            let baseCoord = isReversed ? rawEndCoord : rawStartCoord
            let topCoord = isReversed ? rawStartCoord : rawEndCoord
            let baseEle = isReversed ? rawEndEle : rawStartEle
            let topEle = isReversed ? rawStartEle : rawEndEle

            let baseNodeID = nodeID(for: baseCoord)
            let topNodeID = nodeID(for: topCoord)

            ensureNode(&nodes, id: baseNodeID, coord: baseCoord,
                       elevation: baseEle, kind: .liftBase)
            ensureNode(&nodes, id: topNodeID, coord: topCoord,
                       elevation: topEle, kind: .liftTop)

            let rawClCoords = lift.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }
            let clCoords = isReversed ? rawClCoords.reversed() : rawClCoords
            let length = polylineLength(clCoords)
            let liftMaxEle = liftElevations.max() ?? topEle
            let liftMinEle = liftElevations.min() ?? baseEle
            let vDrop = max(abs(topEle - baseEle), liftMaxEle - liftMinEle)
            let avgGrad = length > 0 ? atan(vDrop / length) * 180 / .pi : 0
            let edge = GraphEdge(
                id: "l\(lift.id)", sourceID: baseNodeID, targetID: topNodeID,
                kind: .lift, geometry: clCoords,
                attributes: EdgeAttributes(
                    lengthMeters: length, verticalDrop: vDrop,
                    averageGradient: avgGrad, maxGradient: avgGrad,
                    trailName: lift.name,
                    liftType: lift.type,
                    liftCapacity: lift.capacity,
                    rideTimeSeconds: estimateLiftTime(length: length, type: lift.type),
                    isOpen: lift.isOpen,
                    midpointElevation: (baseEle + topEle) / 2.0
                )
            )
            edges.append(edge)
        }

        // Lift direction audit
        let liftEdges = edges.filter { $0.kind == .lift }
        let correctDirection = liftEdges.filter { e in
            let srcElev = nodes[e.sourceID]?.elevation ?? 0
            let tgtElev = nodes[e.targetID]?.elevation ?? 0
            return tgtElev >= srcElev  // lift should go up
        }.count
        print("[GraphBuilder] Lifts: \(liftEdges.count) total, \(correctDirection) uphill, \(liftEdges.count - correctDirection) flat/reversed")
        for edge in liftEdges {
            let srcElev = nodes[edge.sourceID]?.elevation ?? 0
            let tgtElev = nodes[edge.targetID]?.elevation ?? 0
            let name = edge.attributes.trailName ?? "unnamed"
            let type = edge.attributes.liftType?.rawValue ?? "?"
            print("[GraphBuilder]   \(name) (\(type)): \(Int(srcElev))m → \(Int(tgtElev))m (\(Int(tgtElev - srcElev))m gain)")
        }

        // Adaptive thresholds based on resort size.
        // Small resorts (Wilmot, ~2km diagonal) get smaller thresholds to avoid false merges.
        // Large resorts (Whistler, ~10km diagonal) get larger thresholds for better connectivity.
        let resortScale = min(1.25, max(0.5, resort.bounds.diagonalMeters / 5000))
        let snapThreshold = 80.0 * resortScale    // 40m–100m
        let splitLength = 150.0 * resortScale      // 75m–187m
        let traverseThreshold = 200.0 * resortScale // 100m–250m
        print("[GraphBuilder] Resort scale: \(String(format: "%.2f", resortScale)) (diagonal: \(Int(resort.bounds.diagonalMeters))m) → snap \(Int(snapThreshold))m, split \(Int(splitLength))m, traverse \(Int(traverseThreshold))m")

        // 1. Split long trail edges to create intermediate junction nodes.
        splitLongEdges(&nodes, &edges, maxSegmentLength: splitLength)

        // 2. Detect trail intersections — where two trails physically cross,
        //    split both and create a shared junction node. This lets skiers
        //    turn from one trail onto another mid-run.
        detectTrailIntersections(&nodes, &edges, proximityThreshold: 15.0)

        // 3. Merge nearby nodes — captures OSM ways that end close
        //    but don't share an actual OSM node ID.
        snapNearbyNodes(&nodes, &edges, threshold: snapThreshold)

        // 4. Connect lift tops to nearby run starts — every lift top MUST
        //    have at least one outgoing run. This is the most common dead-end fix.
        connectLiftTopsToruns(&nodes, &edges, maxDistance: snapThreshold * 2)

        // 5. Generate traverse edges to connect nearby disconnected nodes.
        generateTraverseEdges(&nodes, &edges, threshold: traverseThreshold)

        // 6. Bridge any remaining disconnected components
        bridgeDisconnectedComponents(&nodes, &edges)

        // 7. Repair directed dead-ends using downhill flow analysis.
        repairDirectedDeadEnds(&nodes, &edges)

        // 8. Ensure every connected node can reach a lift base.
        //    Without this, skiers at run bottoms can only go further downhill.
        ensureLiftReachability(&nodes, &edges)

        // 9. Verify repair completeness (diagnostic)
        verifyZeroSinks(nodes, edges)

        // 10. Remove isolated unnamed nodes with 0-1 edges
        pruneIsolatedNodes(&nodes, &edges)

        // 10. Assign trail group IDs for map display consolidation.
        assignTrailGroups(&edges, hints: resort.graphBuildHints)

        let graph = MountainGraph(resortID: resortID, nodes: nodes, edges: edges)
        logDiagnostics(graph)
        return graph
    }

    // MARK: - Helpers

    /// Generate a stable node ID from coordinates (rounded to ~1.1m precision).
    /// The explicit snapNearbyNodes() pass handles intentional merging at configurable radius.
    private static func nodeID(for coord: Coordinate) -> String {
        let latKey = Int(round(coord.lat * 100000))
        let lonKey = Int(round(coord.lon * 100000))
        return "n\(latKey)_\(lonKey)"
    }

    /// Default groomed status based on difficulty when OSM tag is absent or generic.
    /// Returns `nil` when the OSM `piste:grooming` tag is absent (unknown);
    /// terrain parks/double-blacks have strong priors worth keeping.
    /// Enrichment (Epic/MtnPowder) is expected to fill in the `nil` cases
    /// when it has real data. Heuristic priors for unknown green/blue/black
    /// are no longer baked in — downstream code handles nil as uncertainty.
    private static func defaultGroomed(grooming: String?, difficulty: RunDifficulty?) -> Bool? {
        if let g = grooming?.lowercased() {
            if g == "backcountry" || g == "mogul" { return false }
            if g == "classic" || g == "groomed" { return true }
        }
        // No OSM tag — only emit a value for kinds where we have a strong prior.
        switch difficulty {
        case .terrainPark: return true      // parks are always groomed
        case .doubleBlack: return false     // steep expert terrain never groomed
        default:           return nil       // unknown; enrichment or fallback will decide
        }
    }

    /// Detect gladed terrain from trail name — checks multiple keyword variants.
    private static func detectGladed(name: String) -> Bool {
        let lower = name.lowercased()
        let keywords = ["glade", "glades", "tree", "trees", "wood", "woods", "forest"]
        return keywords.contains { lower.contains($0) }
    }

    private static func ensureNode(
        _ nodes: inout [String: GraphNode],
        id: String,
        coord: Coordinate,
        elevation: Double,
        kind: GraphNode.NodeKind
    ) {
        guard nodes[id] == nil else { return }
        nodes[id] = GraphNode(
            id: id,
            coordinate: CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon),
            elevation: elevation,
            kind: kind
        )
    }

    private static func polylineLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        var total: Double = 0
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            total += a.distance(from: b)
        }
        return total
    }

    private static func computeMaxGradient(_ coords: [Coordinate]) -> Double {
        var maxGrad: Double = 0
        for i in 1..<coords.count {
            // Skip segments with missing elevation — prevents fake 90° slopes
            guard let ele1 = coords[i-1].ele, let ele2 = coords[i].ele else { continue }
            let a = CLLocation(latitude: coords[i-1].lat, longitude: coords[i-1].lon)
            let b = CLLocation(latitude: coords[i].lat, longitude: coords[i].lon)
            let hDist = a.distance(from: b)
            let vDist = abs(ele2 - ele1)
            // Require 5m minimum horizontal distance to filter GPS noise
            if hDist > 5 {
                maxGrad = max(maxGrad, atan(vDist / hDist) * 180 / .pi)
            }
        }
        // Cap at 60° — anything steeper is likely data error
        return min(60, maxGrad)
    }

    /// Compute aspect as length-weighted circular mean of per-segment bearings.
    /// Returns (aspect in degrees 0-360, variance 0-1 where 1 = highly variable direction).
    private static func computeAspect(
        coords: [CLLocationCoordinate2D]
    ) -> (aspect: Double, variance: Double) {
        guard coords.count >= 2 else { return (0, 0) }

        var sinSum = 0.0, cosSum = 0.0, totalWeight = 0.0

        for i in 0..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let dlat = b.latitude - a.latitude
            let dlon = b.longitude - a.longitude
            let segLength = sqrt(dlat * dlat + dlon * dlon) * 111_000 // approx meters
            guard segLength > 1 else { continue }

            var bearing = atan2(dlon, dlat) * 180 / .pi
            if bearing < 0 { bearing += 360 }

            let radians = bearing * .pi / 180
            sinSum += sin(radians) * segLength
            cosSum += cos(radians) * segLength
            totalWeight += segLength
        }

        guard totalWeight > 0 else { return (0, 0) }

        sinSum /= totalWeight
        cosSum /= totalWeight

        var meanBearing = atan2(sinSum, cosSum) * 180 / .pi
        if meanBearing < 0 { meanBearing += 360 }

        // R = resultant length (0 = uniform in all directions, 1 = perfectly aligned)
        let R = sqrt(sinSum * sinSum + cosSum * cosSum)
        let variance = 1.0 - R // 0 = straight, 1 = switchbacks

        return (meanBearing, variance)
    }

    private static func estimateLiftTime(length: Double, type: LiftType) -> Double {
        // Speeds sourced from typical lift engineering specs:
        // - Detachable chairlifts / gondolas: 5.0 m/s (Doppelmayr D-Line)
        // - Fixed-grip chairlifts: 2.3 m/s (industry standard)
        // - Cable cars / funiculars: 6.0–12.0 m/s
        // - Surface lifts: 1.0–3.0 m/s
        let speed: Double
        switch type {
        case .cableCar, .funicular:           speed = 8.0   // fastest
        case .gondola:                        speed = 5.0   // detachable
        case .chairLift:                      speed = 2.5   // most are fixed-grip; detachable set via curated data
        case .tBar, .jBar:                    speed = 3.0
        case .platter:                        speed = 2.5
        case .dragLift, .ropeTow:             speed = 2.0
        case .magicCarpet:                    speed = 1.0   // conveyor belt
        default:                              speed = 3.0
        }
        return length / speed
    }

    // MARK: - Split Long Edges

    /// Splits long trail edges into segments, creating intermediate junction
    /// nodes that serve as connection points for traverse edges. This fixes
    /// the common OSM issue where trails pass near each other mid-run but
    /// only have endpoint nodes far apart.
    private static func splitLongEdges(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        maxSegmentLength: Double
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
                let midNodeId = nodeID(for: coord)

                // Skip if it would merge with source or target
                guard midNodeId != edge.sourceID && midNodeId != edge.targetID else { continue }

                // Interpolate elevation proportionally
                let fraction = Double(splitIndices[i]) / Double(coords.count - 1)
                let midEle = srcEle + (tgtEle - srcEle) * fraction

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
                // Use segment's own gradient as max estimate (no per-point elevation data available)
                let segMaxGrad = segAvgGrad

                newEdges.append(GraphEdge(
                    id: "\(edge.id)_s\(seg)",
                    sourceID: deduped[seg - 1],
                    targetID: deduped[seg],
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
    private static func detectTrailIntersections(
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
    private static func connectLiftTopsToruns(
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
    private static func kindPriority(_ kind: GraphNode.NodeKind) -> Int {
        switch kind {
        case .liftBase, .liftTop: return 3
        case .midStation:         return 2
        case .trailHead:          return 1
        case .trailEnd, .junction: return 0
        }
    }

    private static func snapNearbyNodes(
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

    // MARK: - Traverse Edge Generation

    /// Maximum uphill elevation gain (meters) allowed for a traverse edge at all.
    /// Anything steeper must use a lift — you can't walk uphill in ski boots.
    /// 30m is the realistic limit for a push/poling traverse; above that the
    /// solver previously emitted routes like "walk uphill 500ft across a bowl"
    /// which is the core artifact that made solver output feel wrong.
    private static let maxTraverseElevationGain: Double = 30

    /// Maximum absolute elevation difference that still warrants a bidirectional
    /// traverse. Above this we only generate the downhill direction; poling
    /// 20m uphill is technically possible but biases routing toward it
    /// unnaturally. Bidirectional traverses are reserved for near-flat links.
    private static let bidirectionalTraverseGain: Double = 10

    /// Creates elevation-aware traverse edges between nearby nodes that aren't
    /// already connected. Bidirectional only when |gain| ≤ 10m; single-
    /// direction downhill up to the `maxTraverseElevationGain` cap. Uses a
    /// spatial grid so the algorithm stays close to O(n).
    private static func generateTraverseEdges(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge],
        threshold: Double
    ) {
        // Build a set of already-connected node pairs
        var connectedPairs = Set<String>()
        for edge in edges {
            let pair1 = "\(edge.sourceID)->\(edge.targetID)"
            let pair2 = "\(edge.targetID)->\(edge.sourceID)"
            connectedPairs.insert(pair1)
            connectedPairs.insert(pair2)
        }

        // Spatial grid: bucket nodes by lat/lon cells (~100m)
        let cellSize = 0.001 // ~111m at equator, ~80m at 45° latitude
        var grid: [String: [GraphNode]] = [:]
        for node in nodes.values {
            let cellKey = "\(Int(floor(node.coordinate.latitude / cellSize)))_\(Int(floor(node.coordinate.longitude / cellSize)))"
            grid[cellKey, default: []].append(node)
        }

        var traverseCount = 0
        let nodeList = Array(nodes.values)
        for node in nodeList {
            let cellLat = Int(floor(node.coordinate.latitude / cellSize))
            let cellLon = Int(floor(node.coordinate.longitude / cellSize))

            // Check 3x3 grid of neighboring cells
            for dLat in -1...1 {
                for dLon in -1...1 {
                    let neighborKey = "\(cellLat + dLat)_\(cellLon + dLon)"
                    guard let neighbors = grid[neighborKey] else { continue }

                    for neighbor in neighbors {
                        guard neighbor.id != node.id else { continue }

                        let pairKey = "\(node.id)->\(neighbor.id)"
                        guard !connectedPairs.contains(pairKey) else { continue }

                        let a = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
                        let b = CLLocation(latitude: neighbor.coordinate.latitude, longitude: neighbor.coordinate.longitude)
                        let dist = a.distance(from: b)

                        guard dist < threshold else { continue }

                        let elevGain_AB = neighbor.elevation - node.elevation   // positive = uphill A→B
                        let elevGain_BA = node.elevation - neighbor.elevation   // positive = uphill B→A
                        let absGain = abs(elevGain_AB)
                        let geom = [node.coordinate, neighbor.coordinate]

                        // Bidirectional only for near-flat links; otherwise
                        // create only the downhill direction when within cap.
                        let bidirectional = absGain <= bidirectionalTraverseGain
                        let withinCap = absGain <= maxTraverseElevationGain

                        if bidirectional {
                            edges.append(GraphEdge(
                                id: "x\(node.id)_\(neighbor.id)",
                                sourceID: node.id, targetID: neighbor.id,
                                kind: .traverse, geometry: geom,
                                attributes: EdgeAttributes(
                                    lengthMeters: dist, verticalDrop: max(0, elevGain_AB)
                                )
                            ))
                            edges.append(GraphEdge(
                                id: "x\(neighbor.id)_\(node.id)",
                                sourceID: neighbor.id, targetID: node.id,
                                kind: .traverse, geometry: geom.reversed(),
                                attributes: EdgeAttributes(
                                    lengthMeters: dist, verticalDrop: max(0, elevGain_BA)
                                )
                            ))
                            traverseCount += 2
                            connectedPairs.insert("\(node.id)->\(neighbor.id)")
                            connectedPairs.insert("\(neighbor.id)->\(node.id)")
                        } else if withinCap {
                            // Downhill direction only
                            if elevGain_AB < 0 {
                                edges.append(GraphEdge(
                                    id: "x\(node.id)_\(neighbor.id)",
                                    sourceID: node.id, targetID: neighbor.id,
                                    kind: .traverse, geometry: geom,
                                    attributes: EdgeAttributes(lengthMeters: dist, verticalDrop: 0)
                                ))
                                traverseCount += 1
                                connectedPairs.insert("\(node.id)->\(neighbor.id)")
                            } else {
                                edges.append(GraphEdge(
                                    id: "x\(neighbor.id)_\(node.id)",
                                    sourceID: neighbor.id, targetID: node.id,
                                    kind: .traverse, geometry: geom.reversed(),
                                    attributes: EdgeAttributes(lengthMeters: dist, verticalDrop: 0)
                                ))
                                traverseCount += 1
                                connectedPairs.insert("\(neighbor.id)->\(node.id)")
                            }
                        }
                        // |gain| > 30m: no traverse (too steep)
                    }
                }
            }
        }

        print("[GraphBuilder] Generated \(traverseCount) traverse edges connecting \(nodes.count) nodes")
    }

    // MARK: - Component Bridging

    /// Ensures the graph is a single connected component by adding long-range
    /// traverse edges between the closest node pairs of disconnected components.
    private static func bridgeDisconnectedComponents(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge]
    ) {
        var iteration = 0
        while true {
            let components = findComponents(nodes: nodes, edges: edges)
            guard components.count > 1 else {
                if iteration > 0 {
                    print("[GraphBuilder] Bridged to 1 component in \(iteration) iterations")
                }
                return
            }

            // Sort components by size descending — bridge smaller ones to the largest
            let sorted = components.sorted { $0.count > $1.count }
            let mainComponent = Set(sorted[0])

            // Find the closest node in each smaller component to any node in the main component
            for component in sorted.dropFirst() {
                var bestDist = Double.infinity
                var bestA: String?
                var bestB: String?

                for nodeIdSmall in component {
                    guard let nodeSmall = nodes[nodeIdSmall] else { continue }
                    let locSmall = CLLocation(latitude: nodeSmall.coordinate.latitude,
                                              longitude: nodeSmall.coordinate.longitude)

                    for nodeIdMain in mainComponent {
                        guard let nodeMain = nodes[nodeIdMain] else { continue }
                        let locMain = CLLocation(latitude: nodeMain.coordinate.latitude,
                                                 longitude: nodeMain.coordinate.longitude)
                        let dist = locSmall.distance(from: locMain)
                        if dist < bestDist {
                            bestDist = dist
                            bestA = nodeIdSmall
                            bestB = nodeIdMain
                        }
                    }
                }

                guard let a = bestA, let b = bestB,
                      let nodeA = nodes[a], let nodeB = nodes[b] else { continue }

                let geom = [nodeA.coordinate, nodeB.coordinate]
                let elevGain_AB = nodeB.elevation - nodeA.elevation
                let elevGain_BA = nodeA.elevation - nodeB.elevation
                let absGain = abs(elevGain_AB)

                // Apply the same tiered rule as generateTraverseEdges. For
                // bridging we also guarantee at least the downhill edge when
                // the cap is exceeded, so disconnected components don't stay
                // isolated at a cliff.
                if absGain <= bidirectionalTraverseGain {
                    edges.append(GraphEdge(
                        id: "b\(a)_\(b)", sourceID: a, targetID: b,
                        kind: .traverse, geometry: geom,
                        attributes: EdgeAttributes(lengthMeters: bestDist, verticalDrop: max(0, elevGain_AB))
                    ))
                    edges.append(GraphEdge(
                        id: "b\(b)_\(a)", sourceID: b, targetID: a,
                        kind: .traverse, geometry: geom.reversed(),
                        attributes: EdgeAttributes(lengthMeters: bestDist, verticalDrop: max(0, elevGain_BA))
                    ))
                } else if absGain <= maxTraverseElevationGain {
                    // Downhill direction only
                    if nodeA.elevation >= nodeB.elevation {
                        edges.append(GraphEdge(
                            id: "b\(a)_\(b)", sourceID: a, targetID: b,
                            kind: .traverse, geometry: geom,
                            attributes: EdgeAttributes(lengthMeters: bestDist, verticalDrop: 0)
                        ))
                    } else {
                        edges.append(GraphEdge(
                            id: "b\(b)_\(a)", sourceID: b, targetID: a,
                            kind: .traverse, geometry: geom.reversed(),
                            attributes: EdgeAttributes(lengthMeters: bestDist, verticalDrop: 0)
                        ))
                    }
                } else {
                    // Huge cliff — still add the downhill edge so the
                    // component bridges, even though it exceeds the cap.
                    if nodeA.elevation >= nodeB.elevation {
                        edges.append(GraphEdge(
                            id: "b\(a)_\(b)", sourceID: a, targetID: b,
                            kind: .traverse, geometry: geom,
                            attributes: EdgeAttributes(lengthMeters: bestDist, verticalDrop: 0)
                        ))
                    } else {
                        edges.append(GraphEdge(
                            id: "b\(b)_\(a)", sourceID: b, targetID: a,
                            kind: .traverse, geometry: geom.reversed(),
                            attributes: EdgeAttributes(lengthMeters: bestDist, verticalDrop: 0)
                        ))
                    }
                }
            }

            iteration += 1
            // Safety: don't loop forever
            if iteration > 50 { break }
        }
    }

    /// Find connected components treating all edges as undirected.
    private static func findComponents(
        nodes: [String: GraphNode],
        edges: [GraphEdge]
    ) -> [[String]] {
        // Build undirected adjacency
        var adj: [String: [String]] = [:]
        for edge in edges {
            adj[edge.sourceID, default: []].append(edge.targetID)
            adj[edge.targetID, default: []].append(edge.sourceID)
        }

        var visited = Set<String>()
        var components: [[String]] = []

        for nodeId in nodes.keys {
            guard !visited.contains(nodeId) else { continue }
            var component: [String] = []
            var queue = [nodeId]
            visited.insert(nodeId)
            while !queue.isEmpty {
                let current = queue.removeFirst()
                component.append(current)
                for neighbor in adj[current] ?? [] {
                    guard !visited.contains(neighbor) else { continue }
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            components.append(component)
        }

        return components
    }

    // MARK: - Directed Dead-End Repair

    /// Identifies nodes with zero outgoing edges (directed sinks) and logs
    /// them. Previously this would fabricate long traverses (up to 3km, no
    /// elevation limit) to "repair" orphans — that hid garbage routes from
    /// the solver. Better to leave the sinks unreachable and let
    /// `GraphDiagnostics` + the solver's `findEscapeNode` surface the real
    /// problem rather than route someone across a bowl.
    private static func repairDirectedDeadEnds(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge]
    ) {
        var outCount: [String: Int] = [:]
        for edge in edges {
            outCount[edge.sourceID, default: 0] += 1
        }
        let sinks = nodes.keys.filter { outCount[$0, default: 0] == 0 }
        if sinks.isEmpty {
            print("[GraphBuilder] No directed dead-ends found")
            return
        }
        print("[GraphBuilder] WARNING: \(sinks.count) directed dead-end nodes (no outgoing edges). Marking as non-skiable; solver will route around them.")
        if sinks.count <= 10 {
            for id in sinks { print("[GraphBuilder]   sink: \(id)") }
        }
    }

    // MARK: - Lift Reachability

    /// Ensures every node with outgoing edges can reach at least one lift base
    /// within a bounded BFS. Nodes that can't reach any lift are "lift-stranded" —
    /// the solver would route them all the way to the base. Fix by adding a
    /// traverse to the nearest lift base.
    private static func ensureLiftReachability(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge]
    ) {
        // Build outgoing adjacency
        var outgoing: [String: [GraphEdge]] = [:]
        for edge in edges { outgoing[edge.sourceID, default: []].append(edge) }

        let liftBaseIds = Set(nodes.filter { $0.value.kind == .liftBase }.keys)
        guard !liftBaseIds.isEmpty else {
            print("[GraphBuilder] No lift bases in graph — skipping lift reachability check")
            return
        }

        // BFS from each node: can it reach a lift base within 8 hops?
        let maxHops = 8
        var stranded: [String] = []

        for nodeId in nodes.keys {
            guard outgoing[nodeId]?.isEmpty == false else { continue }

            var visited = Set<String>()
            var queue = [(nodeId, 0)]
            visited.insert(nodeId)
            var foundLift = false

            while !queue.isEmpty && !foundLift {
                let (current, depth) = queue.removeFirst()
                if liftBaseIds.contains(current) { foundLift = true; break }
                guard depth < maxHops else { continue }
                for edge in outgoing[current] ?? [] {
                    guard !visited.contains(edge.targetID) else { continue }
                    visited.insert(edge.targetID)
                    queue.append((edge.targetID, depth + 1))
                }
            }

            if !foundLift { stranded.append(nodeId) }
        }

        guard !stranded.isEmpty else {
            print("[GraphBuilder] ✓ All nodes can reach a lift base within \(maxHops) hops")
            return
        }
        print("[GraphBuilder] \(stranded.count) nodes can't reach a lift base — adding traverse links")

        var repaired = 0
        for nodeId in stranded {
            guard let node = nodes[nodeId] else { continue }
            let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)

            // Find nearest lift base
            var bestDist = Double.infinity
            var bestId: String?
            for lbId in liftBaseIds {
                guard let lb = nodes[lbId] else { continue }
                let lbLoc = CLLocation(latitude: lb.coordinate.latitude, longitude: lb.coordinate.longitude)
                let d = loc.distance(from: lbLoc)
                if d < bestDist { bestDist = d; bestId = lbId }
            }

            // Connect if within 2km (reasonable ski resort scale)
            guard let targetId = bestId, bestDist < 2000, let targetNode = nodes[targetId] else { continue }

            let geom = [node.coordinate, targetNode.coordinate]
            let elevGain = max(0, targetNode.elevation - node.elevation)
            edges.append(GraphEdge(
                id: "lr\(nodeId)_\(targetId)", sourceID: nodeId, targetID: targetId,
                kind: .traverse, geometry: geom,
                attributes: EdgeAttributes(
                    lengthMeters: bestDist,
                    verticalDrop: elevGain
                )
            ))
            repaired += 1
        }
        print("[GraphBuilder] Added \(repaired) lift-reachability traverses")
    }

    /// Logs remaining directed sinks after repair for debugging.
    /// Call between repairDirectedDeadEnds and pruneIsolatedNodes.
    private static func verifyZeroSinks(
        _ nodes: [String: GraphNode],
        _ edges: [GraphEdge]
    ) {
        var outCount: [String: Int] = [:]
        for edge in edges {
            outCount[edge.sourceID, default: 0] += 1
        }
        let sinks = nodes.keys.filter { outCount[$0, default: 0] == 0 }
        if sinks.isEmpty {
            print("[GraphBuilder] ✓ Zero directed sinks — graph is fully connected")
        } else {
            print("[GraphBuilder] ⚠️ \(sinks.count) directed sinks remain after repair:")
            for sinkId in sinks.prefix(10) {
                if let node = nodes[sinkId] {
                    print("  → \(sinkId) at (\(node.coordinate.latitude), \(node.coordinate.longitude)) ele=\(Int(node.elevation))m kind=\(node.kind.rawValue)")
                }
            }
            if sinks.count > 10 {
                print("  ... and \(sinks.count - 10) more")
            }
        }
    }

    // MARK: - Prune Isolated Nodes

    /// Remove isolated nodes that have 0-1 total edges (in+out) and aren't on named trails.
    /// These are typically service road endpoints or GPS noise from OSM.
    private static func pruneIsolatedNodes(
        _ nodes: inout [String: GraphNode],
        _ edges: inout [GraphEdge]
    ) {
        var edgeCount: [String: Int] = [:]
        for edge in edges {
            edgeCount[edge.sourceID, default: 0] += 1
            edgeCount[edge.targetID, default: 0] += 1
        }

        // Nodes on named trails/lifts should be kept even if low connectivity
        let namedNodeIds = Set(edges.filter { $0.attributes.trailName != nil }
            .flatMap { [$0.sourceID, $0.targetID] })

        var pruneIds: Set<String> = []
        for nodeId in nodes.keys {
            let count = edgeCount[nodeId, default: 0]
            if count <= 1 && !namedNodeIds.contains(nodeId) {
                pruneIds.insert(nodeId)
            }
        }

        if !pruneIds.isEmpty {
            nodes = nodes.filter { !pruneIds.contains($0.key) }
            edges.removeAll { pruneIds.contains($0.sourceID) || pruneIds.contains($0.targetID) }
            print("[GraphBuilder] Pruned \(pruneIds.count) isolated unnamed nodes")
        }
    }

    // MARK: - Trail Group Assignment

    /// Aggressive trail-name normalization so minor OSM inconsistencies
    /// (punctuation, casing, extra whitespace, accents) don't split a single
    /// logical trail into multiple groups. "Peak to Creek", "Peak-to-Creek",
    /// "Peak To Creek " all hash to the same key.
    /// Same normalization used when assigning `trailGroupId` during graph build.
    static func normalizedTrailKey(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let collapsed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let trimmed = String(collapsed).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return trimmed
    }

    /// Groups edges that share the same normalized trail name, same difficulty,
    /// and are connected via shared nodes into a single logical trail.
    /// Each group gets a unique `trailGroupId` written into EdgeAttributes.
    ///
    /// This solves OSM's fragmentation: one trail stored as 5 separate ways
    /// becomes one visual line on the map.
    private static func assignTrailGroups(_ edges: inout [GraphEdge], hints: ResortGraphBuildHints? = nil) {
        let mergeNamedTraverses = hints?.mergeNamedTraverseGroups ?? true

        // Build index: (normalizedName, difficulty or "traverse") → [edge indices]
        var keyToIndices: [String: [Int]] = [:]
        for (i, edge) in edges.enumerated() {
            guard let name = edge.attributes.trailName, !name.isEmpty else { continue }
            let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
            if lower.hasPrefix("unnamed") { continue }

            switch edge.kind {
            case .run, .lift:
                let normName = normalizedTrailKey(name)
                let diffKey = edge.attributes.difficulty?.rawValue ?? "none"
                let key = "\(normName)|\(diffKey)"
                keyToIndices[key, default: []].append(i)
            case .traverse where mergeNamedTraverses:
                let normName = normalizedTrailKey(name)
                let key = "\(normName)|traverse"
                keyToIndices[key, default: []].append(i)
            default:
                break
            }
        }

        // For each group of same-name/difficulty edges, use union-find
        // to merge those connected via shared nodes into trail groups.
        var groupCounter = 0

        for (_, indices) in keyToIndices {
            guard indices.count >= 1 else { continue }

            if indices.count == 1 {
                // Single edge — give it its own group
                let idx = indices[0]
                var attrs = edges[idx].attributes
                attrs.trailGroupId = "tg\(groupCounter)"
                edges[idx] = GraphEdge(
                    id: edges[idx].id, sourceID: edges[idx].sourceID,
                    targetID: edges[idx].targetID, kind: edges[idx].kind,
                    geometry: edges[idx].geometry, attributes: attrs
                )
                groupCounter += 1
                continue
            }

            // Union-Find for this set of edges
            var parent = Array(0..<indices.count)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x {
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                }
                return x
            }
            func union(_ a: Int, _ b: Int) {
                let ra = find(a), rb = find(b)
                if ra != rb { parent[ra] = rb }
            }

            // Build node→local-index map: which local edges touch each node
            var nodeToLocal: [String: [Int]] = [:]
            for (localIdx, edgeIdx) in indices.enumerated() {
                let e = edges[edgeIdx]
                nodeToLocal[e.sourceID, default: []].append(localIdx)
                nodeToLocal[e.targetID, default: []].append(localIdx)
            }

            // Union edges sharing a node
            for (_, locals) in nodeToLocal {
                for j in 1..<locals.count {
                    union(locals[0], locals[j])
                }
            }

            // Collect components and assign group IDs
            var componentEdges: [Int: [Int]] = [:]
            for localIdx in 0..<indices.count {
                componentEdges[find(localIdx), default: []].append(indices[localIdx])
            }
            for (_, edgeIndices) in componentEdges {
                let gid = "tg\(groupCounter)"
                for idx in edgeIndices {
                    var attrs = edges[idx].attributes
                    attrs.trailGroupId = gid
                    edges[idx] = GraphEdge(
                        id: edges[idx].id, sourceID: edges[idx].sourceID,
                        targetID: edges[idx].targetID, kind: edges[idx].kind,
                        geometry: edges[idx].geometry, attributes: attrs
                    )
                }
                groupCounter += 1
            }
        }

        // Assign groups to remaining ungrouped runs and lifts (one id each).
        for i in 0..<edges.count {
            guard edges[i].attributes.trailGroupId == nil else { continue }
            guard edges[i].kind == .run || edges[i].kind == .lift else { continue }
            var attrs = edges[i].attributes
            attrs.trailGroupId = "tg\(groupCounter)"
            edges[i] = GraphEdge(
                id: edges[i].id, sourceID: edges[i].sourceID,
                targetID: edges[i].targetID, kind: edges[i].kind,
                geometry: edges[i].geometry, attributes: attrs
            )
            groupCounter += 1
        }

        // Unnamed traverse micro-segments: one trailGroupId per connected component.
        mergeUnnamedTraverseChainComponents(&edges, groupCounter: &groupCounter)

        let groupedRuns = edges.filter { $0.kind == .run && $0.attributes.trailGroupId != nil }
        let uniqueGroups = Set(groupedRuns.compactMap { $0.attributes.trailGroupId })
        print("[GraphBuilder] Assigned \(groupedRuns.count) run edges to \(uniqueGroups.count) trail groups")
    }

    /// Groups unnamed `traverse` edges that share nodes into single `trailGroupId`s.
    private static func mergeUnnamedTraverseChainComponents(_ edges: inout [GraphEdge], groupCounter: inout Int) {
        let pending = edges.enumerated().compactMap { i, e -> Int? in
            guard e.kind == .traverse, e.attributes.trailGroupId == nil else { return nil }
            return i
        }
        guard !pending.isEmpty else { return }

        var parent: [Int: Int] = [:]
        for i in pending { parent[i] = i }
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x]! != x {
                parent[x] = parent[parent[x]!]!
                x = parent[x]!
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var nodeToIdx: [String: [Int]] = [:]
        for i in pending {
            let e = edges[i]
            nodeToIdx[e.sourceID, default: []].append(i)
            nodeToIdx[e.targetID, default: []].append(i)
        }
        for (_, arr) in nodeToIdx {
            for j in 1..<arr.count {
                union(arr[0], arr[j])
            }
        }

        var components: [Int: [Int]] = [:]
        for i in pending {
            components[find(i), default: []].append(i)
        }
        for (_, idxs) in components {
            let gid = "tg\(groupCounter)"
            groupCounter += 1
            for idx in idxs {
                var attrs = edges[idx].attributes
                attrs.trailGroupId = gid
                edges[idx] = GraphEdge(
                    id: edges[idx].id, sourceID: edges[idx].sourceID,
                    targetID: edges[idx].targetID, kind: edges[idx].kind,
                    geometry: edges[idx].geometry, attributes: attrs
                )
            }
        }
    }

    // MARK: - Diagnostics

    /// Log graph health metrics for debugging.
    static func logDiagnostics(_ graph: MountainGraph) {
        var outCount: [String: Int] = [:]
        for edge in graph.edges {
            outCount[edge.sourceID, default: 0] += 1
        }

        let sinks = graph.nodes.keys.filter { outCount[$0, default: 0] == 0 }.count

        var totalEdgeCount: [String: Int] = [:]
        for edge in graph.edges {
            totalEdgeCount[edge.sourceID, default: 0] += 1
            totalEdgeCount[edge.targetID, default: 0] += 1
        }
        let deadEnds = graph.nodes.keys.filter { totalEdgeCount[$0, default: 0] <= 1 }.count

        let namedRuns = Set(graph.runs.compactMap { $0.attributes.trailName }).count
        let namedLifts = Set(graph.lifts.compactMap { $0.attributes.trailName }).count

        // Elevation health
        let runsWithVert = graph.runs.filter { $0.attributes.verticalDrop > 0 }.count
        let liftsWithVert = graph.lifts.filter { $0.attributes.verticalDrop > 0 }.count
        let nodesWithElev = graph.nodes.values.filter { $0.elevation > 0 }.count
        let maxVert = graph.edges.map { $0.attributes.verticalDrop }.max() ?? 0

        print("""
        [GraphDiag] Nodes: \(graph.nodes.count), Edges: \(graph.edges.count)
        [GraphDiag] Runs: \(graph.runs.count) (\(namedRuns) named), Lifts: \(graph.lifts.count) (\(namedLifts) named)
        [GraphDiag] Directed sinks (no outgoing): \(sinks)
        [GraphDiag] Dead ends (≤1 total edge): \(deadEnds)
        [GraphDiag] Elevation: \(nodesWithElev)/\(graph.nodes.count) nodes with elev, runs w/vert: \(runsWithVert)/\(graph.runs.count), lifts w/vert: \(liftsWithVert)/\(graph.lifts.count), max vert: \(Int(maxVert))m
        """)
    }
}
