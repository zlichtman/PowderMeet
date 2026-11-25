import Foundation
import MountainCore

/// Where a descent came from (`specs/02-DOMAIN.md` section 8). Provenance only:
/// it is not part of a descent's identity, which is its content hash.
public enum ActivitySource: String, Codable, Sendable, Hashable, CaseIterable {
    case live, slopes, gpx, tcx, fit, healthkit
}

/// One GPS sample. Parsers report what the file says, so everything but the
/// position is optional; descents produced by `DescentSegmenter` contain only
/// points with a timestamp.
public struct TrackPoint: Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double
    public var elevationM: Double?
    public var timestamp: Date?
    /// Device-reported ground speed in m/s, when the format carries one.
    public var speedMS: Double?

    public init(
        lat: Double, lon: Double, elevationM: Double? = nil,
        timestamp: Date? = nil, speedMS: Double? = nil
    ) {
        self.lat = lat
        self.lon = lon
        self.elevationM = elevationM
        self.timestamp = timestamp
        self.speedMS = speedMS
    }

    public var coordinate: Coordinate { Coordinate(lon: lon, lat: lat) }
}

/// How much authority the source container has over a segment's boundaries.
/// Tracks and laps are hints: `DescentSegmenter` ignores where they start and
/// end and finds the runs physically. A Slopes `Run` action or a Ski Tracks
/// ski-run segment is the provider's own run list; it is kept when the track
/// agrees it is one ski run and corrected when it is not (a drive, a gondola
/// download, several laps under one label).
public enum SegmentBoundary: Sendable, Hashable {
    case providerHint
    case authoritativeDownhillRun
}

/// One run, lap or track as the source file describes it, with the native
/// per-run statistics when the format recorded them (Slopes actions, TCX
/// laps, FIT lap messages). GPX has none.
public struct ParsedSegment: Sendable, Hashable {
    /// 1-based index in the file; 0 for a segment the parser synthesized.
    public var number: Int
    public var startTime: Date?
    public var endTime: Date?
    public var durationS: Double?
    public var topSpeedMS: Double?
    public var avgSpeedMS: Double?
    public var distanceM: Double?
    public var verticalM: Double?
    public var points: [TrackPoint]
    public var boundary: SegmentBoundary

    public init(
        number: Int, startTime: Date?, endTime: Date?, durationS: Double?,
        topSpeedMS: Double? = nil, avgSpeedMS: Double? = nil, distanceM: Double? = nil,
        verticalM: Double? = nil, points: [TrackPoint],
        boundary: SegmentBoundary = .providerHint
    ) {
        self.number = number
        self.startTime = startTime
        self.endTime = endTime
        self.durationS = durationS
        self.topSpeedMS = topSpeedMS
        self.avgSpeedMS = avgSpeedMS
        self.distanceM = distanceM
        self.verticalM = verticalM
        self.points = points
        self.boundary = boundary
    }
}

/// What every parser produces. `DescentSegmenter` turns it into descents; no
/// code downstream of a parser branches on the file format.
public struct ParsedActivity: Sendable, Hashable {
    public var source: ActivitySource
    /// Name the file itself supplies (Slopes carries the resort; GPX a track
    /// name; TCX its activity id). A label, never an identity.
    public var resortName: String?
    public var segments: [ParsedSegment]
    /// The app or device that wrote the file, as the file names it: a GPX
    /// `creator`, a FIT manufacturer, "Slopes", "Ski Tracks". A label only.
    public var sourceApp: String?
    /// Every fix in the file, in file order, when `segments` covers only part
    /// of the recording (a provider run list). Empty otherwise.
    public var fullTrack: [TrackPoint]
    /// What the file says about itself, for display and for checking our own
    /// result. Never copied into a descent.
    public var declared: DeclaredTotals
    /// Timestamps were written without a zone and were read as UTC.
    public var assumedUTC: Bool

    public init(
        source: ActivitySource, resortName: String? = nil, segments: [ParsedSegment],
        sourceApp: String? = nil, fullTrack: [TrackPoint] = [],
        declared: DeclaredTotals = DeclaredTotals(), assumedUTC: Bool = false
    ) {
        self.source = source
        self.resortName = resortName
        self.segments = segments
        self.sourceApp = sourceApp
        self.fullTrack = fullTrack
        self.declared = declared
        self.assumedUTC = assumedUTC
    }
}

/// Totals the file's author recorded: a Slopes or Ski Tracks run count, a FIT
/// session's lap count and total descent.
public struct DeclaredTotals: Sendable, Hashable {
    public var runCount: Int?
    public var verticalM: Double?
    /// The sport the file names, if any: FIT `sport` ("alpine_skiing"), TCX
    /// `Activity Sport` ("Biking"), GPX track `<type>` ("cycling").
    public var sport: String?

    public init(runCount: Int? = nil, verticalM: Double? = nil, sport: String? = nil) {
        self.runCount = runCount
        self.verticalM = verticalM
        self.sport = sport
    }
}

/// Statistics the source recorded for a descent, kept only when plausible.
/// Nil means the source did not say; nothing here is derived from the graph.
public struct DescentStats: Sendable, Hashable {
    public var topSpeedMS: Double?
    public var avgSpeedMS: Double?
    public var distanceM: Double?
    public var verticalM: Double?

