import XCTest
import CoreGraphics
import ImageIO
@testable import PowderMeet

final class ElevationServiceTests: XCTestCase {
    private actor Requests {
        var urls: [URL] = []
        let png: Data?
        let fallback: Data
        init(png: Data? = nil, fallback: String = "{\"elevation\":[]}") {
            self.png = png
            self.fallback = Data(fallback.utf8)
        }
        func respond(_ url: URL) -> (Data, URLResponse) {
            urls.append(url)
            let isTile = url.host == "api.mapbox.com"
            let status = isTile && png == nil ? 404 : 200
            return (isTile ? (png ?? Data()) : fallback,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func count(host: String) -> Int { urls.filter { $0.host == host }.count }
    }

    private func point(x: Double, y: Double, zoom: Int) -> (lat: Double, lon: Double) {
        let n = pow(2.0, Double(zoom))
        return (atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi, x / n * 360 - 180)
    }

    private func png(width: Int, height: Int, bytes: [UInt8]) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testRasterEndpointAndTokenEncoding() throws {
        let url = try XCTUnwrap(TerrainRGBTile.url(z: 14, x: 2597, y: 5538, token: "test&scope=value"))
        XCTAssertEqual(url.path, "/v4/mapbox.terrain-rgb/14/2597/5538@2x.pngraw")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "access_token", value: "test&scope=value")])
    }

    func testMercatorPixelSamplingAndNorthSouthOrientation() throws {
        // Every row has a distinct exact RGB elevation. Non-square dimensions
        // also prevent width being mistaken for height.
        let bytes: [UInt8] = (0..<256).flatMap { row in
            Array(repeating: [UInt8(1), UInt8(row), UInt8(136), UInt8(255)], count: 2).flatMap { $0 }
        }
        let tile = (width: 2, height: 256, data: Data(bytes))
        for row in [0, 37, 128, 200, 255] {
            let coordinate = point(x: 0.25, y: (Double(row) + 0.5) / 256, zoom: 1)
            let value = try XCTUnwrap(TerrainRGBTile.sampleElevation(lat: coordinate.lat, lon: coordinate.lon,
                tileZ: 1, tileX: 0, tileY: 0, tileData: tile))
            XCTAssertEqual(value, -10000 + (65536 + Double(row) * 256 + 136) * 0.1, accuracy: 0.0001)
        }
    }

    func testTileBoundsAndMalformedPixelsFailWithoutInventingElevations() throws {
        for latitude in [Double.nan, .infinity, -90, 90, 86] {
            XCTAssertNil(TerrainRGBTile.position(lat: latitude, lon: 0, zoom: 14))
        }
        for longitude in [Double.nan, .infinity, 181, -181] {
            XCTAssertNil(TerrainRGBTile.position(lat: 0, lon: longitude, zoom: 14))
        }
        XCTAssertNil(TerrainRGBTile.position(lat: 0, lon: 0, zoom: -1))
        XCTAssertEqual(TerrainRGBTile.position(lat: 0, lon: 180, zoom: 14)?.x, 16383)
        XCTAssertEqual(TerrainRGBTile.position(lat: 0, lon: -180, zoom: 14)?.x, 0)
        for data in [Data(), Data([1, 150, 136, 0])] {
            XCTAssertNil(TerrainRGBTile.sampleElevation(lat: 45, lon: -90, tileZ: 1,
                tileX: 0, tileY: 0, tileData: (1, 1, data)))
        }
        XCTAssertNil(TerrainRGBTile.sampleElevation(lat: 45, lon: -90, tileZ: 1,
            tileX: 1, tileY: 0, tileData: (1, 1, Data([1, 150, 136, 255]))))
    }

    func testPNGDecodingUsesCorrectPixelAndReusesCachedTile() async throws {
        let bytes: [UInt8] = [1, 150, 136, 255, 1, 151, 136, 255,
                              1, 152, 136, 255, 1, 153, 136, 255]
        let requests = Requests(png: try png(width: 2, height: 2, bytes: bytes))
        let service = ElevationService(mapboxToken: "test", loadData: { await requests.respond($0) })
        for (index, fraction) in [(0, (0.25, 0.25)), (3, (0.75, 0.75))] {
            let coordinate = point(x: 2597 + fraction.0, y: 5538 + fraction.1, zoom: 14)
            let result = await service.fetchElevations(for: [coordinate], country: "CA")
            XCTAssertEqual(try XCTUnwrap(result.values.first), 407.2 + Double(index) * 25.6, accuracy: 0.001)
        }
        let tiles = await requests.count(host: "api.mapbox.com")
        let fallback = await requests.count(host: "api.open-meteo.com")
        XCTAssertEqual(tiles, 1)
        XCTAssertEqual(fallback, 0)
    }

    func testFallbackPreservesNullPositionsAndDeduplicatesCoordinates() async throws {
        let requests = Requests(fallback: "{\"elevation\":[null,1234]}")
        let service = ElevationService(mapboxToken: "test", loadData: { await requests.respond($0) })
        let result = await service.fetchElevations(for: [(50.09, -122.95), (50.091, -122.95),
            (50.09, -122.95), (.nan, 0), (91, 0)], country: "CA")
        XCTAssertNil(result["50.090000,-122.950000"])
        XCTAssertEqual(result["50.091000,-122.950000"], 1234)
        XCTAssertEqual(result.count, 1)
        let count = await requests.count(host: "api.open-meteo.com")
        XCTAssertEqual(count, 1)
    }

    func testMalformedFallbackLengthIsRejectedAndNotRepeatedPerTile() async {
        for json in ["{\"elevation\":[1,2,3]}", "{\"elevation\":[]}"] {
            let requests = Requests(fallback: json)
            let service = ElevationService(mapboxToken: "test", loadData: { await requests.respond($0) })
            let result = await service.fetchElevations(for: [(50.09, -122.95), (50.091, -122.95)], country: "CA")
            XCTAssertTrue(result.isEmpty)
            let count = await requests.count(host: "api.open-meteo.com")
            XCTAssertEqual(count, 3, "One bounded fallback pass, not a second retry series")
        }
    }

    func testInvalidCoordinatesNeverCallNetwork() async {
        let requests = Requests()
        let service = ElevationService(mapboxToken: "test", loadData: { await requests.respond($0) })
        let result = await service.fetchElevations(for: [(.infinity, 0), (0, .nan), (91, 0)])
        XCTAssertTrue(result.isEmpty)
        let count = await requests.urls.count
        XCTAssertEqual(count, 0)
    }
}
