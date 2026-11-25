import CZlib
import Foundation

public enum ZipReaderError: Error, Sendable, Equatable {
    case notAZipArchive
    case eocdNotFound
    case truncated
    case unsupportedCompression(method: UInt16)
    case zip64Unsupported
    case encrypted
    case decompressionFailed
    case tooLarge(limit: Int)
}

/// Minimal read-only PKZIP reader: stored (method 0) and deflate (method 8)
/// entries, no encryption, no Zip64. Enough for `.slopes` and `.skiz` exports, the
/// only archives this package opens.
///
/// Only the structures needed are read: the End of Central Directory record,
/// the Central Directory file headers and the Local File headers.
struct ZipReader {
    struct Entry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let compressionMethod: UInt16
        let localHeaderOffset: Int
        let crc32: UInt32

        /// Directory entries have a name ending in "/" and no payload.
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Largest entry this reader will inflate. A Slopes export is a few
    /// megabytes; the cap stops a small hostile archive expanding without
    /// bound, and keeps the text parsed from it (several times its size in
    /// strings) well inside a phone's memory.
    static let maximumEntryBytes = 64 * 1_024 * 1_024
    /// Output grows by this much at a time, so an entry that declares a huge
    /// size costs only what it really inflates to.
    static let inflateChunkBytes = 256 * 1_024

    private let bytes: [UInt8]
    let entries: [Entry]

    init(data: Data) throws(ZipReaderError) {
        bytes = [UInt8](data)
        entries = try Self.centralDirectory(bytes)
    }

    /// Files, without the `__MACOSX/` and `._` resource forks Finder adds when
    /// it zips a folder: they carry the real file's name but none of its data.
    var fileEntries: [Entry] {
        entries.filter { entry in
            let last = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
            return !entry.isDirectory && !entry.name.hasPrefix("__MACOSX/") && !last.hasPrefix("._")
        }
    }

