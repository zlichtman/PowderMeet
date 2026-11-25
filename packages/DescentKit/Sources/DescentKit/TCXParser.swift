import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Garmin TCX: `<Activities>` → `<Activity>` → `<Lap>` → `<Track>` →
/// `<Trackpoint>`. Each `<Lap>` becomes one `ParsedSegment` carrying the lap's
/// native statistics (start, total time, distance, maximum speed) and the
/// trackpoints inside it. A lap is a provider hint, not a physical ski run;
/// `DescentSegmenter` validates and splits it.
public enum TCXParser: ActivityParser {
    public static let source = ActivitySource.tcx

    public static func parse(_ data: Data) throws(ActivityParseError) -> ParsedActivity {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        // A streaming parser can emit an earlier lap before a malformed suffix
        // is found. Reject the whole file rather than return a partial one.
        guard parser.parse() else {
            throw .malformed(parser.parserError.map { "\($0)" } ?? "TCX is not well-formed XML")
        }
        guard handler.sawRoot else { throw .notThisFormat }
        // TCX has no resort field; the activity id serves as a label.
        return ParsedActivity(
            source: .tcx, resortName: handler.activityName, segments: handler.laps,
            sourceApp: handler.creatorName, declared: DeclaredTotals(sport: handler.sport),
            assumedUTC: handler.assumedUTC
        )
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var sawRoot = false
        var laps: [ParsedSegment] = []
        var activityName: String?
        /// `<Creator><Name>` (the device) or, failing that, `<Author><Name>`.
        var creatorName: String?
        /// The first `<Activity Sport="...">`: Running, Biking or Other.
        var sport: String?
        var assumedUTC = false
        private var insideCreator = false
        private var insideAuthor = false

        private let dates = ISO8601Reader()
        private var lapPoints: [TrackPoint] = []
        private var lat: Double?
        private var lon: Double?
        private var elevation: Double?
        private var time: Date?
        private var speed: Double?

        private var lapStartTime: Date?
        private var lapTotalTimeS: Double?
        private var lapDistanceM: Double?
        private var lapMaximumSpeed: Double?
        private var insideLap = false
        private var lapNumber = 0

        private var insideTrackpoint = false
        private var insidePosition = false
        private var insideExtensions = false
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            switch xmlLocalName(elementName) {
            case "TrainingCenterDatabase":
                sawRoot = true
            case "Activity":
                if sport == nil, let name = attributeDict["Sport"], !name.isEmpty { sport = name }
            case "Lap":
                insideLap = true
                lapNumber += 1
                lapStartTime = attributeDict["StartTime"].flatMap { dates.lenientDate($0)?.date }
                lapTotalTimeS = nil
                lapDistanceM = nil
                lapMaximumSpeed = nil
                lapPoints = []
            case "Trackpoint":
                insideTrackpoint = true
                lat = nil
                lon = nil
                elevation = nil
                time = nil
                speed = nil
            case "Creator":
                insideCreator = true
            case "Author":
                insideAuthor = true
            case "Position":
                insidePosition = true
            case "Extensions":
                insideExtensions = true
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
            switch xmlLocalName(elementName) {
            case "LatitudeDegrees":
                if insidePosition { lat = Double(value) }
            case "LongitudeDegrees":
                if insidePosition { lon = Double(value) }
            case "AltitudeMeters":
                if insideTrackpoint { elevation = Double(value) }
            case "Time":
                if insideTrackpoint, let read = dates.lenientDate(value) {
                    time = read.date
                    if read.assumedUTC { assumedUTC = true }
                }
            case "Name":
                if insideCreator, !value.isEmpty { creatorName = value }
                if insideAuthor, creatorName == nil, !value.isEmpty { creatorName = value }
            case "Creator":
                insideCreator = false
            case "Author":
                insideAuthor = false
            case "Speed":
                // Per-fix m/s lives in <Trackpoint><Extensions><TPX><Speed>.
                if insideTrackpoint, insideExtensions, let s = Double(value), s >= 0 { speed = s }
            case "Position":
                insidePosition = false
            case "Extensions":
                insideExtensions = false
            case "Trackpoint":
                if let lat, let lon {
                    lapPoints.append(TrackPoint(
                        lat: lat, lon: lon, elevationM: elevation, timestamp: time, speedMS: speed
                    ))
                }
                insideTrackpoint = false
            case "TotalTimeSeconds":
                if insideLap, !insideTrackpoint { lapTotalTimeS = Double(value) }
            case "DistanceMeters":
                if insideLap, !insideTrackpoint { lapDistanceM = Double(value) }
            case "MaximumSpeed":
                if insideLap, let s = Double(value), s >= 0 { lapMaximumSpeed = s }
            case "Lap":
                // Emitted even when empty: the segmenter decides what survives.
                let start = lapStartTime ?? lapPoints.first?.timestamp
                let end: Date?
                if let lapStartTime, let lapTotalTimeS {
                    end = lapStartTime.addingTimeInterval(lapTotalTimeS)
                } else {
                    end = lapPoints.last?.timestamp ?? lapStartTime
                }
                let measured = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }
                // Average speed is not in the TCX schema; derive it when the
                // lap recorded both distance and time.
                var average: Double?
                if let d = lapDistanceM, d > 0, let t = lapTotalTimeS, t > 0 { average = d / t }
                laps.append(ParsedSegment(
                    number: lapNumber,
                    startTime: start,
                    endTime: end,
                    durationS: lapTotalTimeS ?? measured,
                    topSpeedMS: lapMaximumSpeed,
                    avgSpeedMS: average,
                    distanceM: lapDistanceM,
                    verticalM: nil,
                    points: lapPoints
                ))
                lapPoints = []
                insideLap = false
            case "Id":
                if activityName == nil, !value.isEmpty { activityName = value }
            default:
                break
            }
        }
    }
}
