//
//  GPXParser.swift
//  PowderMeet
//
//  SAX-style XML parser for GPX track files.
//  Handles <trk> / <trkseg> / <trkpt> nesting.
//

import Foundation

// GPXTrackPoint and GPXTrack are defined in ActivityModels.swift

// MARK: - Parser

nonisolated final class GPXParser: NSObject, XMLParserDelegate {
    private var tracks: [GPXTrack] = []
    private var currentTrack: GPXTrack?
    private var segmentPoints: [GPXTrackPoint] = []
    /// Per-segment buckets — preserved separately so the unified parser
    /// can emit one ParsedRunSegment per `<trkseg>` when an exporter
    /// uses segments as run delimiters. (Strava GPX is typically single-
    /// segment; the importer post-segments via TrailMatcher.)
    private var trackSegments: [[GPXTrackPoint]] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var currentSpeed: Double?
    private var currentElement = ""
    private var currentText = ""
    private var insideTrack = false
    private var insideExtensions = false

    nonisolated private static func parseTimestamp(_ text: String) -> Date? {
        ISO8601Parser.parse(text)
    }

    // MARK: - Public API

    static func parse(data: Data) -> [GPXTrack] {
        let handler = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        // Ignoring the return value silently swallows malformed XML —
        // callers get an empty `[GPXTrack]` and no hint why. Log so import
        // errors aren't invisible.
        if !parser.parse() {
            if let error = parser.parserError {
                print("[GPXParser] parse error: \(error.localizedDescription) at line \(parser.lineNumber), col \(parser.columnNumber)")
            } else {
                print("[GPXParser] parse failed with no error object")
            }
        }
        return handler.tracks
    }

    /// Unified entry — emits one `ParsedRunSegment` per `<trkseg>` when
    /// the file uses segments as run delimiters (some exporters do).
    /// When there's only a single segment (the Strava-typical case), the
    /// parser still emits one segment containing every point — the
    /// importer post-segments via elevation when it has the runtime
    /// context (the parser doesn't, by design — we keep parsers pure
    /// and free of TrailMatcher / graph dependencies).
    ///
    /// GPX has no native per-run stats (top speed, distance, vertical),
    /// so all stat fields stay nil. The importer derives them from the
    /// raw `points` if the segments aren't re-segmented.
    static func parseUnified(data: Data, sourceFileHash: String) -> ParsedActivity {
        let handler = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        _ = parser.parse()

        var segments: [ParsedRunSegment] = []
        for (idx, points) in handler.trackSegments.enumerated() {
            guard !points.isEmpty else { continue }
            let start = points.first?.timestamp ?? Date()
            let end = points.last?.timestamp ?? start
            segments.append(ParsedRunSegment(
                runNumber: idx + 1,
                startTime: start,
                endTime: end,
                durationSeconds: end.timeIntervalSince(start),
                topSpeedMS: nil,
                avgSpeedMS: nil,
                distanceMeters: nil,
                verticalMeters: nil,
                points: points
            ))
        }
        return ParsedActivity(
            source: .gpx,
            resortName: handler.tracks.first?.name,
            sourceFileHash: sourceFileHash,
            segments: segments
        )
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        // Strip namespace prefix to local name (see didEndElement comment).
        let localName: String
        if let colon = elementName.lastIndex(of: ":") {
            localName = String(elementName[elementName.index(after: colon)...])
        } else {
            localName = elementName
        }

        switch localName {
        case "trk":
            currentTrack = GPXTrack(name: nil, points: [])
            insideTrack = true
        case "trkseg":
            segmentPoints = []
        case "trkpt":
            currentLat = Double(attributes["lat"] ?? "")
            currentLon = Double(attributes["lon"] ?? "")
            currentEle = nil
            currentTime = nil
            currentSpeed = nil
        case "extensions":
            insideExtensions = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Namespace-stripped local name. `XMLParser` by default doesn't
        // process namespaces, so Garmin's `<gpxtpx:speed>` arrives as
        // the literal `"gpxtpx:speed"` and a plain `case "speed":` would
        // never fire. Strip everything up to and including the colon
        // so any namespace prefix (gpxtpx, ns3, custom-vendor) maps
        // back to the bare local element.
        let localName: String
        if let colon = elementName.lastIndex(of: ":") {
            localName = String(elementName[elementName.index(after: colon)...])
        } else {
            localName = elementName
        }
        switch localName {
        case "name":
            // Only capture track name, not waypoint names
            if insideTrack && segmentPoints.isEmpty {
                currentTrack?.name = text
            }
        case "ele":
            currentEle = Double(text)
        case "time":
            currentTime = GPXParser.parseTimestamp(text)
        case "speed":
            // Standard GPX 1.1 <speed> AND Garmin's <gpxtpx:speed>.
            // The localName strip above makes both land here.
            if let s = Double(text), s >= 0 { currentSpeed = s }
        case "extensions":
            insideExtensions = false
        case "trkpt":
            if let lat = currentLat, let lon = currentLon {
                segmentPoints.append(GPXTrackPoint(
                    latitude: lat,
                    longitude: lon,
                    elevation: currentEle,
                    timestamp: currentTime,
                    speed: currentSpeed
                ))
            }
            currentLat = nil
            currentLon = nil
        case "trkseg":
            // Legacy flat output: append into the current track. Unified
            // output: stash the segment as its own bucket so we can emit
            // one ParsedRunSegment per <trkseg>.
            currentTrack?.points.append(contentsOf: segmentPoints)
            if !segmentPoints.isEmpty {
                trackSegments.append(segmentPoints)
            }
            segmentPoints = []
        case "trk":
            if let track = currentTrack {
                tracks.append(track)
            }
            currentTrack = nil
            insideTrack = false
        default:
            break
        }
    }
}
