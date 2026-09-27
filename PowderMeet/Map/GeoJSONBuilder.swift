//
//  GeoJSONBuilder.swift
//  PowderMeet
//
//  Converts MountainGraph data into GeoJSON FeatureCollections
//  suitable for Mapbox source layers.
//

import Foundation
import CoreLocation

enum GeoJSONBuilder {

    // MARK: - Empty Feature Collection

    /// Returns an empty GeoJSON FeatureCollection (for clearing sources).
    static func emptyFeatureCollection() -> [String: Any] {
        return ["type": "FeatureCollection", "features": [] as [[String: Any]]]
    }

    // MARK: - Trail Lines (Consolidated)

    /// Builds consolidated trail features by merging same-group edges into
    /// single continuous LineStrings. This eliminates OSM's fragmentation
    /// so trails display as clean, single lines on the map.
    static func trailFeatures(from graph: MountainGraph) -> [String: Any] {
        // Group run edges by trailGroupId
        var groupEdges: [String: [GraphEdge]] = [:]
        for edge in graph.runs {
            let gid = edge.attributes.trailGroupId ?? edge.id
            groupEdges[gid, default: []].append(edge)
        }

        var features: [[String: Any]] = []
        for (groupId, edges) in groupEdges {
            let ordered = TrailChainGeometry.orderEdgeChain(edges)
            guard let representative = ordered.first else { continue }
            let rawCoords = TrailChainGeometry.chainGeometryLonLat(ordered, orientingWith: graph)
            let coords = chaikinSmooth(rawCoords)

            // Aggregate properties from all edges in the group
            let totalLength = edges.reduce(0.0) { $0 + $1.attributes.lengthMeters }
            let totalVert = edges.reduce(0.0) { $0 + $1.attributes.verticalDrop }
            let maxGradient = edges.map { $0.attributes.maxGradient }.max() ?? 0
            let avgGradient = totalLength > 0
                ? atan(totalVert / totalLength) * 180 / .pi : 0
            let difficulty = representative.attributes.difficulty?.rawValue ?? "unknown"
            let anyOpen = edges.contains { $0.attributes.isOpen }
            let anyGroomed = edges.contains { $0.attributes.isGroomed == true }
            let anyMoguls = edges.contains { $0.attributes.hasMoguls }
            let anyGladed = edges.contains { $0.attributes.isGladed }
            let edgeIds = edges.map { $0.id }
            let officialRatio = Double(edges.filter(\.attributes.isOfficiallyValidated).count)
                / Double(max(1, edges.count))
            let hasName = representative.attributes.trailName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            let overviewImportance = trailOverviewImportance(
                totalLengthMeters: totalLength,
                totalVerticalMeters: totalVert,
                officialRatio: officialRatio,
                hasName: hasName
            )

            var props: [String: Any] = [
                "id": groupId,
                "edgeIds": edgeIds,
                "difficulty": difficulty,
                "color": colorHex(for: representative.attributes.difficulty),
                "length": totalLength,
                "verticalDrop": totalVert,
                "averageGradient": avgGradient,
                "maxGradient": maxGradient,
                "isGroomed": anyGroomed,
                "hasMoguls": anyMoguls,
                "isGladed": anyGladed,
                "isOpen": anyOpen,
                // At whole-resort zoom this lets the style emphasize the long,
                // defining fall lines and fade short connector fragments. Every
                // trail returns at close zoom; this is visual hierarchy only.
                "overviewImportance": overviewImportance
            ]
            if let name = representative.attributes.trailName {
                props["name"] = name
                // Line labels: include vertical when DEM resolved it (flat segments stay name-only).
                if totalVert >= 8 {
                    props["mapLabel"] = "\(name) · \(Int(totalVert))m"
                } else {
                    props["mapLabel"] = name
                }
            } else if totalVert >= 20 {
                props["mapLabel"] = "\(Int(totalVert))m"
            }

            features.append([
                "type": "Feature",
                "properties": props,
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any])
        }

        return [
            "type": "FeatureCollection",
            "features": features
        ]
    }

