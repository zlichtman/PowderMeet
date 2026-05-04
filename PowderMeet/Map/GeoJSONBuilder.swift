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
                "isOpen": anyOpen
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
        graph: MountainGraph? = nil
    ) -> [String: Any] {
        // Concatenate all edge geometries into one continuous LineString.
        // Deduplicate shared endpoints so Mapbox line-trim-offset animates smoothly without gaps.
        let rawCoords = TrailChainGeometry.chainGeometryLonLat(edges, orientingWith: graph)
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

    static func meetingPointFeature(node: GraphNode) -> [String: Any] {
        return [
            "type": "FeatureCollection",
            "features": [
                [
                    "type": "Feature",
                    "properties": [
                        "id": node.id,
                        "elevation": node.elevation
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

            let lon: Double
            let lat: Double
            if let nodeId = friend.nearestNodeId,
               let node = graph?.nodes[nodeId] {
                lon = node.coordinate.longitude
                lat = node.coordinate.latitude
            } else {
                lon = friend.longitude
                lat = friend.latitude
            }

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
                signalLabel = friendAgeAgoPillText(totalMinutes: mins)
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
                "accuracyMeters": (friend.accuracyMeters.map { $0 >= 20 ? $0 : 0 }) ?? 0
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

        // Summit: highest-elevation named junction/peak nodes
        let sortedByEle = graph.nodes.values
            .filter { $0.elevation > 0 }
            .sorted { $0.elevation > $1.elevation }

        if let summit = sortedByEle.first {
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
            .sorted { $0.elevation < $1.elevation }

        if let base = baseCandidates.first {
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
