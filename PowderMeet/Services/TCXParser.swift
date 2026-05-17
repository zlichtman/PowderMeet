//
//  TCXParser.swift
//  PowderMeet
//
//  SAX-style XML parser for Garmin TCX (Training Center XML) files.
//  Structure: <Activities> → <Activity> → <Lap> → <Track> → <Trackpoint>
//
//  Garmin Connect, Wahoo, Strava (when re-exporting Garmin imports) all
//  emit TCX with one `<Lap>` per ski run. The lap element carries
//  StartTime, TotalTimeSeconds, DistanceMeters, and MaximumSpeed —
//  exactly the per-run stats we want, computed at file-write time by
//  the device. We honour those: each `<Lap>` becomes one
//  `ParsedRunSegment` with native stats + the trackpoints inside it.
//
//  The legacy `parse(data:) -> [GPXTrack]` entry is kept for callers
//  that don't care about per-lap segmentation. The new
//  `parseUnified(data:sourceFileHash:)` returns the full `ParsedActivity`
//  envelope used by the unified import pipeline.
//

import Foundation

nonisolated final class TCXParser: NSObject, XMLParserDelegate {
    // MARK: - Output buffers

    private var tracks: [GPXTrack] = []                  // legacy flat output
    private var laps: [ParsedRunSegment] = []            // unified per-lap output

    // MARK: - Trackpoint scratch state

    private var currentLapPoints: [GPXTrackPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var currentSpeed: Double?

    // MARK: - Lap-level scratch state (per <Lap>)

    private var lapStartTime: Date?
    private var lapTotalTimeSeconds: Double?
    private var lapDistanceMeters: Double?
    private var lapMaximumSpeed: Double?
    private var insideLap = false
    private var lapNumber = 0

    // MARK: - Element nesting flags

    private var insideTrackpoint = false
    private var insidePosition = false
    /// While inside `<Extensions>`, plain `<Speed>` lookups need to find
    /// the Garmin-extension speed; outside, `<Speed>` could be a lap-level
    /// MaximumSpeed peer. We disambiguate via element-stack inspection.
    private var insideExtensions = false

    private var currentText = ""
    private var activityName: String?

    // Time parsing — shared helper, dual-format (with/without fractional
    // seconds) so we accept both clean GPS exports and Strava/Suunto.
    nonisolated private static func parseTimestamp(_ text: String) -> Date? {
        ISO8601Parser.parse(text)
    }

    // MARK: - Public API

    /// Legacy entry — flat `[GPXTrack]` output. Kept for any callers that
    /// existed before the unified pipeline. Each Lap becomes one
    /// `GPXTrack` so points stay grouped by run when downstream cares.
    static func parse(data: Data) -> [GPXTrack] {
        let handler = TCXParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        _ = parser.parse()
        return handler.tracks
    }

    /// Unified entry — returns a `ParsedActivity` with one
    /// `ParsedRunSegment` per `<Lap>`, carrying native stats from the
    /// lap element when present.
    static func parseUnified(data: Data, sourceFileHash: String) -> ParsedActivity {
        let handler = TCXParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        _ = parser.parse()

        return ParsedActivity(
            source: .tcx,
            resortName: handler.activityName,  // TCX has no resort field; use Activity Id as a label
            sourceFileHash: sourceFileHash,
            segments: handler.laps
        )
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""

        switch elementName {
        case "Lap":
            insideLap = true
            lapNumber += 1
            lapStartTime = (attributes["StartTime"]).flatMap(TCXParser.parseTimestamp)
            lapTotalTimeSeconds = nil
            lapDistanceMeters = nil
            lapMaximumSpeed = nil
            currentLapPoints = []
        case "Trackpoint":
            insideTrackpoint = true
            currentLat = nil
            currentLon = nil
            currentEle = nil
            currentTime = nil
            currentSpeed = nil
        case "Position":
            insidePosition = true
        case "Extensions":
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

        switch elementName {
        // ── Trackpoint-level fields ─────────────────────────────────
        case "LatitudeDegrees":
            if insidePosition { currentLat = Double(text) }
        case "LongitudeDegrees":
            if insidePosition { currentLon = Double(text) }
        case "AltitudeMeters":
            if insideTrackpoint { currentEle = Double(text) }
        case "Time":
            if insideTrackpoint { currentTime = TCXParser.parseTimestamp(text) }
        case "Speed":
            // Two contexts:
            //   - Trackpoint <Extensions><TPX><Speed> → per-fix m/s
            //   - Lap level (no nested Trackpoint) → already handled via
            //     <MaximumSpeed>; stray <Speed> at lap level rare in
            //     real exports, ignore.
            if insideTrackpoint, insideExtensions, let s = Double(text), s >= 0 {
                currentSpeed = s
            }
        case "Position":
            insidePosition = false
        case "Extensions":
            insideExtensions = false
        case "Trackpoint":
            if let lat = currentLat, let lon = currentLon {
                currentLapPoints.append(GPXTrackPoint(
                    latitude: lat,
                    longitude: lon,
                    elevation: currentEle,
                    timestamp: currentTime,
                    speed: currentSpeed
                ))
            }
            insideTrackpoint = false

        // ── Lap-level fields ────────────────────────────────────────
        case "TotalTimeSeconds":
            if insideLap, !insideTrackpoint { lapTotalTimeSeconds = Double(text) }
        case "DistanceMeters":
            if insideLap, !insideTrackpoint { lapDistanceMeters = Double(text) }
        case "MaximumSpeed":
            // Always lap-level in TCX schema (m/s).
            if insideLap, let s = Double(text), s >= 0 { lapMaximumSpeed = s }

        case "Lap":
            // Emit unified segment (always, even when empty — caller may
            // care about empty laps for reconciliation).
            // For legacy flat output, also append a GPXTrack so the old
            // path stays equivalent.
            let endTime = lapEndTime()
            let startTime = lapStartTime ?? currentLapPoints.first?.timestamp ?? Date()
            let duration = lapTotalTimeSeconds ?? endTime.timeIntervalSince(startTime)
            // avgSpeed is not in standard TCX; derive from distance/time
            // when both present so callers don't have to.
            let avgSpeed: Double? = {
                guard let d = lapDistanceMeters, d > 0,
                      let t = lapTotalTimeSeconds, t > 0 else { return nil }
                return d / t
            }()
            laps.append(ParsedRunSegment(
                runNumber: lapNumber,
                startTime: startTime,
                endTime: endTime,
                durationSeconds: duration,
                topSpeedMS: lapMaximumSpeed,
                avgSpeedMS: avgSpeed,
                distanceMeters: lapDistanceMeters,
                verticalMeters: nil,  // TCX doesn't carry vertical drop natively
                points: currentLapPoints
            ))
            if !currentLapPoints.isEmpty {
                tracks.append(GPXTrack(name: activityName, points: currentLapPoints))
            }
            currentLapPoints = []
            insideLap = false

        case "Id":
            if activityName == nil && !text.isEmpty {
                activityName = text
            }
        default:
            break
        }
    }

    /// Best-effort lap end time: sum of start + duration when both
    /// available, last fix's timestamp otherwise, falls back to start.
    private func lapEndTime() -> Date {
        if let start = lapStartTime, let dur = lapTotalTimeSeconds {
            return start.addingTimeInterval(dur)
        }
        if let last = currentLapPoints.last?.timestamp { return last }
        return lapStartTime ?? Date()
    }
}
