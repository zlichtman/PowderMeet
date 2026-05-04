//
//  GraphDiagnostics.swift
//  PowderMeet
//
//  Automated graph validation that flags likely topology problems
//  without requiring manual truth files for every resort.
//

import Foundation
import CoreLocation

struct GraphDiagnostic: CustomStringConvertible {
    enum Severity: String { case warning, error }
    enum Kind: String {
        case directedSink       // node with zero outgoing edges
        case liftTopNoRuns      // lift top station with no run edges leaving
        case orphanedEndpoint   // trail endpoint >50m from any other node
        case disconnected       // unreachable component
        case liftNoRunsAtTop    // lift exists but no runs leave from its top node
        case unreachableNode    // node in an SCC of size 1 that has in/out edges but no cycle
    }

    let severity: Severity
    let kind: Kind
    let nodeId: String?
    let edgeId: String?
    let detail: String

    var description: String {
        "[\(severity.rawValue.uppercased())] \(kind.rawValue): \(detail)"
    }
}

struct GraphDiagnostics {

    /// Runs all diagnostic checks on a graph and returns a report.
    static func validate(_ graph: MountainGraph) -> [GraphDiagnostic] {
        var issues: [GraphDiagnostic] = []

        issues.append(contentsOf: findDirectedSinks(graph))
        issues.append(contentsOf: findLiftTopsMissingRuns(graph))
        issues.append(contentsOf: findOrphanedEndpoints(graph))
        issues.append(contentsOf: findDisconnectedComponents(graph))
        issues.append(contentsOf: findUnreachableSingletons(graph))

        return issues
    }

    /// Prints a one-line summary; per-issue detail is gated behind
    /// `POWDERMEET_GRAPH_VERBOSE=1` so normal runs stay quiet. The 100-error
    /// dump on every resort load was drowning out useful logs.
    static func printReport(_ graph: MountainGraph) {
        let issues = validate(graph)
        if issues.isEmpty {
            print("[GraphDiagnostics] \(graph.resortID): clean (\(graph.nodes.count)n / \(graph.edges.count)e)")
            return
        }

        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        print("[GraphDiagnostics] \(graph.resortID): \(errors)E / \(warnings)W (\(graph.nodes.count)n / \(graph.edges.count)e)")

        guard ProcessInfo.processInfo.environment["POWDERMEET_GRAPH_VERBOSE"] == "1" else { return }
        for issue in issues.prefix(20) {
            print("  \(issue)")
        }
        if issues.count > 20 {
            print("  ... and \(issues.count - 20) more issues")
        }
    }

    // MARK: - Checks

    /// Nodes Dijkstra can wander into but can't leave: open inbound, no
    /// open outbound. A node with only closed edges (seasonal closures,
    /// phantom-trail removals) is unreachable and harmless — `outgoing()`
    /// already filters to open edges via `MountainGraph._adjacency`, so
    /// without the inbound check we false-flag every closed-only node.
    private static func findDirectedSinks(_ graph: MountainGraph) -> [GraphDiagnostic] {
        var sinks: [GraphDiagnostic] = []
        for (nodeId, node) in graph.nodes {
            let outgoing = graph.outgoing(from: nodeId)
            guard outgoing.isEmpty else { continue }
            let incoming = graph.incoming(to: nodeId)
            guard !incoming.isEmpty else { continue }
            sinks.append(GraphDiagnostic(
                severity: .error,
                kind: .directedSink,
                nodeId: nodeId,
                edgeId: nil,
                detail: "Node \(nodeId) (\(node.kind)) reachable but has no open outgoing edges — routing dead-end"
            ))
        }
        return sinks
    }

    /// Lift top stations with no run edges leaving — skiers can ride up but can't ski down.
    private static func findLiftTopsMissingRuns(_ graph: MountainGraph) -> [GraphDiagnostic] {
        var issues: [GraphDiagnostic] = []

        // Find all lift top nodes
        for edge in graph.edges where edge.kind == .lift && edge.attributes.isOpen {
            let topNodeId = edge.targetID
            let outgoing = graph.outgoing(from: topNodeId)
            let hasRuns = outgoing.contains { $0.kind == .run && $0.attributes.isOpen }
            if !hasRuns {
                let hasTraverses = outgoing.contains { $0.kind == .traverse }
                let severity: GraphDiagnostic.Severity = hasTraverses ? .warning : .error
                issues.append(GraphDiagnostic(
                    severity: severity,
                    kind: .liftTopNoRuns,
                    nodeId: topNodeId,
                    edgeId: edge.id,
                    detail: "Lift \"\(edge.attributes.trailName ?? edge.id)\" top node \(topNodeId) has no open run edges"
                ))
            }
        }

        return issues
    }

