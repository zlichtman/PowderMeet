import CZlib
import Foundation

enum GzipError: Error, Equatable {
    case notGzip
    case corrupt(Int32)
    case tooLarge(limit: Int)
}

enum Gzip {
    /// Inflates an RFC 1952 container, stopping as soon as the output would pass
    /// `limit` so a small hostile payload cannot expand without bound.
    static func gunzip(_ data: Data, limit: Int) throws -> Data {
        guard data.count >= 18, data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b else { throw GzipError.notGzip }

        var stream = z_stream()
        // 16 + MAX_WBITS selects the gzip wrapper (header and CRC-32 trailer).
        let initStatus = inflateInit2_(
            &stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw GzipError.corrupt(initStatus) }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 256 * 1_024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK

        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(
                mutating: input.bindMemory(to: UInt8.self).baseAddress
            )
            stream.avail_in = UInt32(input.count)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw GzipError.corrupt(status)
                }
                guard output.count + produced <= limit else {
                    throw GzipError.tooLarge(limit: limit)
                }
                output.append(contentsOf: chunk[0..<produced])
                if status == Z_OK, produced == 0, stream.avail_in == 0 {
                    throw GzipError.corrupt(Z_BUF_ERROR)   // truncated stream
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}