    public init(
        topSpeedMS: Double? = nil, avgSpeedMS: Double? = nil,
        distanceM: Double? = nil, verticalM: Double? = nil
    ) {
        self.topSpeedMS = topSpeedMS
        self.avgSpeedMS = avgSpeedMS
        self.distanceM = distanceM
        self.verticalM = verticalM
    }
}

/// One physical downhill run: a raw track with provenance (invariant I-20).
/// Its identity is `DescentHasher.contentHash`; trail matching is a separate,
/// re-runnable derivation.
public struct Descent: Sendable, Hashable {
    public var source: ActivitySource
    public var startedAt: Date
    public var endedAt: Date
    /// In time order. Descents from `DescentSegmenter` have at least two
    /// points and every point has a timestamp.
    public var points: [TrackPoint]
    public var stats: DescentStats

    public init(
        source: ActivitySource, startedAt: Date, endedAt: Date,
        points: [TrackPoint], stats: DescentStats = DescentStats()
    ) {
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.points = points
        self.stats = stats
    }
}

public enum ActivityParseError: Error, Sendable, Equatable {
    /// The bytes are not the format this parser reads.
    case notThisFormat
    /// The file is the right format but damaged. A partial activity is never
    /// returned in its place.
    case malformed(String)
    case archive(ZipReaderError)
    case sqliteOpenFailed
    case sqliteNotFoundInArchive
    case noLocationTable
    case emptyLocationTable
    /// A zip that is neither a Slopes nor a Ski Tracks export.
    case unknownArchive
}

/// A file format reader. Parsers describe what the container says; physical
/// run boundaries belong to `DescentSegmenter`.
public protocol ActivityParser {
    static var source: ActivitySource { get }
    static func parse(_ data: Data) throws(ActivityParseError) -> ParsedActivity
}

/// The formats `DescentKit` reads, with detection by extension and content.
public enum ActivityFormat: String, Sendable, CaseIterable {
    case gpx, tcx, fit, slopes, skiz

    public var parser: any ActivityParser.Type {
        switch self {
        case .gpx: GPXParser.self
        case .tcx: TCXParser.self
        case .fit: FITParser.self
        case .slopes: SlopesParser.self
        case .skiz: SkizParser.self
        }
    }

    /// The extension decides when it is one of ours; otherwise the content is
    /// sniffed, because document providers hand over URLs with no suffix.
    public static func detect(fileName: String?, data: Data) -> ActivityFormat? {
        if let fileName, let dot = fileName.lastIndex(of: "."),
           let known = ActivityFormat(rawValue: fileName[fileName.index(after: dot)...].lowercased()) {
            return known
        }
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 12, Array(bytes[8..<12]) == Array(".FIT".utf8) { return .fit }
        if bytes.count >= 15, Array(bytes[0..<15]) == Array("SQLite format 3".utf8) { return .slopes }
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B {
            // Ski Tracks and Slopes are both zips; the entry names tell them
            // apart. Anything else is left to the Slopes parser to reject.
            do {
                if try ZipReader(data: data).entry(baseName: "Nodes.csv") != nil { return .skiz }
            } catch {
                // A zip that cannot be read is reported by the parser, with
                // the reason; detection only picks which parser that is.
            }
            return .slopes
        }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if containsXMLTag("gpx", in: head) { return .gpx }
        if containsXMLTag("trainingcenterdatabase", in: head) { return .tcx }
        return nil
    }

    /// Matches `<name` or `<prefix:name` followed by a tag delimiter, so vendor
    /// namespace prefixes do not hide the root element.
    private static func containsXMLTag(_ localName: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: localName, range: search) {
            search = found.upperBound..<text.endIndex
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : " "
            guard after == " " || after == ">" || after == "/" || after.isNewline || after == "\t"
            else { continue }
            var cursor = found.lowerBound
            var sawColon = false
            while cursor > text.startIndex {
                cursor = text.index(before: cursor)
                let c = text[cursor]
                if c == "<" { return true }
                if c == ":", !sawColon { sawColon = true; continue }
                guard sawColon, c.isLetter || c.isNumber || c == "_" || c == "-" else { break }
            }
        }
        return false
    }
}

/// ISO 8601 with or without fractional seconds. One instance per parse, so no
/// formatter is shared between concurrent imports.
struct ISO8601Reader {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    /// As `date`, and also accepts a time with no zone (`2026-01-10T11:34:26`,
    /// which some loggers write), read as UTC. `assumedUTC` reports that.
    func lenientDate(_ text: String) -> (date: Date, assumedUTC: Bool)? {
        if let date = date(text) { return (date, false) }
        var candidate = text.replacingOccurrences(of: " ", with: "T")
        guard candidate.count >= 19, candidate.contains("T") else { return nil }
        if let last = candidate.last, last.isNumber, !candidate.dropFirst(19).contains(where: { $0 == "+" || $0 == "-" }) {
            candidate += "Z"
            if let date = date(candidate) { return (date, true) }
        }
        return date(candidate).map { ($0, false) }
    }
}

/// `XMLParser` does not process namespaces by default, so prefixed elements
/// arrive as `gpxtpx:speed` or `ns3:Trackpoint`. Every event is reduced to its
/// local name rather than special-casing vendors.
func xmlLocalName(_ elementName: String) -> String {
    guard let colon = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: colon)...])
}
