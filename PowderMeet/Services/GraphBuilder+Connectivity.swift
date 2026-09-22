//
//  GraphBuilder+Connectivity.swift
//  PowderMeet
//
//  Extension of GraphBuilder — traverse-edge generation, component bridging, dead-end repair, lift reachability, isolated-node pruning.
//  Split out of GraphBuilder.swift (behavior-preserving code motion) so the
//  legacy on-device build pipeline is navigable by stage. File-private helpers
//  were promoted to internal to be visible across these extension files.
//

import Foundation
import CoreLocation

nonisolated extension GraphBuilder {

    /// Maximum uphill elevation gain (meters) allowed for a traverse edge at all.
    /// Anything steeper must use a lift — you can't walk uphill in ski boots.
    /// 30m is the realistic limit for a push/poling traverse; above that the
    /// solver previously emitted routes like "walk uphill 500ft across a bowl"
    /// which is the core artifact that made solver output feel wrong.
    static let maxTraverseElevationGain: Double = 30

    /// Maximum absolute elevation difference that still warrants a bidirectional
    /// traverse. Above this we only generate the downhill direction; poling
    /// 20m uphill is technically possible but biases routing toward it
    /// unnaturally. Bidirectional traverses are reserved for near-flat links.
    static let bidirectionalTraverseGain: Double = 10

    /// Creates elevation-aware traverse edges between nearby nodes that aren't
    /// already connected. Bidirectional only when |gain| ≤ 10m; single-
    /// direction downhill up to the `maxTraverseElevationGain` cap. Uses a
    /// spatial grid so the algorithm stays close to O(n).
    @available(*, unavailable, message: "Routing topology must not infer straight-line traverses")
    static func generateTraverseEdges(
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
    @available(*, unavailable, message: "Disconnected source components must fail closed")
    static func bridgeDisconnectedComponents(
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
    static func findComponents(
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
    static func repairDirectedDeadEnds(
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
    @available(*, unavailable, message: "Lift reachability requires curated source geometry")
    static func ensureLiftReachability(
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
    static func verifyZeroSinks(
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
    static func pruneIsolatedNodes(
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

}
