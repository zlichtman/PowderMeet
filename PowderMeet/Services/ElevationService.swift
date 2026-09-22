//
//  ElevationService.swift
//  PowderMeet
//
//  Fetches elevation data for coordinates using multiple sources:
//  1. Mapbox Terrain-RGB (Raster Tiles API; source resolution varies)
//  2. Open-Meteo Elevation API (fallback, ~90m resolution)
//
//  Mapbox terrain tiles encode elevation in RGB pixels:
//    elevation = -10000 + ((R * 256 * 256 + G * 256 + B) * 0.1)
//

import Foundation
import CoreGraphics
import ImageIO

actor ElevationService {

    static let shared = ElevationService()

    private let mapboxToken: String
    typealias DataLoader = @Sendable (URL) async throws -> (Data, URLResponse)
    private let loadData: DataLoader

    private init() {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              !token.isEmpty, !token.contains("$(") else {
            fatalError("MBXAccessToken missing from Info.plist. Populate Secrets.xcconfig and clean build.")
        }
        mapboxToken = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: config)
        loadData = { try await session.data(from: $0) }
    }

    /// Isolated transport for deterministic offline tests and local data audits.
    init(mapboxToken: String, loadData: @escaping DataLoader) {
        self.mapboxToken = mapboxToken
        self.loadData = loadData
    }

    // Tile cache: "z/x/y" → pixel data (RGBA). FIFO-capped so a long session
    // bouncing between resorts doesn't accumulate unbounded memory. A 512×512
    // terrain tile at ~1MB RGBA × 128 entries ≈ 128 MB worst-case; in practice
    // tile overlap across resorts keeps the working set far lower.
    private let maxTileCacheEntries = 128
    private var tileCache: [String: (width: Int, height: Int, data: Data)] = [:]
    /// Insertion order for FIFO eviction — Swift Dictionary itself is unordered.
    private var tileCacheOrder: [String] = []

    // MARK: - Public API

    /// Fetch elevations for a batch of coordinates. When `country` indicates
    /// the United States, USGS 3DEP point queries run first (source resolution
    /// varies by location) and fall back to the Mapbox/Open-Meteo chain for any
    /// points the USGS service doesn't answer.
    /// Returns a dictionary keyed by "lat,lon" string → elevation in meters.
    func fetchElevations(
        for coordinates: [(lat: Double, lon: Double)],
        country: String? = nil
    ) async -> [String: Double] {
        // Invalid coordinates must never reach integer tile conversion. Collapse
        // duplicate six-decimal locations, matching the returned dictionary keys.
        var seen = Set<String>()
        let coordinates = coordinates.filter {
            $0.lat.isFinite && $0.lon.isFinite && abs($0.lat) <= 90 && abs($0.lon) <= 180
                && seen.insert(String(format: "%.6f,%.6f", $0.lat, $0.lon)).inserted
        }
        guard !coordinates.isEmpty, !Task.isCancelled else { return [:] }

        if Self.isUSCountryCode(country) {
            let usgs = await fetchUSGSElevations(for: coordinates)
            if !usgs.isEmpty {
                let remaining = coordinates.filter { coord in
                    usgs[String(format: "%.6f,%.6f", coord.lat, coord.lon)] == nil
                }
                if remaining.isEmpty {
                    return usgs
                }
                // Delegate to the main (Mapbox → Open-Meteo) path for the
                // remainder. Preserves existing behaviour below.
                var merged = usgs
                let fallback = await fetchElevationsMapboxDEM(for: remaining)
                for (k, v) in fallback { merged[k] = v }
                return merged
            }
        }

        return await fetchElevationsMapboxDEM(for: coordinates)
    }

    private static func isUSCountryCode(_ c: String?) -> Bool {
        guard let c = c?.uppercased() else { return false }
        return c == "US" || c == "USA"
    }

    // MARK: - USGS 3DEP (United States only)

    /// Queries the USGS 3DEP Elevation Point Query Service for each
    /// coordinate. A returned height is a terrain estimate, not proof of
    /// survey accuracy or complete steep-terrain coverage.
    /// Runs queries concurrently (bounded) and bails after repeated failure
    /// so a USGS outage doesn't drag out the whole resort load.
    private func fetchUSGSElevations(
        for coordinates: [(lat: Double, lon: Double)]
    ) async -> [String: Double] {
        guard !coordinates.isEmpty else { return [:] }

        struct USGSResponse: Decodable { let value: String? }
        var results: [String: Double] = [:]
        let maxConcurrent = 6
        var consecutiveFailures = 0
        let failureCeiling = 8

        // Simple semaphore-style batching over chunks.
        var index = 0
        while index < coordinates.count {
            guard !Task.isCancelled else { return results }
            if consecutiveFailures >= failureCeiling {
                print("[ElevationService] USGS 3DEP: \(consecutiveFailures) consecutive failures, aborting — handing off to Mapbox DEM")
                break
            }

            let chunkEnd = min(index + maxConcurrent, coordinates.count)
            let chunk = Array(coordinates[index..<chunkEnd])
            index = chunkEnd

            await withTaskGroup(of: (String, Double?).self) { group in
                for coord in chunk {
                    group.addTask { [loadData] in
                        let urlStr = "https://epqs.nationalmap.gov/v1/json?x=\(coord.lon)&y=\(coord.lat)&wkid=4326&units=Meters"
                        guard let url = URL(string: urlStr) else {
                            return (String(format: "%.6f,%.6f", coord.lat, coord.lon), nil)
                        }
                        do {
                            let (data, response) = try await loadData(url)
                            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                                return (String(format: "%.6f,%.6f", coord.lat, coord.lon), nil)
                            }
                            let decoded = try JSONDecoder().decode(USGSResponse.self, from: data)
                            if let valueStr = decoded.value, let v = Double(valueStr), v.isFinite, v > -500 {
                                return (String(format: "%.6f,%.6f", coord.lat, coord.lon), v)
                            }
                            return (String(format: "%.6f,%.6f", coord.lat, coord.lon), nil)
                        } catch {
                            return (String(format: "%.6f,%.6f", coord.lat, coord.lon), nil)
                        }
                    }
                }

                for await (key, value) in group {
                    if let v = value {
                        results[key] = v
                        consecutiveFailures = 0
                    } else {
                        consecutiveFailures += 1
                    }
                }
            }
        }

        print("[ElevationService] USGS 3DEP: \(results.count)/\(coordinates.count) elevations resolved")
        return results
    }

    private func fetchElevationsMapboxDEM(
        for coordinates: [(lat: Double, lon: Double)]
    ) async -> [String: Double] {

        let zoom = 14 // 512px Terrain-RGB native maximum; not a claim of ground accuracy.
        var results: [String: Double] = [:]

        // Group coordinates by tile
        var tileGroups: [String: [(lat: Double, lon: Double, key: String)]] = [:]
        for coord in coordinates {
            let key = String(format: "%.6f,%.6f", coord.lat, coord.lon)
            guard let position = TerrainRGBTile.position(lat: coord.lat, lon: coord.lon, zoom: zoom) else { continue }
            let tileX = position.x
            let tileY = position.y
            let tileKey = "\(zoom)/\(tileX)/\(tileY)"
            tileGroups[tileKey, default: []].append((coord.lat, coord.lon, key))
        }

        print("[ElevationService] Fetching elevations for \(coordinates.count) points across \(tileGroups.count) tiles (zoom \(zoom))")

        var fetchedTiles = 0
        var failedTiles = 0

        for tileKey in tileGroups.keys.sorted() {
            guard !Task.isCancelled else { return results }
            let points = tileGroups[tileKey]!
            let parts = tileKey.split(separator: "/")
            guard parts.count == 3,
                  let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else {
                print("[ElevationService] ⚠️ Malformed tileKey: \(tileKey)")
                continue
            }

            // Try to get tile data (from cache or fetch)
            guard let tileData = await getTileData(z: z, x: x, y: y) else {
                failedTiles += 1
                // All unresolved points share one bounded fallback pass below.
                continue
            }

            fetchedTiles += 1

            // Sample elevation for each point in this tile
            for point in points {
                if let ele = TerrainRGBTile.sampleElevation(
                    lat: point.lat, lon: point.lon,
                    tileZ: z, tileX: x, tileY: y,
                    tileData: tileData
                ) {
                    if ele > -500 { // sanity check
                        results[point.key] = ele
                    }
                }
            }
        }

        print("[ElevationService] Mapbox DEM: \(fetchedTiles) tiles fetched, \(failedTiles) failed, \(results.count)/\(coordinates.count) elevations resolved")

        // Fallback: fetch remaining from Open-Meteo
        let missing = coordinates.filter { coord in
            let key = String(format: "%.6f,%.6f", coord.lat, coord.lon)
            return results[key] == nil
        }

        if !missing.isEmpty {
            print("[ElevationService] Falling back to Open-Meteo for \(missing.count) remaining points")
            let fallback = await fetchOpenMeteoElevations(for: missing)
            for (i, coord) in missing.enumerated() {
                if i < fallback.count, let ele = fallback[i] {
                    let key = String(format: "%.6f,%.6f", coord.lat, coord.lon)
                    results[key] = ele
                }
            }
        }

        return results
    }

    // MARK: - Mapbox Terrain-RGB Tile Fetching

    private func getTileData(z: Int, x: Int, y: Int) async -> (width: Int, height: Int, data: Data)? {
        let cacheKey = "\(z)/\(x)/\(y)"
        if let cached = tileCache[cacheKey] {
            return cached
        }

        // Terrain-DEM is SDK-only. Raw analytical samples use Terrain-RGB.
        guard let url = TerrainRGBTile.url(z: z, x: x, y: y, token: mapboxToken) else { return nil }

        do {
            let (data, response) = try await loadData(url)
            guard let httpResp = response as? HTTPURLResponse,
                  httpResp.statusCode == 200 else {
                return nil
            }

            // Decode PNG → raw RGBA pixel data
            guard let tileData = decodePNG(data: data) else {
                print("[ElevationService] ⚠️ Failed to decode tile \(cacheKey)")
                return nil
            }

            tileCache[cacheKey] = tileData
            tileCacheOrder.append(cacheKey)
            if tileCacheOrder.count > maxTileCacheEntries {
                let oldest = tileCacheOrder.removeFirst()
                tileCache.removeValue(forKey: oldest)
            }
            return tileData
        } catch {
            // Network errors may contain the credential-bearing URL.
            print("[ElevationService] Tile fetch failed z/\(z)/x/\(x)/y/\(y)")
            return nil
        }
    }

    /// Decode a PNG image to raw RGBA pixel data.
    private func decodePNG(data: Data) -> (width: Int, height: Int, data: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard (1...1024).contains(width), (1...1024).contains(height) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var pixelData = Data(count: totalBytes)
        let decoded = pixelData.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }
        return (width, height, pixelData)
    }

    // MARK: - Open-Meteo Fallback

    private func fetchOpenMeteoElevations(
        for coordinates: [(lat: Double, lon: Double)]
    ) async -> [Double?] {
        guard !coordinates.isEmpty else { return [] }

        var results: [Double?] = Array(repeating: nil, count: coordinates.count)
        let batchSize = 50

        for batchStart in stride(from: 0, to: coordinates.count, by: batchSize) {
            guard !Task.isCancelled else { return results }
            let batchEnd = min(batchStart + batchSize, coordinates.count)
            let batch = Array(coordinates[batchStart..<batchEnd])

            let lats = batch.map { String(format: "%.6f", $0.lat) }.joined(separator: ",")
            let lons = batch.map { String(format: "%.6f", $0.lon) }.joined(separator: ",")

            var comps = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
            comps.queryItems = [
                URLQueryItem(name: "latitude", value: lats),
                URLQueryItem(name: "longitude", value: lons),
            ]
            guard let url = comps.url else { continue }

            for attempt in 0..<3 {
                guard !Task.isCancelled else { return results }
                do {
                    let (data, response) = try await loadData(url)
                    guard let httpResp = response as? HTTPURLResponse else { continue }
                    if httpResp.statusCode == 429 {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        continue
                    }
                    guard httpResp.statusCode == 200 else { continue }

                    struct ElevResp: Decodable { let elevation: [Double?] }
                    if let resp = try? JSONDecoder().decode(ElevResp.self, from: data),
                       resp.elevation.count == batch.count {
                        // Preserve positional nulls. A mismatched response must
                        // never shift heights to another point or index past a batch.
                        for (i, ele) in resp.elevation.enumerated() {
                            if let ele, ele.isFinite, ele > -500 {
                                results[batchStart + i] = ele
                            }
                        }
                        break
                    }
                } catch {
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                    }
                }
            }

            // Throttle between batches
            if batchEnd < coordinates.count {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        return results
    }
}
