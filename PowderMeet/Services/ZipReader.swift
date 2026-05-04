//
//  ZipReader.swift
//  PowderMeet
//
//  Minimal pure-Swift PKZIP reader. Read-only; supports stored
//  (method 0) and deflate (method 8) entries. No encryption, no
//  Zip64 — sufficient for `.slopes` exports from the iOS Slopes app
//  (the only consumer in this codebase).
//
//  Why this exists. iOS doesn't ship a public ZIP-extraction API.
//  The previous `SlopesParser` implementation tried to call a
//  non-existent `FileManager.unzipItem(at:to:)` and only succeeded
//  on macOS via spawning `/usr/bin/unzip` — on iOS it threw a
//  "zip extraction not available" stub, and ANY real `.slopes`
//  file (which the Slopes app exports as a ZIP) failed.
//
//  Format reference: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
//  We only implement the structures we need: the End of Central
//  Directory Record (EOCD), the Central Directory File Headers
//  (CDFH), and the Local File Headers (LFH).
//

import Foundation
import Compression

enum ZipReaderError: LocalizedError {
    case notAZipArchive
    case eocdNotFound
    case truncated
    case unsupportedCompression(method: UInt16)
    case zip64Unsupported
    case encrypted
    case decompressionFailed
    case entryNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "File is not a ZIP archive (no PKZIP signature)."
        case .eocdNotFound:
            return "ZIP archive is missing its end-of-central-directory record."
        case .truncated:
            return "ZIP archive is truncated."
        case .unsupportedCompression(let method):
            return "ZIP entry uses unsupported compression method \(method) (only stored=0 and deflate=8 are supported)."
        case .zip64Unsupported:
            return "ZIP archive uses Zip64 (>4 GB) which isn't supported."
        case .encrypted:
            return "ZIP archive is encrypted."
        case .decompressionFailed:
            return "ZIP entry could not be decompressed (corrupt deflate stream)."
        case .entryNotFound(let name):
            return "ZIP archive does not contain an entry named \(name)."
        }
    }
}

