//
//  OverpassService.swift
//  PowderMeet
//

import Foundation

// MARK: - Raw OSM Response Types

struct OverpassResponse: Sendable {
    let elements: [OSMElement]
}

// Explicit nonisolated Decodable so decoding inside the
// OverpassService actor doesn't trigger isolation warnings.
extension OverpassResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case elements }
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        elements = try container.decode([OSMElement].self, forKey: .elements)
    }
}

struct OSMElement: Decodable, Sendable {
    let type: String           // "node", "way", "relation"
    let id: Int64
    let lat: Double?
    let lon: Double?
    let tags: [String: String]?
    let nodes: [Int64]?        // for ways
    let members: [OSMMember]?  // for relations
}

struct OSMMember: Decodable, Sendable {
    let type: String
    let ref: Int64
    let role: String?
}

// MARK: - Overpass Service

actor OverpassService {
    private let baseURL = "https://overpass-api.de/api/interpreter"
    private let session = URLSession.shared

    // MARK: - Main fetch entry point

    func fetchResortData(entry: ResortEntry) async throws -> ResortData {
        let json = try await fetchRaw(bounds: entry.bounds)
        var data = parseResortData(from: json, name: entry.name, bounds: entry.bounds)
        // OSM nodes almost never carry `ele` tags, so vertical drop would always be 0.
        // Backfill trail/lift endpoint elevations from Open-Meteo's DEM before returning.
        data = await backfillElevation(in: data, country: entry.country)
        return data
    }

    // MARK: - HTTP Fetch

    private func fetchRaw(bounds: BoundingBox) async throws -> OverpassResponse {
        let bbox = bounds.overpassBBox
        let query = """
        [out:json][timeout:90];
        (
          way["piste:type"="downhill"](\(bbox));
          way["aerialway"](\(bbox));
          node["aerialway"="station"](\(bbox));
        );
        out body;
        >;
        out qt;
        """

        guard let url = URL(string: baseURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 100)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
        request.httpBody = body.data(using: .utf8)

        let (responseData, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(OverpassResponse.self, from: responseData)
    }

    // MARK: - Parse OSM → ResortData

    private func parseResortData(from response: OverpassResponse, name: String, bounds: BoundingBox) -> ResortData {
        // Build node lookup: id → (lat, lon, ele)
        var nodeMap: [Int64: Coordinate] = [:]
        for element in response.elements where element.type == "node" {
            guard let lat = element.lat, let lon = element.lon else { continue }
            let ele = element.tags?["ele"].flatMap { Double($0) }
            nodeMap[element.id] = Coordinate(lat: lat, lon: lon, ele: ele)
        }

        var trails: [Trail] = []
        var trailNodeIds: [[Int64]] = []   // parallel array: OSM node IDs per trail
        var lifts: [Lift] = []
        var pois: [PointOfInterest] = []

        for element in response.elements where element.type == "way" {
            let tags = element.tags ?? [:]
            guard let nodeIds = element.nodes, nodeIds.count >= 2 else { continue }

            let coords = nodeIds.compactMap { nodeMap[$0] }
            guard coords.count >= 2 else { continue }

            if let pisteType = tags["piste:type"] {
                // It's a ski run (downhill only — no nordic/cross-country)
                if pisteType == "downhill" {
                    let trail = Trail(
                        id: element.id,
                        name: tags["name"] ?? tags["piste:name"],
                        difficulty: RunDifficulty.fromOSM(tags["piste:difficulty"]),
                        grooming: tags["piste:grooming"],
                        coordinates: interpolateElevation(in: coords),
                        lit: tags["piste:lit"] == "yes",
                        ref: tags["piste:ref"] ?? tags["ref"],
                        isOpen: tags["piste:status"] != "closed"
                    )
                    trails.append(trail)
                    trailNodeIds.append(nodeIds)
                }
            } else if let aerialwayType = tags["aerialway"] {
                // Skip stations and other non-line aerialway types
                let skipTypes = ["station", "zip_line"]
                guard !skipTypes.contains(aerialwayType) else { continue }

                let lift = Lift(
                    id: element.id,
                    name: tags["name"],
                    type: LiftType.from(osmValue: aerialwayType),
                    coordinates: coords,
                    capacity: tags["aerialway:capacity"].flatMap { Int($0) },
                    occupancy: tags["aerialway:occupancy"].flatMap { Int($0) },
                    isOpen: tags["opening_hours"] != "closed"
                )
                lifts.append(lift)
            }
        }

        // Propagate names: unnamed trail segments that share an endpoint
        // with a named segment of the same difficulty inherit the name.
        propagateTrailNames(&trails, nodeIds: trailNodeIds)

        // Parse aerialway station nodes as POIs
        for element in response.elements where element.type == "node" {
            guard let lat = element.lat, let lon = element.lon else { continue }
            let tags = element.tags ?? [:]
            guard tags["aerialway"] == "station" else { continue }
            let coord = Coordinate(lat: lat, lon: lon, ele: tags["ele"].flatMap { Double($0) })
            let poi = PointOfInterest(
                id: element.id,
                name: tags["name"],
                type: .station,
                coordinate: coord
            )
            pois.append(poi)
        }

        return ResortData(
            name: name,
            bounds: bounds,
            trails: trails,
            lifts: lifts,
            pois: pois,
            fetchDate: Date(),
            graphBuildHints: nil
        )
    }

    // MARK: - Elevation Backfill

    /// OSM way nodes rarely carry `ele` tags, so vertical drop is always 0 after
    /// a plain Overpass fetch. This uses ElevationService (Mapbox Terrain-DEM v2
    /// at ~30m resolution, with Open-Meteo 90m fallback) to fill in all missing
    /// elevations, then patches and re-interpolates.
    private func backfillElevation(in data: ResortData, country: String? = nil) async -> ResortData {

        // ── 1. Collect ALL unique coordinates missing elevation ──
        func coordKey(_ lat: Double, _ lon: Double) -> String {
            String(format: "%.6f,%.6f", lat, lon)
        }

        var seen: Set<String> = []
        var points: [(lat: Double, lon: Double)] = []

        func enqueue(_ c: Coordinate) {
            guard c.ele == nil else { return }
            let k = coordKey(c.lat, c.lon)
            if seen.insert(k).inserted {
                points.append((c.lat, c.lon))
            }
        }

        // Enqueue ALL coordinates — not just endpoints — so every graph node
        // and interpolation anchor gets a real DEM elevation.
        for trail in data.trails {
            for coord in trail.coordinates { enqueue(coord) }
        }
        for lift in data.lifts {
            for coord in lift.coordinates { enqueue(coord) }
        }
        for poi in data.pois {
            enqueue(poi.coordinate)
        }

        guard !points.isEmpty else {
            print("[OverpassService] All coordinates already have elevation — skipping DEM query")
            return data
        }

        print("[OverpassService] Backfilling elevation for \(points.count) unique coordinates via ElevationService (USGS 3DEP for US, Mapbox DEM + Open-Meteo fallback)")

        // ── 2. Fetch elevations via ElevationService (USGS 3DEP for US, Mapbox DEM + Open-Meteo fallback) ──
        let elevationMap = await ElevationService.shared.fetchElevations(for: points, country: country)

        print("[OverpassService] DEM backfill: \(elevationMap.count)/\(points.count) elevations retrieved")

        guard !elevationMap.isEmpty else {
            print("[OverpassService] ⚠️ DEM backfill completely failed — elevations will be 0")
            return data
        }

        // ── 3. Apply fetched elevations to ALL coordinates ──
        func patched(_ c: Coordinate) -> Coordinate {
            guard c.ele == nil,
                  let e = elevationMap[coordKey(c.lat, c.lon)]
            else { return c }
            return Coordinate(lat: c.lat, lon: c.lon, ele: e)
        }

        func patchAllCoords(_ coords: [Coordinate]) -> [Coordinate] {
            guard !coords.isEmpty else { return coords }
            var result = coords.map { patched($0) }
            // Fill any remaining gaps via linear interpolation
            result = interpolateElevation(in: result)
            return result
        }

        let updatedTrails = data.trails.map { trail in
            Trail(
                id: trail.id, name: trail.name, difficulty: trail.difficulty,
                grooming: trail.grooming,
                coordinates: patchAllCoords(trail.coordinates),
                lit: trail.lit, ref: trail.ref, isOpen: trail.isOpen
            )
        }

        let updatedLifts = data.lifts.map { lift in
            Lift(
                id: lift.id, name: lift.name, type: lift.type,
                coordinates: patchAllCoords(lift.coordinates),
                capacity: lift.capacity, occupancy: lift.occupancy, isOpen: lift.isOpen
            )
        }

        // Patch POI elevations too
        let updatedPois = data.pois.map { poi in
            PointOfInterest(id: poi.id, name: poi.name, type: poi.type,
                            coordinate: patched(poi.coordinate))
        }

        return ResortData(
            name: data.name, bounds: data.bounds,
            trails: updatedTrails, lifts: updatedLifts,
            pois: updatedPois, fetchDate: data.fetchDate,
            graphBuildHints: data.graphBuildHints
        )
    }

    // MARK: - Trail Name Propagation

    /// OSM often splits a single named trail into many way segments.
    /// Some segments carry the name, others don't. This propagates names
    /// from named segments to adjacent unnamed segments with the same difficulty,
    /// using shared OSM node endpoints as the connection criterion.
    private func propagateTrailNames(_ trails: inout [Trail], nodeIds: [[Int64]]) {
        // Build lookup: OSM node ID → indices of trails that touch it
        var nodeToTrails: [Int64: [Int]] = [:]
        for (i, nodes) in nodeIds.enumerated() {
            guard let first = nodes.first, let last = nodes.last else { continue }
            nodeToTrails[first, default: []].append(i)
            nodeToTrails[last, default: []].append(i)
        }

        // Iteratively propagate until no more changes
        var changed = true
        while changed {
            changed = false
            for i in trails.indices where trails[i].name == nil {
                let nodes = nodeIds[i]
                guard let first = nodes.first, let last = nodes.last else { continue }
                let endpoints = [first, last]

                for endpoint in endpoints {
                    guard let neighbors = nodeToTrails[endpoint] else { continue }
                    for j in neighbors where j != i {
                        if let neighborName = trails[j].name,
                           trails[j].difficulty == trails[i].difficulty {
                            trails[i] = Trail(
                                id: trails[i].id, name: neighborName,
                                difficulty: trails[i].difficulty,
                                grooming: trails[i].grooming,
                                coordinates: trails[i].coordinates,
                                lit: trails[i].lit, ref: trails[i].ref,
                                isOpen: trails[i].isOpen
                            )
                            changed = true
                            break
                        }
                    }
                    if trails[i].name != nil { break }
                }
            }
        }
    }

    // MARK: - Elevation interpolation

    /// For nodes missing `ele`, linearly interpolate from neighbouring nodes that have it.
    /// If no node in the trail has elevation, coordinates are returned unchanged (flat projection fallback).
    private func interpolateElevation(in coords: [Coordinate]) -> [Coordinate] {
        guard coords.count >= 2 else { return coords }

        // Collect known (index, elevation) pairs
        let known: [(idx: Int, ele: Double)] = coords.enumerated().compactMap { i, c in
            c.ele.map { (i, $0) }
        }
        guard !known.isEmpty else { return coords }   // nothing to interpolate from
        if known.count == coords.count { return coords } // already complete

        var result = coords
        for i in 0..<coords.count {
            guard result[i].ele == nil else { continue }

            let before = known.last  { $0.idx < i }
            let after  = known.first { $0.idx > i }

            let interpolated: Double
            switch (before, after) {
            case (let b?, let a?):
                let t = Double(i - b.idx) / Double(a.idx - b.idx)
                interpolated = b.ele + t * (a.ele - b.ele)
            case (let b?, nil): interpolated = b.ele
            case (nil, let a?): interpolated = a.ele
            case (nil, nil):    continue
            }

            result[i] = Coordinate(lat: result[i].lat, lon: result[i].lon, ele: interpolated)
        }
        return result
    }

    // MARK: - Build from Shared Snapshot

    /// Builds ResortData from a frozen server-side snapshot instead of fetching live.
    /// Both OSM data and elevations come from Supabase Storage, ensuring all devices
    /// produce identical graphs from identical inputs.
    func buildFromSnapshot(osmData: Data, elevationData: Data, entry: ResortEntry) throws -> ResortData {
        // Decode the OSM response (same format as Overpass API)
        let decoder = JSONDecoder()
        let response = try decoder.decode(OverpassResponse.self, from: osmData)

        // Decode the elevation map (coordKey → elevation in meters)
        let elevationMap = try decoder.decode([String: Double].self, from: elevationData)

        // Parse OSM → ResortData (same logic as live fetch)
        let data = parseResortData(from: response, name: entry.name, bounds: entry.bounds)

        // Apply elevations from the snapshot instead of fetching from DEM
        // Must match ElevationService's key format: "%.6f,%.6f"
        func coordKey(_ lat: Double, _ lon: Double) -> String {
            String(format: "%.6f,%.6f", lat, lon)
        }

        func patched(_ c: Coordinate) -> Coordinate {
            guard c.ele == nil else { return c }
            // Try exact match, then nearby keys
            let key = coordKey(c.lat, c.lon)
            if let ele = elevationMap[key] {
                return Coordinate(lat: c.lat, lon: c.lon, ele: ele)
            }
            return c
        }

        func patchAllCoords(_ coords: [Coordinate]) -> [Coordinate] {
            var result = coords.map { patched($0) }
            result = interpolateElevation(in: result)
            return result
        }

        let updatedTrails = data.trails.map { trail in
            Trail(
                id: trail.id, name: trail.name, difficulty: trail.difficulty,
                grooming: trail.grooming,
                coordinates: patchAllCoords(trail.coordinates),
                lit: trail.lit, ref: trail.ref, isOpen: trail.isOpen
            )
        }

        let updatedLifts = data.lifts.map { lift in
            Lift(
                id: lift.id, name: lift.name, type: lift.type,
                coordinates: patchAllCoords(lift.coordinates),
                capacity: lift.capacity, occupancy: lift.occupancy, isOpen: lift.isOpen
            )
        }

        let updatedPois = data.pois.map { poi in
            PointOfInterest(id: poi.id, name: poi.name, type: poi.type,
                            coordinate: patched(poi.coordinate))
        }

        return ResortData(
            name: data.name, bounds: data.bounds,
            trails: updatedTrails, lifts: updatedLifts,
            pois: updatedPois, fetchDate: Date(),
            graphBuildHints: data.graphBuildHints
        )
    }
}

// Note: Elevation fetching moved to ElevationService.swift
// (Mapbox Terrain-DEM v2 primary, Open-Meteo fallback)
