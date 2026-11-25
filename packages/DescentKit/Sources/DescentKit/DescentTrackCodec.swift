import CZlib
import Foundation

/// The stored form of a descent's track (`specs/02-DOMAIN.md` section 8): gzip
/// of a small JSON document, the bytes `descent_upsert` takes as `track`.
///
/// ```
/// {"v":1,"t0":<unix seconds of the first fix>,"p":[[dt_s, lat, lon, ele_m|null], ...]}
/// ```
/// Times are offsets from `t0` in tenths of a second, coordinates keep six
/// decimals (about 0.1 m) and elevations one, so a day of skiing stays far
/// under the server's 2 MB limit.
public enum DescentTrackCodec {
    public enum CodecError: Error, Equatable, Sendable {
        case empty
        case compression(Int32)
        case malformed
    }

    static let version = 1

    public static func encode(_ descent: Descent) throws(CodecError) -> Data {
        let timed = descent.points.compactMap { point in point.timestamp.map { (point, $0) } }
        guard let first = timed.first?.1 else { throw .empty }
        let t0 = (first.timeIntervalSince1970 * 10).rounded() / 10

        var json = "{\"v\":\(version),\"t0\":\(number(t0, places: 1)),\"p\":["
        json.reserveCapacity(timed.count * 40)
        for (index, (point, time)) in timed.enumerated() {
            if index > 0 { json += "," }
            json += "[\(number(time.timeIntervalSince1970 - t0, places: 1)),"
            json += "\(number(point.lat, places: 6)),\(number(point.lon, places: 6)),"
            json += point.elevationM.map { number($0, places: 1) } ?? "null"
            json += "]"
        }
        json += "]}"
        return try gzip(Data(json.utf8))
    }

    /// A track with no points, starting at `start`: the stored form of a run
    /// known only by its summary (the older PowderMeet backup format carries
    /// no GPS).
    /// `decode` reads it back as no points.
    public static func encodeEmpty(startingAt start: Date) throws(CodecError) -> Data {
        let t0 = (start.timeIntervalSince1970 * 10).rounded() / 10
        return try gzip(Data("{\"v\":\(version),\"t0\":\(number(t0, places: 1)),\"p\":[]}".utf8))
    }

    /// The points of a stored track, for re-matching a descent later.
    public static func decode(_ data: Data, limit: Int = 32 * 1_024 * 1_024) throws(CodecError) -> [TrackPoint] {
        let raw = try gunzip(data, limit: limit)
        struct Document: Decodable {
            var v: Int
            var t0: Double
            var p: [[Double?]]
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: raw)
        } catch {
            throw .malformed
        }
        guard document.v == version else { throw .malformed }
        var points: [TrackPoint] = []
        points.reserveCapacity(document.p.count)
        for row in document.p {
            guard row.count == 4, let dt = row[0], let lat = row[1], let lon = row[2] else { throw .malformed }
            points.append(TrackPoint(
                lat: lat, lon: lon, elevationM: row[3],
                timestamp: Date(timeIntervalSince1970: document.t0 + dt)
            ))
        }
        return points
    }

    /// Fixed decimals without a locale, and without the exponent `Double`'s own
    /// description uses for small values.
    private static func number(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "0" }
        var scale = 1.0
        for _ in 0..<places { scale *= 10 }
        let scaled = Int64((value * scale).rounded())
        let whole = abs(scaled) / Int64(scale)
        let fraction = abs(scaled) % Int64(scale)
        let digits = String(fraction)
        let padded = String(repeating: "0", count: max(0, places - digits.count)) + digits
        return (scaled < 0 ? "-" : "") + "\(whole)" + (places > 0 ? "." + padded : "")
    }

    private static func gzip(_ input: Data) throws(CodecError) -> Data {
        var stream = z_stream()
        // 16 + MAX_WBITS writes the gzip wrapper (header and CRC-32 trailer).
        let status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw .compression(status) }
        defer { deflateEnd(&stream) }

        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(input.count))) + 32)
        var bytes = [UInt8](input)
        let capacity = output.count
        let (result, written): (Int32, Int) = bytes.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress
                stream.avail_in = UInt32(source.count)
                stream.next_out = target.baseAddress
                stream.avail_out = UInt32(capacity)
                let result = deflate(&stream, Z_FINISH)
                return (result, capacity - Int(stream.avail_out))
            }
        }
        guard result == Z_STREAM_END else { throw .compression(result) }
        return Data(output[0..<written])
    }

    private static func gunzip(_ input: Data, limit: Int) throws(CodecError) -> Data {
        var stream = z_stream()
        let status = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw .compression(status) }
        defer { inflateEnd(&stream) }

        var bytes = [UInt8](input)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        let chunkSize = chunk.count
        var failure: CodecError?
        bytes.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = UInt32(source.count)
            while true {
                let (result, produced): (Int32, Int) = chunk.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    return (result, chunkSize - Int(stream.avail_out))
                }
                guard result == Z_OK || result == Z_STREAM_END else {
                    failure = .compression(result)
                    return
                }
                output.append(contentsOf: chunk[0..<produced])
                if output.count > limit || (result == Z_OK && produced == 0 && stream.avail_in == 0) {
                    failure = .malformed
                    return
                }
                if result == Z_STREAM_END { return }
            }
        }
        if let failure { throw failure }
        return output
    }
}
