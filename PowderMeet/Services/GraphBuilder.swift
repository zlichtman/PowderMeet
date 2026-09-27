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
    struct SourceTopology {
        let ownerID: String
        let vertexIDs: [Int64?]
        let elevations: [Double?]
    }

    /// Build a pathfinding graph from resort display data.
    /// Ways join only through exact shared source vertices or explicit
    /// connection geometry; coordinate coincidence is not connectivity.
    static func buildGraph(from resort: ResortData, resortID: String) -> MountainGraph {
        var nodes: [String: GraphNode] = [:]
        var edges: [GraphEdge] = []
        var sourceTopology: [String: SourceTopology] = [:]
        var reverseEntries: [String: String] = [:]

        // MARK: - Process trails → run edges
        for trail in resort.trails {
            guard trail.coordinates.count >= 2 else { continue }

            let startCoord = trail.coordinates.first!
            let endCoord = trail.coordinates.last!
            // Use all coordinate elevations for more accurate vert
            let allElevations = trail.coordinates.compactMap { $0.ele }
            let startEle = startCoord.ele ?? allElevations.first ?? 0
            let endEle = endCoord.ele ?? allElevations.last ?? 0

            let ownerID = "trail:\(trail.id)"
            let startNodeID = sourceEndpointNodeID(
                for: startCoord,
                ownerID: ownerID,
                endpoint: "start"
            )
            let endNodeID = sourceEndpointNodeID(
                for: endCoord,
                ownerID: ownerID,
                endpoint: "end"
            )

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
            let orientedCoordinates = goesDownhill
                ? trail.coordinates
                : Array(trail.coordinates.reversed())
            sourceTopology[edge.id] = SourceTopology(
                ownerID: ownerID,
                vertexIDs: orientedCoordinates.map(\.sourceNodeID),
                elevations: orientedCoordinates.map(\.ele)
            )
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

            let ownerID = "lift:\(lift.id)"
            let baseNodeID = sourceEndpointNodeID(
                for: baseCoord,
                ownerID: ownerID,
                endpoint: "base"
            )
            let topNodeID = sourceEndpointNodeID(
                for: topCoord,
                ownerID: ownerID,
                endpoint: "top"
            )

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
            if lift.isBidirectional == true { reverseEntries[ownerID] = topNodeID }
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
                    chargesLiftWait: true,
                    isOpen: lift.isOpen,
                    midpointElevation: (baseEle + topEle) / 2.0
                )
            )
            edges.append(edge)
            let orientedCoordinates = isReversed
                ? Array(lift.coordinates.reversed())
                : lift.coordinates
            sourceTopology[edge.id] = SourceTopology(
                ownerID: ownerID,
                vertexIDs: orientedCoordinates.map(\.sourceNodeID),
                elevations: orientedCoordinates.map(\.ele)
            )
        }

        // MARK: - Process explicit source connectors → traverse edges
        // A connector is bidirectional walking/traversal geometry supplied by
        // the data source. No straight-line or proximity connector is invented.
        for connection in resort.connections ?? [] {
            guard let startCoord = connection.coordinates.first,
                  let endCoord = connection.coordinates.last,
                  connection.coordinates.count >= 2 else { continue }
            let startEle = startCoord.ele ?? 0
            let endEle = endCoord.ele ?? 0
            let ownerID = "connection:\(connection.id)"
            let startID = sourceEndpointNodeID(
                for: startCoord,
                ownerID: ownerID,
                endpoint: "start"
            )
            let endID = sourceEndpointNodeID(
                for: endCoord,
                ownerID: ownerID,
                endpoint: "end"
            )
            ensureNode(&nodes, id: startID, coord: startCoord, elevation: startEle, kind: .junction)
            ensureNode(&nodes, id: endID, coord: endCoord, elevation: endEle, kind: .junction)

            let forwardGeometry = connection.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }
            let reverseGeometry = Array(forwardGeometry.reversed())
            let length = polylineLength(forwardGeometry)
            let gain = endEle - startEle
            let gradient = length > 0 ? atan(abs(gain) / length) * 180 / .pi : 0
            let commonName = connection.name
            let forwardID = "c\(connection.id)_f"
            let reverseID = "c\(connection.id)_r"
            edges.append(GraphEdge(
                id: forwardID,
                sourceID: startID,
                targetID: endID,
                kind: .traverse,
                geometry: forwardGeometry,
                attributes: EdgeAttributes(
                    lengthMeters: length,
                    verticalDrop: gain,
                    averageGradient: gradient,
                    maxGradient: gradient,
                    trailName: commonName,
                    isOpen: connection.isOpen,
                    midpointElevation: (startEle + endEle) / 2
                )
            ))
            edges.append(GraphEdge(
                id: reverseID,
                sourceID: endID,
                targetID: startID,
                kind: .traverse,
                geometry: reverseGeometry,
                attributes: EdgeAttributes(
                    lengthMeters: length,
                    verticalDrop: -gain,
                    averageGradient: gradient,
                    maxGradient: gradient,
                    trailName: commonName,
                    isOpen: connection.isOpen,
                    midpointElevation: (startEle + endEle) / 2
                )
            ))
            sourceTopology[forwardID] = SourceTopology(
                ownerID: ownerID,
                vertexIDs: connection.coordinates.map(\.sourceNodeID),
                elevations: connection.coordinates.map(\.ele)
            )
            sourceTopology[reverseID] = SourceTopology(
                ownerID: ownerID,
                vertexIDs: connection.coordinates.reversed().map(\.sourceNodeID),
                elevations: connection.coordinates.reversed().map(\.ele)
            )
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

        // Adaptive split length changes graph resolution only; it never creates
        // connectivity that is absent from the source geometry.
        let resortScale = min(1.25, max(0.5, resort.bounds.diagonalMeters / 5000))
        let splitLength = 150.0 * resortScale      // 75m–187m
        print("[GraphBuilder] Resort scale: \(String(format: "%.2f", resortScale)) (diagonal: \(Int(resort.bounds.diagonalMeters))m) → split \(Int(splitLength))m")

        // 1. Materialize only exact shared source vertices, then split long
        //    run geometry for display/progress resolution.
        splitEdgesAtSharedSourceVertices(&nodes, &edges, sourceTopology: &sourceTopology)
        splitLongEdges(&nodes, &edges, maxSegmentLength: splitLength, sourceTopology: sourceTopology)

        // Materialize explicit two-way lift travel after splitting source ways.
        // Each direction retains the same geometry and its own boarding queue.
        var reverseEdges: [GraphEdge] = []
        for edge in edges where edge.kind == .lift {
            guard let owner = sourceTopology[edge.id]?.ownerID,
                  let boarding = reverseEntries[owner] else { continue }
            let a = edge.attributes
            let attributes = segmentAttributes(from: edge, length: a.lengthMeters,
                elevationChange: a.verticalDrop, gradient: a.averageGradient,
                maximumGradient: a.maxGradient, midpointElevation: a.midpointElevation ?? 0,
                liftQueueEntry: edge.targetID == boarding)
            reverseEdges.append(GraphEdge(id: edge.id + "_rev",
                sourceID: edge.targetID, targetID: edge.sourceID, kind: .lift,
                geometry: Array(edge.geometry.reversed()), attributes: attributes))
        }
        edges.append(contentsOf: reverseEdges)

        // Source ways that share the same endpoint already share the same
        // coordinate-derived node ID. We deliberately do not infer turns from
        // nearby/crossing lines, bridge components, connect lift terminals, or
        // manufacture lift-reachability traverses: without curated evidence,
        // those straight lines may cross cliffs, ropes, or grade-separated
        // terrain. Disconnected source topology now fails closed.

        // 2. Diagnose directed dead ends without repairing them.
        repairDirectedDeadEnds(&nodes, &edges)

        // 3. Verify source topology (diagnostic only).
        verifyZeroSinks(nodes, edges)

        // 4. Remove isolated unnamed nodes with 0-1 edges.
        pruneIsolatedNodes(&nodes, &edges)

        // 5. Assign stable trail group IDs for display consolidation.
        assignTrailGroups(&edges, hints: resort.graphBuildHints)

        let graph = MountainGraph(resortID: resortID, nodes: nodes, edges: edges)
        logDiagnostics(graph)
        return graph
    }

    // MARK: - Helpers

    /// Generate a stable node ID from coordinates (rounded to ~1.1m precision).
    /// The explicit snapNearbyNodes() pass handles intentional merging at configurable radius.
    static func nodeID(for coord: Coordinate) -> String {
        let latKey = Int(round(coord.lat * 100000))
        let lonKey = Int(round(coord.lon * 100000))
        return "n\(latKey)_\(lonKey)"
    }

    static func sourceVertexNodeID(_ sourceNodeID: Int64) -> String {
        "src:\(sourceNodeID)"
    }

    static func sourceEndpointNodeID(
        for coordinate: Coordinate,
        ownerID: String,
        endpoint: String
    ) -> String {
        if let sourceNodeID = coordinate.sourceNodeID {
            return sourceVertexNodeID(sourceNodeID)
        }
        // Missing source identity is never permission to merge coincident
        // ways. Scope the fallback to this source owner and endpoint.
        return "local:\(ownerID.count):\(ownerID):\(endpoint):\(nodeID(for: coordinate))"
    }

    /// Default groomed status based on difficulty when OSM tag is absent or generic.
    /// Returns `nil` when the OSM `piste:grooming` tag is absent (unknown);
    /// terrain parks/double-blacks have strong priors worth keeping.
    /// Enrichment (Epic/MtnPowder) is expected to fill in the `nil` cases
    /// when it has real data. Heuristic priors for unknown green/blue/black
    /// are no longer baked in — downstream code handles nil as uncertainty.
    static func defaultGroomed(grooming: String?, difficulty: RunDifficulty?) -> Bool? {
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
    static func detectGladed(name: String) -> Bool {
        let lower = name.lowercased()
        let keywords = ["glade", "glades", "tree", "trees", "wood", "woods", "forest"]
        return keywords.contains { lower.contains($0) }
    }

    static func ensureNode(
        _ nodes: inout [String: GraphNode],
        id: String,
        coord: Coordinate,
        elevation: Double,
        kind: GraphNode.NodeKind
    ) {
        if let existing = nodes[id] {
            let stationKinds: Set<GraphNode.NodeKind> = [.liftBase, .liftTop, .midStation]
            let resolvedKind: GraphNode.NodeKind
            if existing.kind != kind && stationKinds.contains(existing.kind) && stationKinds.contains(kind) {
                // One source vertex can be the top of a lower lift and the
                // base of its upper continuation. Retain both station roles,
                // independent of which lift was parsed first.
                resolvedKind = .midStation
            } else if kindPriority(kind) == kindPriority(existing.kind), kind != existing.kind {
                resolvedKind = .junction
            } else {
                resolvedKind = kindPriority(kind) > kindPriority(existing.kind) ? kind : existing.kind
            }
            guard resolvedKind != existing.kind else { return }
            nodes[id] = GraphNode(
                id: id,
                coordinate: existing.coordinate,
                elevation: elevation != 0 || existing.elevation == 0
                    ? elevation
                    : existing.elevation,
                kind: resolvedKind
            )
            return
        }
        nodes[id] = GraphNode(
            id: id,
            coordinate: CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon),
            elevation: elevation,
            kind: kind
        )
    }

    static func polylineLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total: Double = 0
        for i in 1..<coords.count {
            // Immutable graph identity must use the same pure metric as the
            // source geometry, not platform CLLocation measurement behavior.
            total += haversine(from: coords[i - 1], to: coords[i])
        }
        return total
    }

    static func computeMaxGradient(_ coords: [Coordinate]) -> Double {
        guard coords.count > 1 else { return 0 }
        var maxGrad: Double = 0
        for i in 1..<coords.count {
            // Skip segments with missing elevation — prevents fake 90° slopes
            guard let ele1 = coords[i-1].ele, let ele2 = coords[i].ele else { continue }
            let hDist = haversine(from: coords[i - 1], to: coords[i])
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
    static func computeAspect(
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
        // Normalization can put R just above one for a straight segment.
        let variance = max(0, min(1, 1.0 - R)) // 0 = straight, 1 = switchbacks

        return (meanBearing, variance)
    }

    static func estimateLiftTime(length: Double, type: LiftType) -> Double {
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

}