nonisolated struct ZipReader {
    /// One central-directory entry in the archive — name, sizes, and the
    /// byte offset where its local file header (and then its compressed
    /// payload) begins.
    struct Entry {
        let name: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let compressionMethod: UInt16
        let localHeaderOffset: UInt32
        let crc32: UInt32

        var isDirectory: Bool {
            // ZIP convention: directory entries have a name ending in "/"
            // and zero-length payloads. We don't enumerate directories
            // explicitly but skip them when listing files.
            name.hasSuffix("/")
        }
    }

    /// Whole archive, mapped into memory. Slopes exports are typically
    /// 1–50 MB; mapping is fine.
    let data: Data
    let entries: [Entry]

    /// Loads the archive and parses its central directory. Throws on
    /// malformed input; the resulting `ZipReader` can then be queried
    /// for individual entries via `read(_:)`.
    init(url: URL) throws {
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: raw)
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.parseCentralDirectory(in: data)
    }

    /// All entries that are real files (skips directory markers).
    var fileEntries: [Entry] {
        entries.filter { !$0.isDirectory }
    }

    /// Returns the first entry whose name (case-insensitive) ends in any
    /// of the provided extensions. Used by `SlopesParser` to find the
    /// SQLite DB inside a Slopes export without knowing its exact path.
    func firstEntry(withExtensions extensions: [String]) -> Entry? {
        let lowered = extensions.map { $0.lowercased() }
        for entry in fileEntries {
            let lowerName = entry.name.lowercased()
            if lowered.contains(where: { lowerName.hasSuffix("." + $0) }) {
                return entry
            }
        }
        return nil
    }

    /// Returns the first entry whose decompressed payload starts with
    /// the SQLite magic header — useful when the inner DB has no
    /// recognisable extension.
    func firstSQLiteEntry() throws -> Entry? {
        for entry in fileEntries {
            let bytes = try read(entry, maxBytes: 16)
            let header = String(data: bytes.prefix(15), encoding: .utf8)
            if header == "SQLite format 3" { return entry }
        }
        return nil
    }

    /// Decompresses the entry's payload and returns the bytes.
    /// `maxBytes`, when non-nil, caps the output and is used by the
    /// SQLite-magic sniff above so we don't decompress an entire 50 MB
    /// entry just to inspect 16 bytes.
    func read(_ entry: Entry, maxBytes: Int? = nil) throws -> Data {
        let lfhOffset = Int(entry.localHeaderOffset)
        guard lfhOffset + 30 <= data.count else { throw ZipReaderError.truncated }

        // Local File Header layout:
        //   0    signature       PK\x03\x04           (4 bytes)
        //   4    version          (2)
        //   6    flags            (2)
        //   8    method           (2)
        //   10   modtime          (2)
        //   12   moddate          (2)
        //   14   crc32            (4)
        //   18   compressedSize   (4)
        //   22   uncompressedSize (4)
        //   26   nameLength       (2)
        //   28   extraLength      (2)
        //   30   name + extra + payload
        let signature = data.readU32(at: lfhOffset)
        guard signature == 0x04034b50 else { throw ZipReaderError.notAZipArchive }
        let flags = data.readU16(at: lfhOffset + 6)
        guard (flags & 0x0001) == 0 else { throw ZipReaderError.encrypted }
        let nameLen = Int(data.readU16(at: lfhOffset + 26))
        let extraLen = Int(data.readU16(at: lfhOffset + 28))
        let payloadStart = lfhOffset + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadEnd <= data.count else { throw ZipReaderError.truncated }
        let payload = data.subdata(in: payloadStart..<payloadEnd)

        switch entry.compressionMethod {
        case 0:
            // Stored — payload IS the file.
            if let cap = maxBytes { return payload.prefix(cap) }
            return payload
        case 8:
            // Deflate — Apple's Compression framework with `.zlib`
            // expects a raw deflate stream (no zlib header), which is
            // exactly what PKZIP stores.
            return try inflate(payload, uncompressedSize: Int(entry.uncompressedSize), maxBytes: maxBytes)
        default:
            throw ZipReaderError.unsupportedCompression(method: entry.compressionMethod)
        }
    }

    // MARK: - Central directory parsing

    /// Scans backward from the end of the archive for the End of
    /// Central Directory signature, then walks the central directory
    /// it points at. The EOCD must lie within the last 65 KiB + 22 B
    /// of the file (max comment length plus EOCD size).
    private static func parseCentralDirectory(in data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipReaderError.truncated }

        // Scan backward up to (65535 + 22) bytes for the EOCD signature.
        let scanLimit = min(data.count, 65557)
        let scanStart = data.count - scanLimit
        var eocdOffset: Int = -1
        for i in stride(from: data.count - 22, through: scanStart, by: -1) {
            if data.readU32(at: i) == 0x06054b50 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { throw ZipReaderError.eocdNotFound }

        // EOCD layout:
        //   0   signature        PK\x05\x06    (4 bytes)
        //   4   thisDiskNumber   (2)
        //   6   diskWithCD       (2)
        //   8   entriesOnThisDisk (2)
        //   10  totalEntries     (2)
        //   12  centralDirSize   (4)
        //   16  centralDirOffset (4)
        //   20  commentLength    (2)
        let totalEntries = data.readU16(at: eocdOffset + 10)
        let centralDirOffset = data.readU32(at: eocdOffset + 16)

        // Zip64 escape values — we don't support those.
        if centralDirOffset == 0xffffffff || totalEntries == 0xffff {
            throw ZipReaderError.zip64Unsupported
        }

        var cursor = Int(centralDirOffset)
        var entries: [Entry] = []
        entries.reserveCapacity(Int(totalEntries))

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count else { throw ZipReaderError.truncated }

            // Central Directory File Header layout:
            //   0   signature       PK\x01\x02   (4 bytes)
            //   4   versionMadeBy   (2)
            //   6   versionNeeded   (2)
            //   8   flags           (2)
            //   10  method          (2)
            //   12  modtime         (2)
            //   14  moddate         (2)
            //   16  crc32           (4)
            //   20  compressedSize  (4)
            //   24  uncompressedSize(4)
            //   28  nameLength      (2)
            //   30  extraLength     (2)
            //   32  commentLength   (2)
            //   34  diskNumberStart (2)
            //   36  internalAttrs   (2)
            //   38  externalAttrs   (4)
            //   42  localHeaderOffset(4)
            //   46  name + extra + comment
            let signature = data.readU32(at: cursor)
            guard signature == 0x02014b50 else { throw ZipReaderError.truncated }

            let flags = data.readU16(at: cursor + 8)
            let method = data.readU16(at: cursor + 10)
            let crc32 = data.readU32(at: cursor + 16)
            let compSize = data.readU32(at: cursor + 20)
            let uncompSize = data.readU32(at: cursor + 24)
            let nameLen = Int(data.readU16(at: cursor + 28))
            let extraLen = Int(data.readU16(at: cursor + 30))
            let commentLen = Int(data.readU16(at: cursor + 32))
            let lhOffset = data.readU32(at: cursor + 42)

            // Reject Zip64-escaped fields and encrypted entries up front.
            if compSize == 0xffffffff || uncompSize == 0xffffffff || lhOffset == 0xffffffff {
                throw ZipReaderError.zip64Unsupported
            }
            if (flags & 0x0001) != 0 {
                throw ZipReaderError.encrypted
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { throw ZipReaderError.truncated }
            let nameBytes = data.subdata(in: nameStart..<nameEnd)
            // Bit 11 of the flags signals UTF-8 names; otherwise CP437,
            // but ASCII-compatible filenames decode the same either way
            // and Slopes exports always use ASCII paths.
            let name = String(data: nameBytes, encoding: .utf8)
                ?? String(data: nameBytes, encoding: .ascii)
                ?? ""

            entries.append(Entry(
                name: name,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                compressionMethod: method,
                localHeaderOffset: lhOffset,
                crc32: crc32
            ))

            cursor = nameEnd + extraLen + commentLen
        }

        return entries
    }

    // MARK: - Deflate

    /// Wraps `compression_decode_buffer` with `COMPRESSION_ZLIB`.
    /// Despite the name, Apple's `COMPRESSION_ZLIB` is the raw deflate
    /// algorithm (no 2-byte zlib header, no Adler-32 trailer) — which
    /// is exactly what PKZIP stores in method-8 entries.
    private func inflate(_ compressed: Data, uncompressedSize: Int, maxBytes: Int?) throws -> Data {
        let outputCapacity = maxBytes.map { min($0, uncompressedSize) } ?? uncompressedSize
        // Empty output is valid (zero-length entry). compression_decode_buffer
        // returns 0 in that case, which we'd otherwise read as failure.
        if outputCapacity == 0 { return Data() }

        let result = compressed.withUnsafeBytes { (compIn: UnsafeRawBufferPointer) -> Data? in
            guard let compBase = compIn.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var out = Data(count: outputCapacity)
            let written = out.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int in
                guard let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    outBase, outputCapacity,
                    compBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
            if written == 0 { return nil }
            out.count = written
            return out
        }

        guard let result else { throw ZipReaderError.decompressionFailed }
        return result
    }
}

// MARK: - Little-endian Data readers

private nonisolated extension Data {
    func readU16(at offset: Int) -> UInt16 {
        let lo = UInt16(self[offset])
        let hi = UInt16(self[offset + 1])
        return lo | (hi << 8)
    }

    func readU32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