    /// Stable 0...1 map-hierarchy signal. It never affects routing or trail
    /// availability; it only prevents hundreds of equally bright short runs
    /// from flattening a mountain-wide view into colored spaghetti.
    static func trailOverviewImportance(
        totalLengthMeters: Double,
        totalVerticalMeters: Double,
        officialRatio: Double,
        hasName: Bool
    ) -> Double {
        let vertical = max(0, min(1, totalVerticalMeters / 300))
        let length = max(0, min(1, totalLengthMeters / 1_500))
        let official = max(0, min(1, officialRatio))
        let score = 0.55 * vertical
            + 0.25 * length
            + 0.15 * official
            + (hasName ? 0.05 : 0)
        return max(0.08, min(1, score))
    }

    /// Public wrapper for chain geometry used by MountainMapView for selection highlighting.
    static func chainGeometryPublic(_ edges: [GraphEdge], graph: MountainGraph) -> [[Double]] {
        TrailChainGeometry.chainGeometryLonLat(
            TrailChainGeometry.orderEdgeChain(edges),
            orientingWith: graph
        )
    }

    // MARK: - Gondolas (Animated)

    /// Sample animated gondola positions along every open lift at a given
    /// phase ∈ [0, 1]. Each lift gets 1–4 evenly-spaced cars depending on
    /// its length; caller ticks `phase` to animate them.
    ///
    /// - Parameter lifts: graph.lifts
    /// - Parameter phase: global cycle position (0…1, wraps)
    static func gondolaFeatures(lifts: [GraphEdge], phase: Double) -> [String: Any] {
        var features: [[String: Any]] = []
        for lift in lifts where lift.attributes.isOpen && lift.geometry.count >= 2 {
            let length = lift.attributes.lengthMeters
            guard length > 100 else { continue }
            let count = min(4, max(1, Int(length / 250)))
            for i in 0..<count {
                let offset = Double(i) / Double(count)
                let t = (phase + offset).truncatingRemainder(dividingBy: 1.0)
                guard let pos = interpolateAlong(
                    coords: lift.geometry, lengthMeters: length, progress: t
                ) else { continue }
                features.append([
                    "type": "Feature",
                    "properties": [
                        "liftId": lift.id,
                        "phase": t
                    ] as [String: Any],
                    "geometry": [
                        "type": "Point",
                        "coordinates": [pos.longitude, pos.latitude]
                    ] as [String: Any]
                ])
            }
        }
        return ["type": "FeatureCollection", "features": features]
    }

