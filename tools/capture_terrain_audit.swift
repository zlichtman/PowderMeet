// Compile with the app's ElevationService.swift and TerrainRGBTile.swift.
// Usage: capture-terrain <osm.json> <built-app-Info.plist> <new-output-directory>
// Read-only Mapbox access; no Supabase calls, publication, or implicit retries.
import Foundation
import CryptoKit

private enum CaptureError: Error { case arguments, invalidSource, missingToken, outputExists, requestLimit, incomplete }

private actor CaptureTransport {
    let output: URL
    let session: URLSession
    var tiles: [[String: String]] = []
    var requests = 0
    init(output: URL) {
        self.output = output
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }
    func load(_ url: URL) async throws -> (Data, URLResponse) {
        guard url.host == "api.mapbox.com" else {
            // No external fallback is allowed in this capture: preserve unknowns
            // and fail completeness below instead of blending source providers.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let count = items?.first(where: { $0.name == "latitude" })?.value?.split(separator: ",").count ?? 0
            let data = try JSONSerialization.data(withJSONObject: ["elevation": Array(repeating: NSNull(), count: count)])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard requests < 64, url.path.hasPrefix("/v4/mapbox.terrain-rgb/14/") else { throw CaptureError.requestLimit }
        requests += 1
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return (data, response) }
        let name = url.path.replacingOccurrences(of: "/", with: "_")
        try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
        tiles.append(["requestPath": url.path, "file": name,
                      "sha256": Self.sha(data), "bytes": String(data.count),
                      "etag": http.value(forHTTPHeaderField: "ETag") ?? ""])
        return (data, response)
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@main struct CaptureTerrain {
    static func main() async {
        do { try await capture() }
        catch {
            // Never emit transport errors: they can carry token-bearing URLs.
            print("Terrain capture failed (\(error is CaptureError ? String(describing: error) : "input/output error")). No dataset was published.")
            exit(1)
        }
    }
    static func capture() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw CaptureError.arguments }
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard let source = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              let elements = source["elements"] as? [[String: Any]],
              let timestamp = (source["osm3s"] as? [String: Any])?["timestamp_osm_base"] as? String else { throw CaptureError.invalidSource }
        var nodes: [Int: (lat: Double, lon: Double)] = [:]
        var required = Set<Int>()
        for element in elements {
            guard let id = element["id"] as? Int else { throw CaptureError.invalidSource }
            if element["type"] as? String == "node" {
                guard let lat = element["lat"] as? Double, let lon = element["lon"] as? Double,
                      lat.isFinite, lon.isFinite, abs(lat) <= 85.0511287798066, abs(lon) <= 180 else { throw CaptureError.invalidSource }
                if let old = nodes[id], old.lat != lat || old.lon != lon { throw CaptureError.invalidSource }
                nodes[id] = (lat, lon)
            } else if element["type"] as? String == "way", let tags = element["tags"] as? [String: String] {
                let isPiste = ["downhill", "connection"].contains(tags["piste:type"] ?? "")
                let isLift = tags["piste:type"] == nil && tags["aerialway"] != nil
                    && !["station", "zip_line"].contains(tags["aerialway"] ?? "")
                if isPiste || isLift {
                    guard let ids = element["nodes"] as? [Int], ids.count >= 2 else { throw CaptureError.invalidSource }
                    required.formUnion(ids)
                }
            }
        }
        var coordinates: [String: (lat: Double, lon: Double)] = [:]
        var tileIDs = Set<String>()
        for id in required.sorted() {
            guard let point = nodes[id], let tile = TerrainRGBTile.position(lat: point.lat, lon: point.lon, zoom: 14) else { throw CaptureError.invalidSource }
            coordinates[String(format: "%.6f,%.6f", point.lat, point.lon)] = point
            tileIDs.insert("\(tile.x)/\(tile.y)")
        }
        guard !coordinates.isEmpty, tileIDs.count <= 64 else { throw CaptureError.requestLimit }
        let plistData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let token = (plist as? [String: Any])?["MBXAccessToken"] as? String,
              !token.isEmpty, !token.contains("$(") else { throw CaptureError.missingToken }
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CaptureError.outputExists }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let transport = CaptureTransport(output: output)
        let service = ElevationService(mapboxToken: token, loadData: { try await transport.load($0) })
        let elevations = await service.fetchElevations(for: coordinates.keys.sorted().map { coordinates[$0]! }, country: "CA")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let elevationData = try encoder.encode(elevations)
        try elevationData.write(to: output.appendingPathComponent("elevations.json"), options: .withoutOverwriting)
        let manifest: [String: Any] = ["sourceSHA256": CaptureTransport.sha(sourceData),
            "sourceOSMTimestamp": timestamp, "samplingVersion": "terrain-rgb-mercator-v1",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "requiredSourceNodes": required.count, "requiredCoordinates": coordinates.count,
            "resolvedCoordinates": elevations.count, "elevationSHA256": CaptureTransport.sha(elevationData),
            "tiles": await transport.tiles,
            "attribution": "OpenStreetMap contributors; Mapbox Terrain-RGB. Local audit only, not a published dataset."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        print("Captured \(elevations.count)/\(coordinates.count) elevations across \(tileIDs.count) tiles; source nodes \(required.count).")
        guard elevations.count == coordinates.count else { throw CaptureError.incomplete }
    }
}
