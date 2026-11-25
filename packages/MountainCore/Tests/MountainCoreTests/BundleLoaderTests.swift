import CZlib
import Foundation
import Testing
@testable import MountainCore

/// A two-node, one-lift, one-run resort that satisfies every integrity rule.
private func validDocument() -> BundleDocument {
    let base = Node(id: "n1", lon: -122.95, lat: 50.10, eleM: 700, kind: .base)
    let top = Node(id: "n2", lon: -122.95, lat: 50.11, eleM: 1_100, kind: .liftTop)
    let rise = Geo.haversineM(base.coordinate, top.coordinate)
    let up = [GeoPoint(lon: base.lon, lat: base.lat, eleM: 700),
              GeoPoint(lon: top.lon, lat: top.lat, eleM: 1_100)]
    return BundleDocument(
        resortID: "test-resort", name: "Test Resort", timezone: "America/Vancouver",
        bbox: BoundingBox(minLon: -123, minLat: 50, maxLon: -122.9, maxLat: 50.2),
        center: Coordinate(lon: -122.95, lat: 50.105),
        source: .init(
            extractID: "osm-test", osmExtractAt: Date(timeIntervalSince1970: 1_790_000_000),
            manifestVersion: 1
        ),
        builtAt: Date(timeIntervalSince1970: 1_790_000_100),
        nodes: [base, top],
        edges: [
            Edge(
                id: "w10:0", from: "n1", to: "n2", kind: .lift, group: "lift:test-chair",
                name: "Test Chair", geometry: up, lengthM: rise, verticalM: 400,
                lift: LiftInfo(type: .chair, rideS: 420, capacityPPH: 2_400)
            ),
            Edge(
                id: "w20:0", from: "n2", to: "n1", kind: .run, group: "trail:test-run",
                name: "Test Run", difficulty: .blue, geometry: up.reversed(), lengthM: rise,
                verticalM: -400, gradeMaxDeg: 20, groomedDefault: true, aspectDeg: 180
            ),
        ],
        groups: [
            Group(id: "lift:test-chair", kind: .lift, name: "Test Chair", edgeIDs: ["w10:0"]),
            Group(id: "trail:test-run", kind: .trail, name: "Test Run", difficulty: .blue,
                  edgeIDs: ["w20:0"]),
        ],
        rendezvous: [
            Rendezvous(id: "test-base", nodeID: "n1", kind: .liftBase, name: "Test Base",
                       confidence: 0.95, quality: 0.9, amenities: ["food"]),
        ]
    )
}

private func gzip(_ data: Data) -> Data {
    var stream = z_stream()
    let status = deflateInit2_(
        &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
    )
    precondition(status == Z_OK)
    defer { deflateEnd(&stream) }
    var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))) + 64)
    let written: Int = data.withUnsafeBytes { input in
        output.withUnsafeMutableBufferPointer { buffer in
            stream.next_in = UnsafeMutablePointer(
                mutating: input.bindMemory(to: UInt8.self).baseAddress
            )
            stream.avail_in = UInt32(input.count)
            stream.next_out = buffer.baseAddress
            stream.avail_out = UInt32(buffer.count)
            precondition(deflate(&stream, Z_FINISH) == Z_STREAM_END)
            return buffer.count - Int(stream.avail_out)
        }
    }
    return Data(output[0..<written])
}

private func stored(_ document: BundleDocument) throws -> (data: Data, id: BundleID) {
    let data = gzip(try document.encoded())
    return (data, try #require(BundleID(SHA256.hex(data))))
}

@Test func sha256MatchesKnownAnswers() {
    #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    // 1,000 bytes crosses several blocks and the length-padding boundary.
    #expect(SHA256.hex(Data(repeating: 0x61, count: 1_000))
        == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
}

@Test func validBundleLoadsWithItsByteIdentity() throws {
    let (data, id) = try stored(validDocument())
    let bundle = try BundleLoader.load(data: data, expectedID: id)
    #expect(bundle.id == id)
    #expect(bundle.resortID == "test-resort")
    #expect(bundle.graph.edges.map(\.id) == ["w10:0", "w20:0"])
    #expect(bundle.graph.outgoing(from: "n1").map(\.id) == ["w10:0"])
    #expect(bundle.rendezvous("test-base")?.nodeID == "n1")
    #expect(bundle.timeZone != nil)
}

@Test func corruptSHAIsRejectedBeforeAnythingIsDecoded() throws {
    let (data, id) = try stored(validDocument())
    var tampered = data
    tampered[tampered.count - 1] ^= 0x01
    #expect(throws: BundleLoadError.sha256Mismatch(expected: id, actual: SHA256.hex(tampered))) {
        try BundleLoader.load(data: tampered, expectedID: id)
    }
    // Bytes that are not a bundle at all still fail on identity, not on parsing.
    let junk = Data("not a bundle".utf8)
    #expect(throws: BundleLoadError.sha256Mismatch(expected: id, actual: SHA256.hex(junk))) {
        try BundleLoader.load(data: junk, expectedID: id)
    }
}

