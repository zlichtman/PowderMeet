import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// GPX track files: `<trk>` / `<trkseg>` / `<trkpt>`, from Strava, Garmin,
/// Apple Health, Slopes, Ski Tracks and any other logger. One `ParsedSegment`
/// per non-empty `<trkseg>`. Exporters disagree about what a segment means (a
/// run, a lift ride, a pause, the whole day), so `DescentSegmenter` ignores
/// the boundaries and finds the runs in the points. GPX has no per-run
/// statistics. The root `creator` attribute is kept as the source app.
public enum GPXParser: ActivityParser {
    public static let source = ActivitySource.gpx

    public static func parse(_ data: Data) throws(ActivityParseError) -> ParsedActivity {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        // XMLParser streams, so complete tracks may already have been emitted
        // before malformed trailing XML is found. Reject the whole file.
        guard parser.parse() else {
            throw .malformed(parser.parserError.map { "\($0)" } ?? "GPX is not well-formed XML")
        }
        // Foundation on Linux accepts a document that ends inside an element.
        guard handler.openElements == 0 else {
            throw .malformed("GPX ends before its elements are closed")
        }
        guard handler.sawRoot else { throw .notThisFormat }

        var segments: [ParsedSegment] = []
        for (index, points) in handler.trackSegments.enumerated() {
            let start = points.first?.timestamp
            let end = points.last?.timestamp
            segments.append(ParsedSegment(
                number: index + 1,
                startTime: start,
                endTime: end,
                durationS: start.flatMap { s in end.map { $0.timeIntervalSince(s) } },
                points: points
            ))
        }
        return ParsedActivity(
            source: .gpx, resortName: handler.trackName, segments: segments,
            sourceApp: handler.creator, declared: DeclaredTotals(sport: handler.trackType),
            assumedUTC: handler.assumedUTC
        )
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var sawRoot = false
        var openElements = 0
        var creator: String?
        var assumedUTC = false
        var trackName: String?
        /// The first track's `<type>` ("cycling", "alpine_skiing"), as Garmin and Strava write it.
        var trackType: String?
        var trackSegments: [[TrackPoint]] = []

        private let dates = ISO8601Reader()
        private var segmentPoints: [TrackPoint] = []
        private var lat: Double?
        private var lon: Double?
        private var elevation: Double?
        private var time: Date?
        private var speed: Double?
        private var text = ""
        private var insideTrack = false
        private var trackHasPoints = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            openElements += 1
            switch xmlLocalName(elementName) {
            case "gpx":
                sawRoot = true
                if let name = attributeDict["creator"], !name.isEmpty { creator = name }
            case "trk":
                insideTrack = true
                trackHasPoints = false
            case "trkseg":
                segmentPoints = []
            case "trkpt":
                lat = Double(attributeDict["lat"] ?? "")
                lon = Double(attributeDict["lon"] ?? "")
                elevation = nil
                time = nil
                speed = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            openElements -= 1
            switch xmlLocalName(elementName) {
            case "name":
                // The first track's own name, not a waypoint's or a later track's.
                if insideTrack, lat == nil, !value.isEmpty, !trackHasPoints, segmentPoints.isEmpty, trackName == nil {
                    trackName = value
                }
            case "type":
                if insideTrack, lat == nil, !value.isEmpty, trackType == nil { trackType = value }
            case "ele":
                elevation = Double(value)
            case "time":
                if let read = dates.lenientDate(value) {
                    time = read.date
                    if read.assumedUTC, lat != nil { assumedUTC = true }
                } else {
                    time = nil
                }
            case "speed":
                // GPX 1.1 <speed> and Garmin's <gpxtpx:speed> both land here.
                if let s = Double(value), s >= 0 { speed = s }
            case "trkpt":
                if let lat, let lon {
                    segmentPoints.append(TrackPoint(
                        lat: lat, lon: lon, elevationM: elevation, timestamp: time, speedMS: speed
                    ))
                    trackHasPoints = true
                }
                lat = nil
                lon = nil
            case "trkseg":
                if !segmentPoints.isEmpty { trackSegments.append(segmentPoints) }
                segmentPoints = []
            case "trk":
                insideTrack = false
            default:
                break
            }
        }
    }
}
