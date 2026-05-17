//
//  ResortAmenitiesService.swift
//  PowderMeet
//
//  On-mountain amenities (restaurants, cafes, bars, warming huts,
//  restrooms, first aid, rentals, parking) for the current resort.
//
//  Deliberately a SIDE CHANNEL, not part of the deterministic graph.
//  The graph fingerprint is a hard invariant — two devices at the
//  same resort must build byte-identical graphs (see CLAUDE.md). POIs
//  like restaurants don't affect routing, so threading them through
//  the graph would only risk fingerprint drift for zero solver gain.
//  Instead this fetches amenities directly from Overpass keyed by the
//  resort bounding box, caches them on disk, and the map renders them
//  through their own source/layer. Works identically for legacy and
//  canonical-pipeline resorts because it never touches either build
//  path.
//
//  Cache: `Documents/amenities/<resortId>.json`, 14-day TTL. Amenities
//  move on the order of seasons, not hours, so a fortnight-stale list
//  is fine and a network failure silently falls back to it.
//

import Foundation

actor ResortAmenitiesService {
    static let shared = ResortAmenitiesService()

    private let baseURL = "https://overpass-api.de/api/interpreter"
    private let session = URLSession.shared
    private let ttl: TimeInterval = 14 * 24 * 3600

    /// In-flight de-dupe so a rapid resort re-entry doesn't fire two
    /// identical Overpass queries.
    private var inFlight: [String: Task<[PointOfInterest], Never>] = [:]

    private init() {}

    /// Amenities within `entry`'s bounding box. Returns cached results
    /// immediately when fresh; otherwise fetches, caches, and returns.
    /// Never throws — a fetch failure yields the stale cache or `[]`.
    func amenities(for entry: ResortEntry) async -> [PointOfInterest] {
        if let fresh = loadCache(resortId: entry.id, maxAge: ttl) {
            return fresh
        }
        if let existing = inFlight[entry.id] {
            return await existing.value
        }
        let task = Task<[PointOfInterest], Never> {
            let fetched = await fetch(bounds: entry.bounds)
            if !fetched.isEmpty {
                saveCache(resortId: entry.id, pois: fetched)
                return fetched
            }
            // Network/parse miss: fall back to any stale cache so the
            // map still shows last-known amenities offline-on-mountain.
            return loadCache(resortId: entry.id, maxAge: .infinity) ?? []
        }
        inFlight[entry.id] = task
        let result = await task.value
        inFlight[entry.id] = nil
        return result
    }

    // MARK: - Overpass

    /// OSM tags we surface, mapped to our `POIType`. `way`/`relation`
    /// matches use `out center` so polygon lodges resolve to a point.
    private func fetch(bounds: BoundingBox) async -> [PointOfInterest] {
        let bbox = bounds.overpassBBox
        let query = """
        [out:json][timeout:60];
        (
          nwr["amenity"="restaurant"](\(bbox));
          nwr["amenity"="cafe"](\(bbox));
          nwr["amenity"="bar"](\(bbox));
          nwr["amenity"="fast_food"](\(bbox));
          nwr["amenity"="biergarten"](\(bbox));
          nwr["amenity"="toilets"](\(bbox));
          nwr["amenity"="first_aid"](\(bbox));
          nwr["amenity"="shelter"](\(bbox));
          nwr["amenity"="ski_rental"](\(bbox));
          nwr["shop"="ski"](\(bbox));
          nwr["amenity"="parking"]["access"!="private"](\(bbox));
          nwr["tourism"="alpine_hut"](\(bbox));
          nwr["tourism"="wilderness_hut"](\(bbox));
          nwr["tourism"="chalet"](\(bbox));
        );
        out center tags;
        """
        guard let url = URL(string: baseURL) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 70)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            let decoded = try JSONDecoder().decode(AmenityResponse.self, from: data)
            return parse(decoded)
        } catch {
            return []
        }
    }

    // Local decoding types — kept separate from the shared
    // `OSMElement` (used by the deterministic OverpassService) so this
    // side channel can decode the `center` object that `out center`
    // emits for ways/relations without risking that model.
    private struct AmenityResponse: Decodable {
        let elements: [AmenityElement]
    }
    private struct AmenityCenter: Decodable {
        let lat: Double
        let lon: Double
    }
    private struct AmenityElement: Decodable {
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: AmenityCenter?
        let tags: [String: String]?
    }

    private func parse(_ response: AmenityResponse) -> [PointOfInterest] {
        var seen = Set<Int64>()
        var pois: [PointOfInterest] = []
        for el in response.elements {
            guard !seen.contains(el.id) else { continue }
            // node → top-level lat/lon; way/relation → `center`.
            let lat = el.lat ?? el.center?.lat
            let lon = el.lon ?? el.center?.lon
            guard let lat, let lon else { continue }
            let tags = el.tags ?? [:]
            guard let type = Self.poiType(for: tags) else { continue }
            seen.insert(el.id)
            pois.append(PointOfInterest(
                id: el.id,
                name: tags["name"],
                type: type,
                coordinate: Coordinate(lat: lat, lon: lon, ele: nil)
            ))
        }
        return pois
    }

    /// Resolve OSM tags to one of our `POIType` cases. Order matters —
    /// first match wins (first_aid before generic shelter, etc.).
    static func poiType(for tags: [String: String]) -> POIType? {
        if tags["amenity"] == "first_aid" { return .firstAid }
        if tags["amenity"] == "toilets" { return .restroom }
        if tags["amenity"] == "parking" { return .parking }
        if tags["amenity"] == "ski_rental" || tags["shop"] == "ski" { return .rental }
        if let a = tags["amenity"],
           ["restaurant", "cafe", "bar", "fast_food", "biergarten"].contains(a) {
            return .restaurant
        }
        if let t = tags["tourism"],
           ["alpine_hut", "wilderness_hut", "chalet"].contains(t) {
            return .lodge
        }
        if tags["amenity"] == "shelter" { return .lodge }
        return nil
    }

    // MARK: - Disk cache

    private func cacheURL(resortId: String) -> URL? {
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        let amenityDir = dir.appendingPathComponent("amenities", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: amenityDir, withIntermediateDirectories: true
        )
        return amenityDir.appendingPathComponent("\(resortId).json")
    }

    private struct CacheEnvelope: Codable {
        let savedAt: Date
        let pois: [PointOfInterest]
    }

    private func loadCache(resortId: String, maxAge: TimeInterval) -> [PointOfInterest]? {
        guard let url = cacheURL(resortId: resortId),
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(CacheEnvelope.self, from: data)
        else { return nil }
        if maxAge != .infinity,
           Date.now.timeIntervalSince(env.savedAt) > maxAge {
            return nil
        }
        return env.pois
    }

    private func saveCache(resortId: String, pois: [PointOfInterest]) {
        guard let url = cacheURL(resortId: resortId) else { return }
        let env = CacheEnvelope(savedAt: .now, pois: pois)
        if let data = try? JSONEncoder().encode(env) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