    func entry(named name: String) -> Entry? {
        fileEntries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A file by its last path component, so an archive that wraps its
    /// contents in a folder still resolves.
    func entry(baseName: String) -> Entry? {
        entry(named: baseName) ?? fileEntries.first { entry in
            let last = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
            return last.caseInsensitiveCompare(baseName) == .orderedSame
        }
    }

    /// First file whose name ends in one of the extensions, case-insensitively.
    func firstEntry(withExtensions extensions: [String]) -> Entry? {
        let suffixes = extensions.map { "." + $0.lowercased() }
        return fileEntries.first { entry in
            let name = entry.name.lowercased()
            return suffixes.contains { name.hasSuffix($0) }
        }
    }

    /// First file whose payload starts with the SQLite header, for an inner
    /// database with no recognisable extension.
    func firstSQLiteEntry() throws(ZipReaderError) -> Entry? {
        let magic = Array("SQLite format 3".utf8)
        for entry in fileEntries where entry.uncompressedSize >= magic.count {
            if Array(try read(entry, maxBytes: 16).prefix(magic.count)) == magic { return entry }
        }
        return nil
    }

    /// The entry's payload. `maxBytes` caps the output, so sniffing a header
    /// does not inflate a whole entry. A full read is checked against the
    /// stored CRC-32.
    func read(_ entry: Entry, maxBytes: Int? = nil) throws(ZipReaderError) -> Data {
        // Local file header: signature(4) version(2) flags(2) method(2)
        // time(2) date(2) crc(4) compressed(4) uncompressed(4) nameLen(2)
        // extraLen(2), then name, extra and payload.
        let header = entry.localHeaderOffset
        guard header >= 0, header <= bytes.count - 30 else { throw .truncated }
        guard Self.u32(bytes, header) == 0x0403_4b50 else { throw .notAZipArchive }
        guard Self.u16(bytes, header + 6) & 0x0001 == 0 else { throw .encrypted }
        let payloadStart = header + 30 + Int(Self.u16(bytes, header + 26)) + Int(Self.u16(bytes, header + 28))
        guard entry.compressedSize <= bytes.count, payloadStart <= bytes.count - entry.compressedSize else {
            throw .truncated
        }
        let payload = bytes[payloadStart..<(payloadStart + entry.compressedSize)]

        if maxBytes == nil, entry.uncompressedSize > Self.maximumEntryBytes {
            throw .tooLarge(limit: Self.maximumEntryBytes)
        }
        let output: [UInt8]
        switch entry.compressionMethod {
        case 0:
            output = Array(maxBytes.map { payload.prefix($0) } ?? payload)
        case 8:
            output = try Self.inflateRaw(
                payload, capacity: min(maxBytes ?? .max, entry.uncompressedSize)
            )
        default:
            throw .unsupportedCompression(method: entry.compressionMethod)
        }
        if maxBytes == nil {
            guard output.count == entry.uncompressedSize, Self.crc(output) == entry.crc32 else {
                throw .decompressionFailed
            }
        }
        return Data(output)
    }

    // MARK: - Central directory

    private static func centralDirectory(_ bytes: [UInt8]) throws(ZipReaderError) -> [Entry] {
        guard bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4b else { throw .notAZipArchive }
        guard bytes.count >= 22 else { throw .truncated }

        // The end record sits within the last 65,535 + 22 bytes (maximum
        // comment plus the record itself); scan backward for its signature.
        var eocd = -1
        let lowest = max(0, bytes.count - 65_557)
        var index = bytes.count - 22
        while index >= lowest {
            if u32(bytes, index) == 0x0605_4b50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw .eocdNotFound }

        // End record: signature(4) disk(2) cdDisk(2) entriesHere(2) total(2)
        // cdSize(4) cdOffset(4) commentLen(2).
        let total = u16(bytes, eocd + 10)
        let directoryOffset = u32(bytes, eocd + 16)
        if directoryOffset == 0xffff_ffff || total == 0xffff { throw .zip64Unsupported }

        var cursor = Int(directoryOffset)
        var entries: [Entry] = []
        entries.reserveCapacity(Int(total))
        for _ in 0..<total {
            // Central header: signature(4) madeBy(2) needed(2) flags(2)
            // method(2) time(2) date(2) crc(4) compressed(4) uncompressed(4)
            // nameLen(2) extraLen(2) commentLen(2) disk(2) internal(2)
            // external(4) localOffset(4), then name, extra and comment.
            guard cursor <= bytes.count - 46 else { throw .truncated }
            guard u32(bytes, cursor) == 0x0201_4b50 else { throw .truncated }
            let flags = u16(bytes, cursor + 8)
            let compressed = u32(bytes, cursor + 20)
            let uncompressed = u32(bytes, cursor + 24)
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = u32(bytes, cursor + 42)
            if compressed == 0xffff_ffff || uncompressed == 0xffff_ffff || localOffset == 0xffff_ffff {
                throw .zip64Unsupported
            }
            if flags & 0x0001 != 0 { throw .encrypted }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { throw .truncated }
            // Flag bit 11 marks UTF-8 names; otherwise CP437, which agrees
            // with UTF-8 for the ASCII paths Slopes writes.
            entries.append(Entry(
                name: String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self),
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed),
                compressionMethod: u16(bytes, cursor + 10),
                localHeaderOffset: Int(localOffset),
                crc32: u32(bytes, cursor + 16)
            ))
            cursor = nameEnd + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Deflate

    /// Inflates a raw deflate stream (no zlib header or trailer), which is what
    /// PKZIP stores for method 8. Stops once `capacity` bytes are produced.
    private static func inflateRaw(
        _ input: ArraySlice<UInt8>, capacity: Int
    ) throws(ZipReaderError) -> [UInt8] {
        if capacity == 0 { return [] }
        var stream = z_stream()
        // Negative window bits select a raw stream.
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw .decompressionFailed }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: min(capacity, inflateChunkBytes))
        var status: Int32 = Z_OK
        input.withUnsafeBufferPointer { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            stream.avail_in = UInt32(source.count)
            while output.count < capacity {
                let room = min(chunk.count, capacity - output.count)
                let produced: Int = chunk.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = UInt32(room)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return room - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
                // Z_BUF_ERROR or no output: the input ran out before the stream ended.
                if status != Z_OK || produced == 0 { break }
            }
        }
        // A full buffer is the expected end of a capped read.
        let filled = output.count == capacity
        guard status == Z_STREAM_END || (filled && (status == Z_OK || status == Z_BUF_ERROR)) else {
            throw .decompressionFailed
        }
        return output
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var value = crc32(0, nil, 0)
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let chunk = min(buffer.count - offset, 1 << 30)
                value = crc32(value, buffer.baseAddress.map { $0 + offset }, UInt32(chunk))
                offset += chunk
            }
        }
        return UInt32(truncatingIfNeeded: value)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