    /// Trail endpoints that are >50m from any other node — likely missing merge.
    private static func findOrphanedEndpoints(_ graph: MountainGraph) -> [GraphDiagnostic] {
        var issues: [GraphDiagnostic] = []
        let nodeArray = Array(graph.nodes.values)

        for (nodeId, node) in graph.nodes {
            let outCount = graph.outgoing(from: nodeId).count
            let inCount = graph.incoming(to: nodeId).count

            // Only check endpoints (degree 1) — junctions are fine
            guard outCount + inCount <= 1 else { continue }

            // Find nearest other node
            var minDist = Double.infinity
            for other in nodeArray where other.id != nodeId {
                let dLat = node.coordinate.latitude - other.coordinate.latitude
                let dLon = node.coordinate.longitude - other.coordinate.longitude
                let approxMeters = sqrt(dLat * dLat + dLon * dLon) * 111_000
                minDist = min(minDist, approxMeters)
            }

            if minDist > 50 {
                issues.append(GraphDiagnostic(
                    severity: .warning,
                    kind: .orphanedEndpoint,
                    nodeId: nodeId,
                    edgeId: nil,
                    detail: "Endpoint \(nodeId) is \(Int(minDist))m from nearest node — possible missing merge"
                ))
            }
        }

        return issues
    }

    /// Tarjan's strongly connected components algorithm. Returns components
    /// in reverse topological order (sinks first), each a list of node ids.
    private static func stronglyConnectedComponents(_ graph: MountainGraph) -> [[String]] {
        var index = 0
        var stack: [String] = []
        var onStack = Set<String>()
        var indices: [String: Int] = [:]
        var lowlinks: [String: Int] = [:]
        var components: [[String]] = []

        func strongconnect(_ v: String) {
            indices[v] = index
            lowlinks[v] = index
            index += 1
            stack.append(v)
            onStack.insert(v)

            for edge in graph.outgoing(from: v) {
                let w = edge.targetID
                if indices[w] == nil {
                    strongconnect(w)
                    lowlinks[v] = min(lowlinks[v] ?? Int.max, lowlinks[w] ?? Int.max)
                } else if onStack.contains(w) {
                    lowlinks[v] = min(lowlinks[v] ?? Int.max, indices[w] ?? Int.max)
                }
            }

            if lowlinks[v] == indices[v] {
                var component: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                components.append(component)
            }
        }

        for v in graph.nodes.keys {
            if indices[v] == nil {
                strongconnect(v)
            }
        }
        return components
    }

    /// Reports nodes that sit in a singleton SCC but still have inbound and
    /// outbound edges. These are typically routing cul-de-sacs — you can get
    /// there and you can leave, but you can never return, so round-trip
    /// planning (e.g. meet-up at a mid-mountain location and come back) breaks.
    private static func findUnreachableSingletons(_ graph: MountainGraph) -> [GraphDiagnostic] {
        let sccs = stronglyConnectedComponents(graph)
        var issues: [GraphDiagnostic] = []
        for scc in sccs where scc.count == 1 {
            let nodeId = scc[0]
            let outDeg = graph.outgoing(from: nodeId).count
            let inDeg = graph.incoming(to: nodeId).count
            guard outDeg > 0, inDeg > 0 else { continue }
            // Both edges exist but the node isn't part of any cycle.
            issues.append(GraphDiagnostic(
                severity: .warning,
                kind: .unreachableNode,
                nodeId: nodeId,
                edgeId: nil,
                detail: "Node \(nodeId) is in a singleton SCC with in=\(inDeg)/out=\(outDeg) — unreachable once left"
            ))
        }
        return issues
    }

    /// Finds disconnected components — areas unreachable from the main graph.
    private static func findDisconnectedComponents(_ graph: MountainGraph) -> [GraphDiagnostic] {
        var visited = Set<String>()
        var components: [[String]] = []

        for nodeId in graph.nodes.keys {
            guard !visited.contains(nodeId) else { continue }

            // BFS from this node (treating edges as undirected)
            var queue = [nodeId]
            var component: [String] = []
            var head = 0

            while head < queue.count {
                let current = queue[head]
                head += 1
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                component.append(current)

                // Follow outgoing and incoming edges
                for edge in graph.outgoing(from: current) {
                    if !visited.contains(edge.targetID) { queue.append(edge.targetID) }
                }
                for edge in graph.incoming(to: current) {
                    if !visited.contains(edge.sourceID) { queue.append(edge.sourceID) }
                }
            }

            components.append(component)
        }

        // Sort by size, largest first
        let sorted = components.sorted { $0.count > $1.count }

        var issues: [GraphDiagnostic] = []
        for comp in sorted.dropFirst() where comp.count >= 2 {
            issues.append(GraphDiagnostic(
                severity: .warning,
                kind: .disconnected,
                nodeId: comp.first,
                edgeId: nil,
                detail: "Disconnected component with \(comp.count) nodes (main component has \(sorted[0].count) nodes)"
            ))
        }

        return issues
    }
}
