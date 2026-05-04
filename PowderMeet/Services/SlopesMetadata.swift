//
//  SlopesMetadata.swift
//  PowderMeet
//
//  Parses Slopes' `Metadata.xml` (the authoritative source-of-truth in a
//  modern `.slopes` export). Slopes itself already segments the day into
//  Lift/Run actions with high-quality stats (top speed, avg speed, vertical,
//  distance, duration). Our previous parser ignored this file and re-derived
//  segmentation from `GPS.csv` with a 6-point sliding window — which choked
//  on the gaps Slopes leaves in its smoothed track (lift idle time, fix
//  drops). The result was Jan-10 importing 1 run instead of 7 and the avg
//  > peak speed inversion the user reported.
//
//  This file deliberately handles only the modern Slopes XML shape:
//
//    <Activity runCount="7" topSpeed="13.22" distance="..." vertical="..."
//              duration="..." locationName="..." start="..." end="..."
//              recordStart="..." recordEnd="...">
//      <actions>
//        <Action type="Lift|Run" start="..." end="..." duration="..."
//                topSpeed="..." avgSpeed="..." distance="..." vertical="..."
//                numberOfType="..." min/maxLat/Long/Alt="..."/>
//        ...
//      </actions>
//    </Activity>
//
//  All speed/distance/vertical/duration values are SI (m/s, m, m, s).
//  Timestamps are local-clock with an explicit offset (e.g. `-0600`) — we
//  honour that, because dropping the offset and assuming UTC would shift
//  every run by hours and break time-window slicing of GPS.csv.
//

import Foundation

// MARK: - Models

/// Activity-level summary from `<Activity ...>` in Metadata.xml.
nonisolated struct SlopesActivityHeader {
    let locationName: String?
    let start: Date?           // first action's start (skiing began)
    let end: Date?             // last action's end (skiing finished)
    let recordStart: Date?     // recording started (may include lodge time)
    let recordEnd: Date?
    let durationSeconds: Double
    let distanceMeters: Double
    let verticalMeters: Double
    let topSpeedMS: Double
    let runCount: Int
}

/// One `<Action>` from Slopes' segmentation. We keep both Lift and Run
/// kinds — the importer only consumes `.run`, but having Lifts available
/// is useful for future ride-time / chair-mix analytics.
nonisolated struct SlopesActionMetadata {
    enum Kind { case lift, run, unknown(String) }

    let kind: Kind
    let runNumber: Int          // numberOfType (1-based); meaningful per-kind
    let start: Date
    let end: Date
    let durationSeconds: Double
    let topSpeedMS: Double
    let avgSpeedMS: Double
    let distanceMeters: Double
    let verticalMeters: Double
    // Bounding box from the per-action GPS slice — useful for quick
    // resort identification when the Activity-level locationName is
    // missing (older / third-party Slopes exporters).
    let minLat: Double?
    let maxLat: Double?
    let minLon: Double?
    let maxLon: Double?

    var isRun: Bool {
        if case .run = kind { return true }
        return false
    }
}

/// Whole-activity envelope: header + ordered actions.
nonisolated struct SlopesMetadata {
    let header: SlopesActivityHeader
    let actions: [SlopesActionMetadata]

    var runs: [SlopesActionMetadata] { actions.filter { $0.isRun } }
}

// MARK: - Parser

enum SlopesMetadataError: Error {
    case malformed(String)
    case parseFailed(underlying: Error)
}

/// Event-driven XML parse — `XMLParser` is the only XML reader in the iOS
/// Foundation stack and the metadata is small enough that the streaming
/// API doesn't add complexity over a DOM build. Returns a typed error so
/// callers can surface the specific failure mode (missing actions, bad
/// timestamp format, etc.).
nonisolated enum SlopesMetadataParser {

    static func parse(data: Data) -> Result<SlopesMetadata, SlopesMetadataError> {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            if let err = parser.parserError {
                return .failure(.parseFailed(underlying: err))
            }
            return .failure(.malformed("XMLParser returned false without error"))
        }
        guard let header = delegate.header else {
            return .failure(.malformed("No <Activity> element found"))
        }
        return .success(SlopesMetadata(header: header, actions: delegate.actions))
    }

    // MARK: - XMLParser delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var header: SlopesActivityHeader?
        var actions: [SlopesActionMetadata] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "Activity":
                header = makeHeader(from: attributeDict)
            case "Action":
                if let action = makeAction(from: attributeDict) {
                    actions.append(action)
                }
            default:
                break
            }
        }

        private func makeHeader(from a: [String: String]) -> SlopesActivityHeader {
            SlopesActivityHeader(
                locationName: a["locationName"],
                start: SlopesDate.parse(a["start"]),
                end: SlopesDate.parse(a["end"]),
                recordStart: SlopesDate.parse(a["recordStart"]),
                recordEnd: SlopesDate.parse(a["recordEnd"]),
                durationSeconds: doubleValue(a["duration"]) ?? 0,
                distanceMeters: doubleValue(a["distance"]) ?? 0,
                verticalMeters: doubleValue(a["vertical"]) ?? 0,
                topSpeedMS: doubleValue(a["topSpeed"]) ?? 0,
                runCount: Int(a["runCount"] ?? "") ?? 0
            )
        }

        private func makeAction(from a: [String: String]) -> SlopesActionMetadata? {
            guard let start = SlopesDate.parse(a["start"]),
                  let end = SlopesDate.parse(a["end"]) else {
                // Action without parsable times is unusable — skip silently
                // so a single bad action doesn't fail the whole import.
                return nil
            }
            let kind: SlopesActionMetadata.Kind
            switch a["type"]?.lowercased() {
            case "run": kind = .run
            case "lift": kind = .lift
            case let other?: kind = .unknown(other)
            case nil:    kind = .unknown("")
            }
            return SlopesActionMetadata(
                kind: kind,
                runNumber: Int(a["numberOfType"] ?? "") ?? 0,
                start: start,
                end: end,
                durationSeconds: doubleValue(a["duration"]) ?? end.timeIntervalSince(start),
                topSpeedMS: doubleValue(a["topSpeed"]) ?? 0,
                avgSpeedMS: doubleValue(a["avgSpeed"]) ?? 0,
                distanceMeters: doubleValue(a["distance"]) ?? 0,
                verticalMeters: doubleValue(a["vertical"]) ?? 0,
                minLat: doubleValue(a["minLat"]),
                maxLat: doubleValue(a["maxLat"]),
                minLon: doubleValue(a["minLong"]),
                maxLon: doubleValue(a["maxLong"])
            )
        }

        private func doubleValue(_ s: String?) -> Double? {
            guard let s, !s.isEmpty else { return nil }
            return Double(s)
        }
    }
}

// MARK: - Date parsing

/// Slopes timestamps look like `2026-01-10 11:34:26 -0600` — local clock
/// plus offset. `ISO8601DateFormatter` rejects the space separator, and
/// a single `DateFormatter` instance isn't safe to share across threads
/// without locking, so we own a small per-thread cache.
nonisolated enum SlopesDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)  // overridden by `Z`
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Trim possible nbsp / surrounding whitespace.
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return formatter.date(from: trimmed)
    }
}
