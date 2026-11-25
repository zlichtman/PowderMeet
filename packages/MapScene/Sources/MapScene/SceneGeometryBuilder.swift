import Foundation
import MountainCore

extension SceneBuilder {
    /// The static sources for a bundle. Feature order and ids follow the bundle's
    /// own sorted identities, so two builds of the same bundle are identical.
    public static func geometry(for bundle: ResortBundle, skied: [String: Int] = [:]) -> SceneGeometry {
        let graph = bundle.graph
        let mostSkied = bundle.groups.lazy.filter { $0.kind == .trail }
            .compactMap { skied[RunOverlay.skiedKey($0.name)] }.max() ?? 0
        var trails: [SceneFeature] = []
        var lifts: [SceneFeature] = []

        for group in bundle.groups {
            let edges = group.edgeIDs.compactMap(graph.edge).filter { $0.geometry.count >= 2 }
            guard !edges.isEmpty else { continue }
            let length = edges.reduce(0) { $0 + $1.lengthM }
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)

            switch group.kind {
            case .trail:
                let lines = TrailChainGeometry.chains(edges).map { Polyline.chaikinSmooth($0) }
                guard !lines.isEmpty else { continue }
                let drop = max(0, edges.reduce(0) { $0 - $1.verticalM })
                let difficulty = group.difficulty ?? edges.first?.difficulty
                var properties: [String: SceneValue] = [
                    "kind": .string("trail"),
                    "difficulty": .string((difficulty ?? .unknown).rawValue),
                    "color": .string(MapPalette.hex(for: difficulty)),
                    RunOverlay.steepness.colorProperty: .string(RunOverlay.steepnessHex(RunOverlay.pitchDeg(edges))),
                    RunOverlay.aspect.colorProperty: .string(RunOverlay.aspectHex(RunOverlay.aspectDeg(edges))),
                    RunOverlay.skied.colorProperty: .string(RunOverlay.skiedHex(
                        skied[RunOverlay.skiedKey(name)] ?? 0, most: mostSkied)),
                    "length": .number(length),
                    "verticalDrop": .number(drop),
                    "overviewImportance": .number(trailOverviewImportance(
                        totalLengthMeters: length, totalVerticalMeters: drop,
                        officialRatio: group.official ? 1 : 0, hasName: !name.isEmpty)),
                ]
                if !name.isEmpty {
                    properties["name"] = .string(name)
                    properties["mapLabel"] = .string(drop >= 8 ? "\(name) · \(Int(drop))m" : name)
                } else if drop >= 20 {
                    // Short unnamed pieces stay unlabelled so the map stays readable.
                    properties["mapLabel"] = .string(
                        "\(TerrainName.run(nil, difficulty: difficulty)) · \(Int(drop))m")
                }
                trails.append(feature(group.id.rawValue, lines, properties))

            case .lift:
                // Lift lines are straight between towers; smoothing would bend them.
                let lines = TrailChainGeometry.chains(edges)
                guard !lines.isEmpty else { continue }
                let rise = abs(edges.reduce(0) { $0 + $1.verticalM })
                var properties: [String: SceneValue] = [
                    "kind": .string("lift"),
                    "liftType": .string(edges.first?.lift?.type.rawValue ?? "unknown"),
                    "color": .string(MapPalette.lift),
                    "length": .number(length),
                    "verticalDrop": .number(rise),
                ]
                if !name.isEmpty {
                    properties["name"] = .string(name)
                    properties["mapLabel"] = .string(rise >= 8 ? "\(name) · \(Int(rise))m" : name)
                } else if rise >= 15 {
                    properties["mapLabel"] = .string(
                        "\(TerrainName.lift(nil, type: edges.first?.lift?.type)) · \(Int(rise))m")
                }
                lifts.append(feature(group.id.rawValue, lines, properties))
            }
        }