@Test func oversizePayloadIsRejected() throws {
    // A highly compressible payload: small on the wire, large once inflated.
    let bomb = gzip(Data(repeating: 0x20, count: 200_000))
    let bombID = try #require(BundleID(SHA256.hex(bomb)))
    #expect(throws: BundleLoadError.decodedSizeExceeded(limit: 100_000)) {
        try BundleLoader.load(
            data: bomb, expectedID: bombID,
            maximumCompressedBytes: 1_000_000, maximumDecodedBytes: 100_000
        )
    }
    #expect(throws: BundleLoadError.compressedSizeExceeded(actual: bomb.count, limit: 16)) {
        try BundleLoader.load(
            data: bomb, expectedID: bombID, maximumCompressedBytes: 16, maximumDecodedBytes: 100_000
        )
    }
    #expect(BundleLoader.maximumDecodedBytes == 64 * 1_024 * 1_024)
}

@Test func graphThatFailsIntegrityIsRejected() throws {
    var dangling = validDocument()
    dangling.edges[1].to = "n404"
    var (data, id) = try stored(dangling)
    #expect(throws: BundleLoadError.integrity(.missingEndpoint(edge: "w20:0", node: "n404"))) {
        try BundleLoader.load(data: data, expectedID: id)
    }

    var uphillRun = validDocument()
    uphillRun.edges[1].verticalM = 400
    (data, id) = try stored(uphillRun)
    #expect(throws: BundleLoadError.integrity(.invalidAttribute(edge: "w20:0", field: "vertical_m"))) {
        try BundleLoader.load(data: data, expectedID: id)
    }

    var wrongLength = validDocument()
    wrongLength.edges[1].lengthM *= 2
    (data, id) = try stored(wrongLength)
    #expect(throws: BundleLoadError.integrity(.invalidAttribute(edge: "w20:0", field: "length_m"))) {
        try BundleLoader.load(data: data, expectedID: id)
    }

    var strayRendezvous = validDocument()
    strayRendezvous.rendezvous[0].nodeID = "n404"
    (data, id) = try stored(strayRendezvous)
    #expect(throws: BundleLoadError.integrity(.invalidRendezvous("test-base", field: "node_id"))) {
        try BundleLoader.load(data: data, expectedID: id)
    }

    var liveWithoutAliases = validDocument()
    liveWithoutAliases.statusMode = .live
    (data, id) = try stored(liveWithoutAliases)
    #expect(throws: BundleLoadError.integrity(.liveStatusCoverage(mapped: 0, lifts: 1))) {
        try BundleLoader.load(data: data, expectedID: id)
    }

    var liveWithAlias = liveWithoutAliases
    liveWithAlias.statusAliases = ["epic": ["Test Chair": "lift:test-chair"]]
    (data, id) = try stored(liveWithAlias)
    #expect(try BundleLoader.load(data: data, expectedID: id).statusMode == .live)
}

/// A newer format that no longer decodes as this one must still say
/// "update the app", not fail as a damaged download.
@Test func aNewerSchemaIsReportedEvenWhenItNoLongerDecodes() throws {
    let data = gzip(Data(#"{"schema_version": 2, "graph": "renamed"}"#.utf8))
    let id = try #require(BundleID(SHA256.hex(data)))
    #expect(throws: BundleLoadError.unsupportedSchema(2)) {
        try BundleLoader.load(data: data, expectedID: id)
    }
}
