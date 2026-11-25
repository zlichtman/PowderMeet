import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Ski Tracks exports (`.skiz`): a zip holding
///
/// - `Nodes.csv`, the GPS log, with no header row: time (Unix seconds),
///   latitude, longitude, altitude (m), heading, speed (m/s), horizontal and
///   vertical accuracy. The layout is the same as Slopes' `GPS.csv`.
/// - `Segment.csv`, Ski Tracks' own list of lift rides and ski runs. The first
///   line is a format number; each row then has start and end time (Unix
///   seconds), a numeric type, two counters, a name, a comment and a type
///   string (`ski_run`, `ski_lift`), followed by statistics starting at column
///   11: time, average speed, distance, vertical, maximum speed.
/// - `Track.xml`, with the day's name, time zone and a `<metrics>` block whose
///   `descents` and `totaldescent` are the app's own totals.
///
/// The format is not published. This reader follows two open-source tools
/// that read and write it; no file produced by the app itself was available
/// when it was written. It therefore trusts the run list only when the list
/// lines up with the GPS log, and otherwise hands the whole log to
/// `DescentSegmenter`, which needs nothing but `Nodes.csv`.
public enum SkizParser: ActivityParser {
    /// The server's list of sources (`specs/02-DOMAIN.md` section 8) has no
    /// entry for Ski Tracks, and a descent with an unknown source is refused.
    /// Until one is added there, these descents are filed as third-party GPS
    /// logs; `ParsedActivity.sourceApp` still says "Ski Tracks".
    public static let source = ActivitySource.gpx

    public static func parse(_ data: Data) throws(ActivityParseError) -> ParsedActivity {
        let reader: ZipReader
        do { reader = try ZipReader(data: data) } catch { throw .archive(error) }
        guard let nodesEntry = reader.entry(baseName: "Nodes.csv") else { throw .unknownArchive }
        let nodes: Data
        do { nodes = try reader.read(nodesEntry) } catch { throw .archive(error) }
        let points = SlopesParser.points(fromCSV: nodes)

        var track = TrackInfo()
        if let entry = reader.entry(baseName: "Track.xml") {
            let xml: Data
            do { xml = try reader.read(entry) } catch { throw .archive(error) }
            track = TrackInfo.parse(xml)
        }
        var runs: [ParsedSegment] = []
        if let entry = reader.entry(baseName: "Segment.csv") {
            let csv: Data
            do { csv = try reader.read(entry) } catch { throw .archive(error) }
            runs = try runSegments(fromCSV: csv, points: points)
        }

        let declared = DeclaredTotals(runCount: track.descents, verticalM: track.totalDescentM)
        // A run list that does not land on the GPS log was misread (or written
        // against another clock); the log alone is the safer source then.
        let landed = runs.filter { $0.points.count >= 2 }.count
        if runs.isEmpty || landed * 2 < runs.count {
            let start = points.first?.timestamp
            let end = points.last?.timestamp
            return ParsedActivity(source: source, resortName: track.name, segments: [ParsedSegment(
                number: 1, startTime: start, endTime: end,
                durationS: start.flatMap { s in end.map { $0.timeIntervalSince(s) } },
                points: points
            )], sourceApp: "Ski Tracks", declared: declared)
        }
        return ParsedActivity(
            source: source, resortName: track.name, segments: runs,
            sourceApp: "Ski Tracks", fullTrack: points, declared: declared
        )
    }

    /// The rows Ski Tracks labelled as ski runs, each with the fixes inside
    /// its time window.
    private static func runSegments(
        fromCSV data: Data, points: [TrackPoint]
    ) throws(ActivityParseError) -> [ParsedSegment] {
        var runs: [ParsedSegment] = []
        var windows: [(start: Date, end: Date)] = []
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let columns = rawLine.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 8, let rawStart = Double(columns[0]), let rawEnd = Double(columns[1]),
                  let start = SlopesParser.decodeTimestamp(rawStart),
                  let end = SlopesParser.decodeTimestamp(rawEnd), end > start else { continue }
            // The type string is the only label both known tools agree on.
            let label = columns[7].lowercased()
            guard label.contains("run") || label.contains("descent") else { continue }
            func metric(_ index: Int) -> Double? {
                guard columns.count > index, let value = Double(columns[index]), value.isFinite, value > 0
                else { return nil }
                return value
            }
            windows.append((start, end))
            runs.append(ParsedSegment(
                number: runs.count + 1,
                startTime: start,
                endTime: end,
                durationS: end.timeIntervalSince(start),
                topSpeedMS: metric(15),
                avgSpeedMS: metric(12),
                distanceM: metric(13),
                verticalM: columns.count > 14 ? Double(columns[14]).map(abs) : nil,
                points: [],
                boundary: .authoritativeDownhillRun
            ))
        }
        // Filled in once every window is known, so the whole list can be checked.
        for (index, inside) in try TimedFixes(points).slices(windows).enumerated() {
            runs[index].points = inside
        }
        return runs
    }

    private struct TrackInfo {
        var name: String?
        var descents: Int?
        var totalDescentM: Double?

        static func parse(_ data: Data) -> TrackInfo {
            let handler = Handler()
            let parser = XMLParser(data: data)
            parser.delegate = handler
            // The totals are a label; a damaged Track.xml only loses them.
            _ = parser.parse()
            return handler.info
        }

        private final class Handler: NSObject, XMLParserDelegate {
            var info = TrackInfo()
            private var text = ""
            private var insideMetrics = false

            func parser(
                _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
            ) {
                text = ""
                switch xmlLocalName(elementName).lowercased() {
                case "track":
                    if let name = attributeDict["name"], !name.isEmpty { info.name = name }
                case "metrics":
                    insideMetrics = true
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
                switch xmlLocalName(elementName).lowercased() {
                case "metrics":
                    insideMetrics = false
                case "descents":
                    if insideMetrics {
                        // Int(Double) traps on nan, inf and huge values, which a damaged file can carry.
                        info.descents = Int(value) ?? Double(value).flatMap { $0.isFinite && abs($0) < 1e6 ? Int($0) : nil }
                    }
                case "totaldescent":
                    if insideMetrics, let metres = Double(value), metres.isFinite { info.totalDescentM = abs(metres) }
                default:
                    break
                }
            }
        }
    }
}
