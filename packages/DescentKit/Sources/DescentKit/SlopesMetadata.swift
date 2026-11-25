import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// `Metadata.xml` from a modern `.slopes` export. Slopes segments the day into
/// Lift and Run actions itself, with good statistics, and that segmentation is
/// honoured rather than re-derived from `GPS.csv` (which has multi-minute gaps
/// where Slopes stopped recording).
///
///     <Activity runCount="7" topSpeed="13.22" distance="…" vertical="…"
///               duration="…" locationName="…" start="…" end="…">
///       <actions>
///         <Action type="Lift|Run" start="…" end="…" duration="…" topSpeed="…"
///                 avgSpeed="…" distance="…" vertical="…" numberOfType="…"/>
///       </actions>
///     </Activity>
///
/// Values are SI. Timestamps are local clock with an explicit offset
/// (`2026-01-10 11:34:26 -0600`), which is honoured: assuming UTC would shift
/// every run by hours and break the time-window slicing of `GPS.csv`.
struct SlopesMetadata {
    struct Header {
        var locationName: String?
        var runCount: Int
        var verticalM: Double = 0
    }

    struct Action {
        var isRun: Bool
        /// `numberOfType`: 1-based per kind.
        var number: Int
        var start: Date
        var end: Date
        var durationS: Double
        var topSpeedMS: Double
        var avgSpeedMS: Double
        var distanceM: Double
        var verticalM: Double
    }

    var header: Header
    /// In start order.
    var actions: [Action]

    var runs: [Action] { actions.filter(\.isRun) }

    /// Nil when the XML is malformed, has no `<Activity>`, has an action with
    /// invalid boundaries, or declares a run count it does not contain.
    static func parse(_ data: Data) -> SlopesMetadata? {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        guard parser.parse(), let header = handler.header, handler.invalidActionCount == 0 else {
            return nil
        }
        let ordered = handler.actions.sorted { ($0.start, $0.number) < ($1.start, $1.number) }
        let runCount = ordered.filter(\.isRun).count
        guard header.runCount == 0 || header.runCount == runCount else { return nil }
        return SlopesMetadata(header: header, actions: ordered)
    }

    /// `yyyy-MM-dd HH:mm:ss ±HHmm`, parsed by hand so the result does not
    /// depend on a platform's `DateFormatter`.
    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
        guard parts.count == 3 else { return nil }
        let day = parts[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        let clock = parts[1].split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard day.count == 3, clock.count == 3,
              let year = day[0], let month = day[1], let dayOfMonth = day[2],
              let hour = clock[0], let minute = clock[1], let second = clock[2],
              (1970...2200).contains(year),
              (1...12).contains(month), (1...31).contains(dayOfMonth),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }

        let zone = parts[2]
        guard zone.count == 5, let sign = zone.first, sign == "+" || sign == "-",
              let zoneHours = Int(zone.dropFirst().prefix(2)),
              let zoneMinutes = Int(zone.dropFirst(3)) else { return nil }
        let offset = (zoneHours * 3_600 + zoneMinutes * 60) * (sign == "-" ? -1 : 1)

        // The year bound above keeps this arithmetic far from Int overflow.
        // Days from 1970-01-01 in the proleptic Gregorian calendar.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + dayOfMonth - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds))
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var header: Header?
        var actions: [Action] = []
        var invalidActionCount = 0

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes a: [String: String] = [:]
        ) {
            switch xmlLocalName(elementName) {
            case "Activity":
                header = Header(
                    locationName: a["locationName"], runCount: Int(a["runCount"] ?? "") ?? 0,
                    verticalM: nonNegative(a["vertical"])
                )
            case "Action":
                guard let start = SlopesMetadata.date(a["start"]),
                      let end = SlopesMetadata.date(a["end"]), end > start else {
                    invalidActionCount += 1
                    return
                }
                let declared = number(a["duration"]).flatMap { $0 > 0 ? $0 : nil }
                actions.append(Action(
                    isRun: a["type"]?.lowercased() == "run",
                    number: Int(a["numberOfType"] ?? "") ?? 0,
                    start: start,
                    end: end,
                    durationS: declared ?? end.timeIntervalSince(start),
                    topSpeedMS: nonNegative(a["topSpeed"]),
                    avgSpeedMS: nonNegative(a["avgSpeed"]),
                    distanceM: nonNegative(a["distance"]),
                    verticalM: nonNegative(a["vertical"])
                ))
            default:
                break
            }
        }

        private func number(_ text: String?) -> Double? {
            guard let text, let value = Double(text), value.isFinite else { return nil }
            return value
        }

        private func nonNegative(_ text: String?) -> Double {
            guard let value = number(text), value >= 0 else { return 0 }
            return value
        }
    }
}