    /// Linear interpolation along a polyline by arc-length progress.
    private static func interpolateAlong(
        coords: [CLLocationCoordinate2D],
        lengthMeters: Double,
        progress t: Double
    ) -> CLLocationCoordinate2D? {
        guard coords.count >= 2, lengthMeters > 0 else { return coords.first }
        let target = t * lengthMeters
        var acc: Double = 0
        for i in 0..<coords.count - 1 {
            let a = coords[i]
            let b = coords[i + 1]
            let seg = haversine(
                from: Coordinate(lat: a.latitude, lon: a.longitude),
                to: Coordinate(lat: b.latitude, lon: b.longitude)
            )
            if acc + seg >= target {
                let u = seg > 0 ? (target - acc) / seg : 0
                return CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * u,
                    longitude: a.longitude + (b.longitude - a.longitude) * u
                )
            }
            acc += seg
        }
        return coords.last
    }

    // MARK: - Lift Lines

    static func liftFeatures(from graph: MountainGraph) -> [String: Any] {
        let features: [[String: Any]] = graph.lifts.map { edge in
            let coords: [[Double]] = edge.geometry.map { [$0.longitude, $0.latitude] }

            var props: [String: Any] = [
                "id": edge.attributes.trailGroupId ?? edge.id,
                "liftType": edge.attributes.liftType?.rawValue ?? "unknown",
                "color": HUDTheme.mapboxLiftHex,
                "isOpen": edge.attributes.isOpen
            ]
            if let name = edge.attributes.trailName {
                props["name"] = name
                let v = edge.attributes.verticalDrop
                if v >= 8 {
                    props["mapLabel"] = "\(name) · \(Int(v))m"
                } else {
                    props["mapLabel"] = name
                }
            } else if edge.attributes.verticalDrop >= 15 {
                props["mapLabel"] = "\(Int(edge.attributes.verticalDrop))m"
            }
            return [
                "type": "Feature",
                "properties": props,
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any]
        }
        return [
            "type": "FeatureCollection",
            "features": features
        ]
    }

    // MARK: - Route Overlay

    static func routeFeatures(
        edges: [GraphEdge],
        skierLabel: String,
        colorHex: String,
        graph: MountainGraph? = nil,
        initialEdgeFraction: Double = 0
    ) -> [String: Any] {
        // Keep full canonical edge IDs for validation, but omit the portion of
        // the first edge already travelled when GPS placed the skier inside it.
        // This prevents route overlays from drawing backward to the trail top.
        let firstCoords = edges.first.map {
            TrailChainGeometry.chainGeometryLonLat([$0], orientingWith: graph)
        } ?? []
        let clippedFirst = trimPolylineStart(
            firstCoords,
            fraction: max(0, min(1, initialEdgeFraction))
        )
        let remaining = TrailChainGeometry.chainGeometryLonLat(
            Array(edges.dropFirst()),
            orientingWith: graph
        )
        var rawCoords = clippedFirst
        if let last = rawCoords.last,
           let first = remaining.first,
           abs(last[0] - first[0]) < 1e-6,
           abs(last[1] - first[1]) < 1e-6 {
            rawCoords.append(contentsOf: remaining.dropFirst())
        } else {
            rawCoords.append(contentsOf: remaining)
        }
        let allCoords = chaikinSmooth(rawCoords)

        let features: [[String: Any]] = [
            [
                "type": "Feature",
                "properties": [
                    "skier": skierLabel,
                    "color": colorHex,
                    "edgeCount": edges.count
                ] as [String: Any],
                "geometry": [
                    "type": "LineString",
                    "coordinates": allCoords
                ] as [String: Any]
            ]
        ]
        return [
            "type": "FeatureCollection",
            "features": features
        ]
    }

    // MARK: - Meeting Point

    static func meetingPointFeature(
        node: GraphNode,
        displayName: String? = nil,
        rendezvousPoint: RendezvousPoint? = nil,
        markerVerb: String = "MEET"
    ) -> [String: Any] {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let landmarkName = trimmedName?.isEmpty == false ? trimmedName! : "Meeting Point"
        let kind = rendezvousPoint?.kind ?? {
            switch node.kind {
            case .liftBase: return RendezvousPoint.Kind.liftBase
            case .midStation: return RendezvousPoint.Kind.midStation
            default: return nil
            }
        }()
        return [
            "type": "FeatureCollection",
            "features": [
                [
                    "type": "Feature",
                    "properties": [
                        "id": node.id,
                        "elevation": node.elevation,
                        "mapLabel": "\(markerVerb.uppercased()) · \(landmarkName.uppercased())",
                        "kindLabel": kind?.userFacingLabel ?? "DESIGNATED MEETING POINT",
                        "kind": kind?.rawValue ?? "designated"
                    ] as [String: Any],
                    "geometry": [
                        "type": "Point",
                        "coordinates": [node.coordinate.longitude, node.coordinate.latitude]
                    ] as [String: Any]
                ]
            ]
        ]
    }

    // MARK: - Chaikin Curve Smoothing

    /// Applies Chaikin's corner-cutting algorithm to smooth a polyline.
    /// Each iteration replaces every segment with two new points at 25% and 75%,
    /// preserving the original start and end points.
    private static func chaikinSmooth(_ coords: [[Double]], iterations: Int = 2) -> [[Double]] {
        guard coords.count > 2 else { return coords }
        var result = coords
        for _ in 0..<iterations {
            var smoothed: [[Double]] = [result[0]]  // preserve start
            for i in 0..<(result.count - 1) {
                let p0 = result[i]
                let p1 = result[i + 1]
                let q = [p0[0] * 0.75 + p1[0] * 0.25, p0[1] * 0.75 + p1[1] * 0.25]
                let r = [p0[0] * 0.25 + p1[0] * 0.75, p0[1] * 0.25 + p1[1] * 0.75]
                smoothed.append(q)
                smoothed.append(r)
            }
            smoothed.append(result[result.count - 1])  // preserve end
            result = smoothed
        }
        return result
    }

    /// Removes a distance-weighted prefix from a `[lon, lat]` polyline while
    /// retaining an interpolated vertex at the exact fractional start.
    private static func trimPolylineStart(
        _ coordinates: [[Double]],
        fraction: Double
    ) -> [[Double]] {
        guard coordinates.count > 1, fraction > 0 else { return coordinates }
        if fraction >= 1 { return Array(coordinates.suffix(1)) }

        var lengths: [Double] = []
        lengths.reserveCapacity(coordinates.count - 1)
        var total = 0.0
        for index in 1..<coordinates.count {
            let a = CLLocation(latitude: coordinates[index - 1][1], longitude: coordinates[index - 1][0])
            let b = CLLocation(latitude: coordinates[index][1], longitude: coordinates[index][0])
            let length = a.distance(from: b)
            lengths.append(length)
            total += length
        }
        guard total > 0 else { return coordinates }

        let target = total * fraction
        var consumed = 0.0
        for (index, length) in lengths.enumerated() where length > 0 {
            guard consumed + length >= target else {
                consumed += length
                continue
            }
            let t = (target - consumed) / length
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let start = [
                a[0] + (b[0] - a[0]) * t,
                a[1] + (b[1] - a[1]) * t
            ]
            return [start] + Array(coordinates.dropFirst(index + 1))
        }
        return Array(coordinates.suffix(1))
    }

    // MARK: - User Location Point

    static func userLocationFeature(coordinate: CLLocationCoordinate2D) -> [String: Any] {
        [
            "type": "FeatureCollection",
            "features": [[
                "type": "Feature",
                "properties": ["type": "user"] as [String: Any],
                "geometry": [
                    "type": "Point",
                    "coordinates": [coordinate.longitude, coordinate.latitude]
                ] as [String: Any]
            ]]
        ]
    }

    // MARK: - Friend Location Points

    /// Stale / cold age pill: under 1h = minutes; 1h+ = hours and minutes.
    fileprivate static func friendAgeAgoPillText(totalMinutes: Int) -> String {
        let m = max(0, totalMinutes)
        if m < 60 {
            if m < 1 { return "<1M AGO" }
            return "\(m)M AGO"
        }
        let h = m / 60
        let rem = m % 60
        if rem == 0 { return "\(h)H AGO" }
        return "\(h)H \(rem)M AGO"
    }

    static func friendLocationFeatures(
        friends: [UUID: RealtimeLocationService.FriendLocation],
        graph: MountainGraph? = nil,
        signalQualities: [UUID: FriendSignalQuality] = [:]
    ) -> [String: Any] {
        let now = Date()
        let features: [[String: Any]] = friends.values.compactMap { friend -> [String: Any]? in
            guard FriendSignalClassifier.isVisibleOnMap(lastSeen: friend.capturedAt, now: now) else {
                return nil
            }

            let initials = friend.displayName
                .split(separator: " ")
                .prefix(2)
                .map { String($0.prefix(1)).uppercased() }
                .joined()

            // The node stamp remains useful as a compatibility hint, but the
            // visible dot represents the actual reported fix. Snapping a
            // moving friend to sparse junctions makes them appear to teleport.
            let lon = friend.longitude
            let lat = friend.latitude

            let quality = signalQualities[friend.userId]
                ?? FriendSignalClassifier.classify(lastSeen: friend.capturedAt, now: now)

            let signalState: String
            let signalLabel: String
            let diskOpacity: Double
            switch quality {
            case .live:
                signalState = "live"
                signalLabel = ""
                diskOpacity = 1.0
            case .stale(let mins):
                signalState = "stale"
                signalLabel = friendAgeAgoPillText(totalMinutes: mins)
                diskOpacity = 0.75
            case .cold(let mins):
                signalState = "cold"
                // Past 10 min, prefix the age pill with "LOST SIGNAL ·"
                // so the user reads it as "their phone went silent" not
                // just "haven't checked in a while". 5–10 min cold can
                // still happen with a normal pocket dwell on a long
                // chairlift. ≥10 min is unambiguous.
                signalLabel = mins >= 10
                    ? "LOST SIGNAL · \(friendAgeAgoPillText(totalMinutes: mins))"
                    : friendAgeAgoPillText(totalMinutes: mins)
                diskOpacity = 0.45
            }

            let firstName = friend.displayName
                .split(separator: " ").first
                .map(String.init)?.uppercased() ?? initials

            var props: [String: Any] = [
                "userId": friend.userId.uuidString,
                "displayName": friend.displayName,
                "initials": initials.isEmpty ? "?" : initials,
                "firstName": firstName,
                "signalState": signalState,
                "signalLabel": signalLabel,
                "diskOpacity": diskOpacity,
                // Accuracy halo: only emit a non-zero value when fix is loose
                // enough to be worth showing (≥20 m). Sub-20 m accuracy renders
                // crisp without a fuzzy ring around it.
                "accuracyMeters": (friend.accuracyMeters.map {
                    $0 >= 20 ? min(500, $0) : 0
                }) ?? 0
            ]
            if !signalLabel.isEmpty {
                props["namePill"] = "\(firstName) · \(signalLabel)"
            } else {
                props["namePill"] = firstName
            }

            return [
                "type": "Feature",
                "properties": props,
                "geometry": [
                    "type": "Point",
                    "coordinates": [lon, lat]
                ] as [String: Any]
            ] as [String: Any]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Traverse Edges

    /// Exports traverse edges as LineStrings, merging `trailGroupId` chains like runs.
    static func traverseFeatures(from graph: MountainGraph) -> [String: Any] {
        var groupEdges: [String: [GraphEdge]] = [:]
        for edge in graph.edges where edge.kind == .traverse {
            let gid = edge.attributes.trailGroupId ?? edge.id
            groupEdges[gid, default: []].append(edge)
        }

        var features: [[String: Any]] = []
        for (groupId, edges) in groupEdges {
            let ordered = TrailChainGeometry.orderEdgeChain(edges)
            guard let representative = ordered.first else { continue }
            let rawCoords = TrailChainGeometry.chainGeometryLonLat(ordered, orientingWith: graph)
            let coords = chaikinSmooth(rawCoords)
            let totalLen = edges.reduce(0.0) { $0 + $1.attributes.lengthMeters }
            let totalVert = edges.reduce(0.0) { $0 + $1.attributes.verticalDrop }
            var props: [String: Any] = [
                "id": groupId,
                "edgeIds": edges.map(\.id),
                "length": totalLen,
                "verticalDrop": totalVert
            ]
            if let name = representative.attributes.trailName {
                props["name"] = name
            }
            features.append([
                "type": "Feature",
                "properties": props,
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any])
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Dead-End Nodes

    /// Exports nodes with zero open outgoing edges as Point features.
    static func deadEndNodeFeatures(from graph: MountainGraph) -> [String: Any] {
        let deadEnds = graph.nodes.values.filter { graph.outgoing(from: $0.id).isEmpty }
        let features: [[String: Any]] = deadEnds.map { node in
            [
                "type": "Feature",
                "properties": [
                    "id": node.id,
                    "kind": node.kind.rawValue,
                    "elevation": node.elevation
                ] as [String: Any],
                "geometry": [
                    "type": "Point",
                    "coordinates": [node.coordinate.longitude, node.coordinate.latitude]
                ] as [String: Any]
            ] as [String: Any]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Phantom Trails

    /// Exports closed-because-phantom edges (named but unvalidated) as LineString features.
    static func phantomTrailFeatures(from graph: MountainGraph) -> [String: Any] {
        let phantoms = graph.edges.filter {
            !$0.attributes.isOpen &&
            !$0.attributes.isOfficiallyValidated &&
            $0.attributes.trailName != nil &&
            ($0.kind == .run || $0.kind == .lift)
        }
        let features: [[String: Any]] = phantoms.map { edge in
            let raw = edge.geometry.map { [$0.longitude, $0.latitude] }
            let coords = chaikinSmooth(raw)
            var props: [String: Any] = [
                "id": edge.id,
                "kind": edge.kind.rawValue
            ]
            if let name = edge.attributes.trailName {
                props["name"] = name
            }
            return [
                "type": "Feature",
                "properties": props,
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Operational Closures

    /// Exact validated run/lift segments currently marked closed. These stay
    /// separate from consolidated named-trail features so one open segment
    /// cannot visually erase a closure elsewhere in the same trail group.
    static func closedTerrainFeatures(from graph: MountainGraph) -> [String: Any] {
        let closed = graph.edges.filter {
            !$0.attributes.isOpen
                && $0.attributes.isOfficiallyValidated
                && ($0.kind == .run || $0.kind == .lift)
                && $0.geometry.count >= 2
        }
        let features: [[String: Any]] = closed.map { edge in
            let raw = edge.geometry.map { [$0.longitude, $0.latitude] }
            let coords = edge.kind == .run ? chaikinSmooth(raw) : raw
            let name = edge.attributes.trailName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let closedLabel = name.flatMap { $0.isEmpty ? nil : "CLOSED · \($0)" } ?? "CLOSED"
            return [
                "type": "Feature",
                "properties": [
                    "id": edge.id,
                    "kind": edge.kind.rawValue,
                    "closedLabel": closedLabel
                ] as [String: Any],
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - POI Features

    /// Derives summit, base, and lift-terminus POIs from the graph topology
    /// and elevation data. Summits are the top-N highest-elevation nodes;
    /// bases are the lowest. Lift termini come from lift edge endpoints.
    /// All labels go through `MountainNaming` so the map matches every
    /// other surface — picker, profile HUD, friend cards, route steps.
    static func poiFeatures(from graph: MountainGraph) -> [String: Any] {
        var features: [[String: Any]] = []
        var usedLocations: Set<String> = []
        let naming = MountainNaming(graph)

        func locKey(_ c: CLLocationCoordinate2D) -> String {
            "\(Int(c.latitude * 1e4)),\(Int(c.longitude * 1e4))"
        }

        // Resort overview landmarks: several elevation extremes separated in
        // real space. A single global summit/base made multi-mountain resorts
        // such as Whistler Blackcomb read as one undifferentiated blob.
        let sortedByEle = graph.nodes.values
            .filter { $0.elevation > 0 }
        let summits = separatedElevationLandmarks(
            nodes: Array(sortedByEle),
            descending: true
        )

        for summit in summits {
            let key = locKey(summit.coordinate)
            usedLocations.insert(key)
            features.append(poiFeature(
                coord: summit.coordinate,
                name: naming.nodeLabel(summit.id, style: .canonical).uppercased(),
                type: "summit",
                icon: "triangle.fill",
                elevation: summit.elevation
            ))
        }

        // Base: lowest-elevation node connected to a lift
        let liftNodes = Set(graph.lifts.flatMap { [$0.sourceID, $0.targetID] })
        let baseCandidates = liftNodes.compactMap { graph.nodes[$0] }
            .filter { $0.elevation > 0 }
        let bases = separatedElevationLandmarks(
            nodes: baseCandidates,
            descending: false
        )

        for base in bases {
            let key = locKey(base.coordinate)
            if !usedLocations.contains(key) {
                usedLocations.insert(key)
                features.append(poiFeature(
                    coord: base.coordinate,
                    name: naming.nodeLabel(base.id, style: .canonical).uppercased(),
                    type: "base",
                    icon: "house.fill",
                    elevation: base.elevation
                ))
            }
        }

        // Lift termini: top and bottom of each named lift. The label
        // uses `.withChainPosition` so both endpoints get the lift name
        // plus a "· TOP" / "· BASE" suffix, matching the picker's HUD
        // when the user selects a lift base.
        for lift in graph.lifts {
            guard lift.attributes.trailName != nil else { continue }
            guard let src = graph.nodes[lift.sourceID],
                  let tgt = graph.nodes[lift.targetID] else { continue }

            let top = src.elevation > tgt.elevation ? src : tgt
            let bot = src.elevation > tgt.elevation ? tgt : src
            let topKey = locKey(top.coordinate)
            let botKey = locKey(bot.coordinate)

            if !usedLocations.contains(topKey) {
                usedLocations.insert(topKey)
                features.append(poiFeature(
                    coord: top.coordinate,
                    name: naming.nodeLabel(top.id, style: .withChainPosition).uppercased(),
                    type: "liftTop",
                    icon: "cablecar.fill",
                    elevation: top.elevation
                ))
            }
            if !usedLocations.contains(botKey) {
                usedLocations.insert(botKey)
                features.append(poiFeature(
                    coord: bot.coordinate,
                    name: naming.nodeLabel(bot.id, style: .withChainPosition).uppercased(),
                    type: "liftBase",
                    icon: "cablecar.fill",
                    elevation: bot.elevation
                ))
            }
        }

        return ["type": "FeatureCollection", "features": features]
    }

    /// Deterministic elevation-first landmark selection with geographic
    /// separation. Keeps the overview to a few orienting anchors rather than
    /// promoting every lift terminal into a mountain-wide label.
    static func separatedElevationLandmarks(
        nodes: [GraphNode],
        descending: Bool,
        count: Int = 3,
        minimumDistanceMeters: Double = 1_500
    ) -> [GraphNode] {
        guard count > 0 else { return [] }
        let ordered = nodes.sorted { lhs, rhs in
            if lhs.elevation != rhs.elevation {
                return descending
                    ? lhs.elevation > rhs.elevation
                    : lhs.elevation < rhs.elevation
            }
            return lhs.id < rhs.id
        }
        var selected: [GraphNode] = []
        for candidate in ordered {
            guard selected.allSatisfy({
                haversine(from: $0.coordinate, to: candidate.coordinate)
                    >= minimumDistanceMeters
            }) else { continue }
            selected.append(candidate)
            if selected.count == count { break }
        }
        return selected
    }

    // MARK: - Amenity Features (restaurants, huts, rest stops)

    /// On-mountain amenities fetched by `ResortAmenitiesService` as a
    /// side channel (NOT graph-derived — see that service for why).
    /// Each POIType maps to an SF Symbol the map registers in
    /// `registerSFSymbols`. Unnamed amenities still render their glyph
    /// (a lone restroom marker is useful even without a name).
    static func amenityFeatures(from pois: [PointOfInterest]) -> [String: Any] {
        let features: [[String: Any]] = pois.map { poi in
            [
                "type": "Feature",
                "properties": [
                    "name": (poi.name ?? amenityDefaultName(poi.type)).uppercased(),
                    "poiType": poi.type.rawValue,
                    "icon": amenityIcon(poi.type)
                ] as [String: Any],
                "geometry": [
                    "type": "Point",
                    "coordinates": [poi.coordinate.lon, poi.coordinate.lat]
                ] as [String: Any]
            ]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    /// SF Symbol per amenity type. Registered SDF in
    /// `MountainMapView+Style.registerSFSymbols` so `iconColor` can
    /// retint per type.
    static func amenityIcon(_ type: POIType) -> String {
        switch type {
        case .restaurant: return "fork.knife"
        case .lodge:      return "house.fill"
        case .firstAid:   return "cross.case.fill"
        case .rental:     return "bag.fill"
        case .parking:    return "parkingsign"
        case .restroom:   return "toilet.fill"
        case .station, .summit, .base: return "mappin.circle.fill"
        }
    }

    private static func amenityDefaultName(_ type: POIType) -> String {
        switch type {
        case .restaurant: return "Food"
        case .lodge:      return "Hut"
        case .firstAid:   return "First Aid"
        case .rental:     return "Rental"
        case .parking:    return "Parking"
        case .restroom:   return "Restroom"
        case .station, .summit, .base: return "POI"
        }
    }

    private static func poiFeature(
        coord: CLLocationCoordinate2D,
        name: String,
        type: String,
        icon: String,
        elevation: Double
    ) -> [String: Any] {
        [
            "type": "Feature",
            "properties": [
                "name": name,
                "poiType": type,
                "icon": icon,
                "elevation": Int(elevation)
            ] as [String: Any],
            "geometry": [
                "type": "Point",
                "coordinates": [coord.longitude, coord.latitude]
            ] as [String: Any]
        ]
    }

    // MARK: - Lift Endpoint Features

    static func liftEndpointFeatures(from graph: MountainGraph) -> [String: Any] {
        var features: [[String: Any]] = []
        var usedLocations: Set<String> = []

        func locKey(_ c: CLLocationCoordinate2D) -> String {
            "\(Int(c.latitude * 1e4)),\(Int(c.longitude * 1e4))"
        }

        for lift in graph.lifts {
            guard let src = graph.nodes[lift.sourceID],
                  let tgt = graph.nodes[lift.targetID] else { continue }

            for node in [src, tgt] {
                let key = locKey(node.coordinate)
                guard !usedLocations.contains(key) else { continue }
                usedLocations.insert(key)
                features.append([
                    "type": "Feature",
                    "properties": [
                        "name": lift.attributes.trailName ?? "",
                        "icon": "cablecar.fill"
                    ] as [String: Any],
                    "geometry": [
                        "type": "Point",
                        "coordinates": [node.coordinate.longitude, node.coordinate.latitude]
                    ] as [String: Any]
                ])
            }
        }

        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Sun Exposure Features

    /// Builds trail features annotated with sun exposure at the given time.
    /// Each feature has an `exposure` property (0→shade, 1→full sun) and a
    /// pre-computed `exposureColor` hex for direct use in a Mapbox expression.
    static func sunExposureFeatures(
        from graph: MountainGraph,
        at date: Date,
        resortLatitude: Double,
        resortLongitude: Double?,
        temperatureC: Double,
        cloudCoverPercent: Int
    ) -> [String: Any] {
        var features: [[String: Any]] = []

        var groupEdges: [String: [GraphEdge]] = [:]
        for edge in graph.runs {
            let gid = edge.attributes.trailGroupId ?? edge.id
            groupEdges[gid, default: []].append(edge)
        }

        for (_, edges) in groupEdges {
            let ordered = TrailChainGeometry.orderEdgeChain(edges)
            guard let representative = ordered.first else { continue }
            let rawCoords = TrailChainGeometry.chainGeometryLonLat(ordered, orientingWith: graph)
            let coords = chaikinSmooth(rawCoords)

            let exposure = SunExposureCalculator.exposure(
                for: representative,
                at: date,
                resortLatitude: resortLatitude,
                resortLongitude: resortLongitude,
                temperatureC: temperatureC,
                cloudCoverPercent: cloudCoverPercent
            )

            let hex = exposureColorHex(exposure.exposureFactor)

            features.append([
                "type": "Feature",
                "properties": [
                    "exposure": exposure.exposureFactor,
                    "color": hex,
                    "condition": exposure.snowCondition.rawValue
                ] as [String: Any],
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any])
        }

        return ["type": "FeatureCollection", "features": features]
    }

    /// Maps 0 (full shade) → cool gray, 1 (full sun) → warm amber.
    private static func exposureColorHex(_ t: Double) -> String {
        let clamped = max(0, min(1, t))
        let r = Int(120 + clamped * (255 - 120))
        let g = Int(125 + clamped * (190 - 125))
        let b = Int(140 + clamped * (80 - 140))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Temperature Overlay Features

    /// Builds trail features annotated with estimated temperature at their
    /// elevation, using the environmental lapse rate (~6.5°C / 1000m) from
    /// the base station reading. Cold trails render blue, warm ones amber.
    static func temperatureFeatures(
        from graph: MountainGraph,
        baseTemperatureC: Double,
        baseElevationM: Double
    ) -> [String: Any] {
        let lapseRatePer1000m = 6.5

        var groupEdges: [String: [GraphEdge]] = [:]
        for edge in graph.runs {
            let gid = edge.attributes.trailGroupId ?? edge.id
            groupEdges[gid, default: []].append(edge)
        }

        var features: [[String: Any]] = []
        for (_, edges) in groupEdges {
            let ordered = TrailChainGeometry.orderEdgeChain(edges)
            guard let representative = ordered.first else { continue }
            let rawCoords = TrailChainGeometry.chainGeometryLonLat(ordered, orientingWith: graph)
            let coords = chaikinSmooth(rawCoords)

            let srcEle = graph.nodes[representative.sourceID]?.elevation ?? baseElevationM
            let tgtEle = graph.nodes[representative.targetID]?.elevation ?? baseElevationM
            let avgElevation = (srcEle + tgtEle) / 2
            let tempAtElevation = baseTemperatureC - (avgElevation - baseElevationM) / 1000.0 * lapseRatePer1000m
            let hex = temperatureColorHex(tempAtElevation)

            features.append([
                "type": "Feature",
                "properties": [
                    "temperature": round(tempAtElevation * 10) / 10,
                    "color": hex
                ] as [String: Any],
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ] as [String: Any])
        }

        return ["type": "FeatureCollection", "features": features]
    }

    /// Maps temperature → color: ≤-15°C deep blue, 0°C teal, ≥5°C warm amber.
    private static func temperatureColorHex(_ tempC: Double) -> String {
        let t = max(0, min(1, (tempC + 15) / 20.0))
        let r = Int(40 + t * (255 - 40))
        let g = Int(80 + t * (180 - 80))
        let b = Int(220 - t * (220 - 50))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Helpers

    static func colorHex(for difficulty: RunDifficulty?) -> String {
        guard let d = difficulty else { return "#FFFFFF" }
        return HUDTheme.mapboxHex(for: d)
    }
}
