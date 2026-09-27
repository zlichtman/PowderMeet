import Foundation

/// Raw Terrain-RGB access is separate from the map's SDK Terrain-DEM renderer.
/// Pixel density/0.1m encoding precision does not imply survey-grade accuracy.
nonisolated enum TerrainRGBTile {
    static func url(z: Int, x: Int, y: Int, token: String) -> URL? {
        var components = URLComponents(string: "https://api.mapbox.com/v4/mapbox.terrain-rgb/\(z)/\(x)/\(y)@2x.pngraw")
        components?.queryItems = [URLQueryItem(name: "access_token", value: token)]
        return components?.url
    }

    struct Position {
        let x: Int
        let y: Int
        let fractionX: Double
        let fractionY: Double
    }

    static func position(lat: Double, lon: Double, zoom: Int) -> Position? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 85.0511287798066,
              abs(lon) <= 180, (0...22).contains(zoom) else { return nil }
        let n = pow(2.0, Double(zoom))
        // Keep exact world edges within the final tile, not an out-of-range tile.
        let worldX = min(n.nextDown, max(0, (lon + 180) / 360 * n))
        let radians = lat * .pi / 180
        let worldY = min(n.nextDown, max(0, (1 - asinh(tan(radians)) / .pi) / 2 * n))
        let x = Int(floor(worldX)), y = Int(floor(worldY))
        return Position(x: x, y: y, fractionX: worldX - Double(x), fractionY: worldY - Double(y))
    }

    static func sampleElevation(
        lat: Double, lon: Double, tileZ: Int, tileX: Int, tileY: Int,
        tileData: (width: Int, height: Int, data: Data)
    ) -> Double? {
        guard tileData.width > 0, tileData.height > 0,
              tileData.width <= 4096, tileData.height <= 4096,
              let point = position(lat: lat, lon: lon, zoom: tileZ),
              point.x == tileX, point.y == tileY else { return nil }
        // Mercator latitude is nonlinear. Use the same projected position for
        // selecting the tile and the pixel, including the independent height.
        let px = min(tileData.width - 1, Int(floor(point.fractionX * Double(tileData.width))))
        let py = min(tileData.height - 1, Int(floor(point.fractionY * Double(tileData.height))))
        let offset = (py * tileData.width + px) * 4
        guard offset + 3 < tileData.data.count, tileData.data[offset + 3] == 255 else { return nil }
        let r = Double(tileData.data[offset]), g = Double(tileData.data[offset + 1])
        let b = Double(tileData.data[offset + 2])
        return -10000 + (r * 65536 + g * 256 + b) * 0.1
    }
}
