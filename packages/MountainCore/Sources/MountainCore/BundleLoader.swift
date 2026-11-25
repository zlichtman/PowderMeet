import Foundation

public enum BundleLoadError: Error, Equatable, Sendable {
    case compressedSizeExceeded(actual: Int, limit: Int)
    case sha256Mismatch(expected: BundleID, actual: String)
    case notGzip
    case corruptGzip
    case decodedSizeExceeded(limit: Int)
    case decodingFailed(String)
    case unsupportedSchema(Int)
    case integrity(BundleIntegrityError)
}

public enum BundleLoader {
    public static let maximumCompressedBytes = 16 * 1_024 * 1_024
    public static let maximumDecodedBytes = 64 * 1_024 * 1_024

    /// Verifies, inflates, decodes and validates a stored bundle, in that order:
    /// nothing is decompressed until the bytes hash to `expectedID`.
    public static func load(data: Data, expectedID: BundleID) throws -> ResortBundle {
        try load(
            data: data, expectedID: expectedID,
            maximumCompressedBytes: maximumCompressedBytes,
            maximumDecodedBytes: maximumDecodedBytes
        )
    }

    static func load(
        data: Data, expectedID: BundleID, maximumCompressedBytes: Int, maximumDecodedBytes: Int
    ) throws -> ResortBundle {
        guard data.count <= maximumCompressedBytes else {
            throw BundleLoadError.compressedSizeExceeded(
                actual: data.count, limit: maximumCompressedBytes
            )
        }
        let actual = SHA256.hex(data)
        guard actual == expectedID.rawValue else {
            throw BundleLoadError.sha256Mismatch(expected: expectedID, actual: actual)
        }

        let json: Data
        do {
            json = try Gzip.gunzip(data, limit: maximumDecodedBytes)
        } catch GzipError.tooLarge {
            throw BundleLoadError.decodedSizeExceeded(limit: maximumDecodedBytes)
        } catch GzipError.notGzip {
            throw BundleLoadError.notGzip
        } catch {
            throw BundleLoadError.corruptGzip
        }

        // The version first: a newer format may not decode as this one at
        // all, and then the skier must be told to update, not shown a failure.
        let document: BundleDocument
        do {
            let version = try BundleCoding.decoder().decode(SchemaProbe.self, from: json).schemaVersion
            guard ResortBundle.supportedBundleSchemas.contains(version) else {
                throw BundleLoadError.unsupportedSchema(version)
            }
            document = try BundleDocument.decode(json)
        } catch let error as BundleLoadError {
            throw error
        } catch {
            throw BundleLoadError.decodingFailed(String(describing: error))
        }

        let bundle = ResortBundle(id: expectedID, document: document)
        do {
            _ = try BundleIntegrity.validate(bundle)
        } catch let error as BundleIntegrityError {
            throw BundleLoadError.integrity(error)
        }
        return bundle
    }
}

/// Only the version of a bundle document, readable whatever else changed.
private struct SchemaProbe: Decodable {
    var schemaVersion: Int

    private enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
}