        // Exact segments: the closure overlay draws these, one edge at a time.
        var segments: [SceneFeature] = []
        var connections: [SceneFeature] = []
        var liftEnds: [SceneFeature] = []
        var stationKeys: Set<String> = []
        for edge in graph.edges where edge.geometry.count >= 2 {
            let coordinates = edge.coordinates
            let name = (edge.name ?? edge.group.flatMap(bundle.group)?.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if edge.kind != .connection || edge.group != nil {
                segments.append(SceneFeature(
                    id: edge.id.rawValue,
                    shape: .line(edge.kind == .lift ? coordinates : Polyline.chaikinSmooth(coordinates)),
                    properties: [
                        "kind": .string(edge.kind.rawValue),
                        "closedLabel": .string(name.isEmpty ? "CLOSED" : "CLOSED · \(name)"),
                    ]))
            }
            if edge.kind == .connection {
                var properties: [String: SceneValue] = ["length": .number(edge.lengthM)]
                if !name.isEmpty { properties["name"] = .string(name) }
                connections.append(SceneFeature(
                    id: edge.id.rawValue, shape: .line(Polyline.chaikinSmooth(coordinates)),
                    properties: properties))
            }
            if edge.kind == .lift {
                for id in [edge.from, edge.to] {
                    guard let node = graph.nodes[id] else { continue }
                    let key = "\(Int(node.lat * 1e4)),\(Int(node.lon * 1e4))"
                    guard stationKeys.insert(key).inserted else { continue }
                    liftEnds.append(SceneFeature(
                        id: id.rawValue, shape: .point(node.coordinate),
                        properties: ["name": .string(name), "icon": .string("cablecar.fill")]))
                }
            }
        }

        // Landmarks: the rendezvous catalog. A few, well separated, label the
        // whole-mountain view as summits and bases.
        let places: [(point: Rendezvous, node: Node)] = bundle.rendezvous.compactMap { point in
            graph.nodes[point.nodeID].map { (point, $0) }
        }
        let summits = Set(separatedElevationLandmarks(places.map(\.node), descending: true).map(\.id))
        let bases = Set(separatedElevationLandmarks(
            places.filter { $0.point.kind != .liftTop }.map(\.node), descending: false
        ).map(\.id)).subtracting(summits)

        var landmarks: [SceneFeature] = []
        var beams: [SceneFeature] = []
        for (point, node) in places {
            let name = point.name.uppercased()
            var properties: [String: SceneValue] = [
                "name": .string(name),
                "poiType": .string(point.kind.rawValue),
                "icon": .string(PlaceIcon.icon(kind: point.kind, amenities: point.amenities)),
                "iconPriority": .number(PlaceIcon.priority(kind: point.kind, amenities: point.amenities)),
                "elevation": .number(node.eleM.rounded()),
                "meetLabel": .string("MEET · \(name)"),
            ]
            if summits.contains(node.id) {
                properties["overview"] = .string("summit")
            } else if bases.contains(node.id) {
                properties["overview"] = .string("base")
            }
            landmarks.append(SceneFeature(
                id: point.id.rawValue, shape: .point(node.coordinate), properties: properties))
            beams.append(SceneFeature(
                id: point.id.rawValue, shape: .polygon(beamPolygon(around: node.coordinate))))
        }

        return SceneGeometry(bundleID: bundle.id, skied: skied, sources: [
            SceneSource(id: .trails, features: trails),
            SceneSource(id: .edges, features: segments),
            SceneSource(id: .lifts, features: lifts),
            SceneSource(id: .connections, features: connections),
            SceneSource(id: .liftEnds, features: liftEnds),
            SceneSource(id: .rendezvous, features: landmarks),
            SceneSource(id: .beams, features: beams),
        ])
    }

    /// 0...1 hierarchy for the whole-mountain view: long, tall, official, named
    /// runs stay; short connectors fade. Never affects routing or availability.
    public static func trailOverviewImportance(
        totalLengthMeters: Double, totalVerticalMeters: Double, officialRatio: Double, hasName: Bool
    ) -> Double {
        let vertical = max(0, min(1, totalVerticalMeters / 300))
        let length = max(0, min(1, totalLengthMeters / 1_500))
        let official = max(0, min(1, officialRatio))
        let score = 0.55 * vertical + 0.25 * length + 0.15 * official + (hasName ? 0.05 : 0)
        return max(0.08, min(1, score))
    }

    /// Highest (or lowest) nodes first, skipping any within `minimumDistanceM` of
    /// one already chosen, so a two-mountain resort gets a label on each.
    static func separatedElevationLandmarks(
        _ nodes: [Node], descending: Bool, count: Int = 3, minimumDistanceM: Double = 1_500
    ) -> [Node] {
        let ordered = nodes.sorted { a, b in
            if a.eleM != b.eleM { return descending ? a.eleM > b.eleM : a.eleM < b.eleM }
            return a.id < b.id
        }
        var selected: [Node] = []
        for candidate in ordered where selected.count < count {
            if selected.allSatisfy({
                Geo.haversineM($0.coordinate, candidate.coordinate) >= minimumDistanceM
            }) {
                selected.append(candidate)
            }
        }
        return selected
    }

    /// A 12-sided ring about 3 m across; the adapter extrudes it into the meeting
    /// beam.
    static func beamPolygon(around center: Coordinate) -> [Coordinate] {
        let radiusM = 3.0
        let latPerM = 1.0 / 111_000.0
        let lonPerM = 1.0 / (111_000.0 * max(cos(center.lat * .pi / 180), 0.0001))
        return (0...12).map { i in
            let angle = Double(i % 12) / 12 * 2 * .pi
            return Coordinate(
                lon: center.lon + radiusM * cos(angle) * lonPerM,
                lat: center.lat + radiusM * sin(angle) * latPerM)
        }
    }

    private static func feature(
        _ id: String, _ lines: [[Coordinate]], _ properties: [String: SceneValue]
    ) -> SceneFeature {
        SceneFeature(
            id: id, shape: lines.count == 1 ? .line(lines[0]) : .lines(lines), properties: properties)
    }
}
