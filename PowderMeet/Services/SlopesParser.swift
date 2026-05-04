//
//  SlopesParser.swift
//  PowderMeet
//
//  Parser for Slopes app export files (.slopes). A `.slopes` export
//  comes in three flavours, in decreasing order of how much data it
//  carries:
//
//    1. **Modern ZIP archive** (the iOS Slopes app's current export)
//       containing `GPS.csv`, `RawGPS.csv`, and `Metadata.xml`. The
//       XML is the authoritative source of truth — Slopes already
//       segments the day into Lift/Run actions and computes
//       per-action top speed, avg speed, distance, vertical, and
//       duration. We honour that segmentation rather than re-deriving
//       from `GPS.csv` (which has multi-minute gaps wherever Slopes
//       stopped recording during lifts or fix dropouts). This is
//       what `parseActivity(url:)` returns.
//
//    2. **Legacy ZIP archive** containing a SQLite database — older
//       Slopes versions and some third-party exporters. We unpack via
//       `ZipReader` (pure Swift, no native unzip dep) and pull the
//       inner DB.
//
//    3. **Bare SQLite database** — older exports, or sometimes the
//       result of users renaming a DB file to `.slopes`. Detected by
//       the SQLite-format-3 magic bytes.
//
//  Slopes-the-app is built on Core Data, so its DB follows the
//  `Z`-prefixed naming convention (`ZRECORDEDLOCATION`, `ZLATITUDE`,
//  `ZTIMESTAMP`) AND its timestamps are NSDate values — seconds since
//  2001-01-01 UTC, NOT the Unix epoch. The decoder handles all three
//  conventions (Apple reference date, Unix seconds, Unix milliseconds)
//  and picks based on magnitude.
//
//  `parse(url:)` returns a flat `[GPXTrack]` for callers that don't
//  care about per-run segmentation (legacy GPX-style import). The
//  modern entry point is `parseActivity(url:)`, which returns the full
//  `SlopesActivity` envelope including pre-segmented runs with stats.
//

import Foundation
import SQLite3

// MARK: - Public model — pre-segmented Slopes activity

/// One Slopes-segmented run, paired with the GPS points that fall
/// inside Slopes' reported `[start, end]` window. Stats come from
/// Slopes' own algorithms — we trust them because Slopes has access
/// to the raw sensor stream and its segmentation is significantly
/// better than what we can reconstruct from the smoothed-and-gapped
/// `GPS.csv` after the fact.
nonisolated struct SlopesRun {
    let runNumber: Int            // numberOfType (1-based, per-kind)
    let start: Date
    let end: Date
    let durationSeconds: Double
    let topSpeedMS: Double
    let avgSpeedMS: Double         // Slopes' "moving average" (pauses excluded)
    let distanceMeters: Double
    let verticalMeters: Double
    let points: [GPXTrackPoint]    // GPS fixes inside [start, end]
}

/// Whole-day Slopes activity: header + ordered runs. Lifts are dropped
/// at this level because the importer only cares about runs; if we
/// ever want chair-mix analytics, surface a separate `lifts` array
/// here from `SlopesMetadata`.
nonisolated struct SlopesActivity {
    let resortName: String?
    let recordStart: Date?
    let recordEnd: Date?
    let activityStart: Date?
    let activityEnd: Date?
    let totalDurationSeconds: Double
    let totalDistanceMeters: Double
    let totalVerticalMeters: Double
    let activityTopSpeedMS: Double
    let runs: [SlopesRun]

    /// Bounding box across all run points — used for resort
    /// identification when the legacy single-track flow needs it.
    var firstPoint: GPXTrackPoint? { runs.flatMap { $0.points }.first }
}

// MARK: - Errors

enum SlopesParserError: LocalizedError {
    case notSlopesFormat
    case archiveUnreadable(underlying: Error)
    case sqliteOpenFailed(path: String)
    case sqliteNotFoundInArchive
    case noLocationTable
    case emptyLocationTable
    /// Modern Slopes ZIP was found but `Metadata.xml` couldn't be parsed.
    /// Falls through to GPS-only extraction; surfaced only if every
    /// fallback also fails.
    case metadataParseFailed(SlopesMetadataError)

    var errorDescription: String? {
        switch self {
        case .notSlopesFormat:
            return "File is not a Slopes export — neither a SQLite database nor a ZIP archive containing one."
        case .archiveUnreadable(let underlying):
            return "Could not read the Slopes ZIP archive: \(underlying.localizedDescription)"
        case .sqliteOpenFailed(let path):
            return "Could not open the SQLite database inside the Slopes file (\(path))."
        case .sqliteNotFoundInArchive:
            return "ZIP archive does not contain a SQLite database — is this really a Slopes export?"
        case .noLocationTable:
            return "Slopes database has no recognisable GPS-location table."
        case .emptyLocationTable:
            return "Slopes database has a location table, but no GPS rows were inside it."
        case .metadataParseFailed(let inner):
            return "Slopes Metadata.xml could not be read: \(inner)"
        }
    }
}

nonisolated struct SlopesParser {

    // MARK: - Public entry points

    /// Modern entry point — returns Slopes' own pre-segmented runs with
    /// per-run stats. Use this when callers can consume structured runs
    /// (the activity importer does). Falls back to a single-run synthetic
    /// activity if Metadata.xml is missing or unparseable, so this entry
    /// point also works for bare-SQLite legacy exports.
    static func parseActivity(url: URL) -> Result<SlopesActivity, SlopesParserError> {
        let head = readHead(url: url)
        switch head {
        case .failure(let err): return .failure(err)
        case .success(let bytes):
            if Self.looksLikeZip(bytes) {
                return extractActivityFromZip(zipURL: url)
            }
            if Self.looksLikeSQLite(bytes) {
                // Bare SQLite — no metadata available. Wrap into a single
                // run so the caller still sees the GPS track.
                switch readDatabase(at: url) {
                case .success(let tracks): return .success(syntheticActivity(from: tracks))
                case .failure(let err):    return .failure(err)
                }
            }
            return .failure(.notSlopesFormat)
        }
    }

    /// Parses a `.slopes` file into a flat `[GPXTrack]` — kept for callers
    /// (and tests) that don't need per-run segmentation. Returns one
    /// `GPXTrack` per Slopes Run when metadata is available, else a single
    /// merged track.
    static func parse(url: URL) -> Result<[GPXTrack], SlopesParserError> {
        switch parseActivity(url: url) {
        case .success(let activity):
            if activity.runs.isEmpty {
                return .failure(.emptyLocationTable)
            }
            // One GPXTrack per run preserves segmentation for callers
            // that respect track boundaries; legacy callers that flatten
            // see equivalent points either way.
            let tracks = activity.runs.map { run in
                GPXTrack(
                    name: "Slopes Run \(run.runNumber)",
                    points: run.points
                )
            }
            return .success(tracks)
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Convenience wrapper that drops the error and returns an empty
    /// array on any failure. Kept compatible with the old call shape.
    static func parseTracks(url: URL) -> [GPXTrack] {
        switch parse(url: url) {
        case .success(let tracks): return tracks
        case .failure: return []
        }
    }

    /// Unified parser entry — returns a `ParsedActivity` envelope that
    /// the activity importer consumes alongside outputs from GPX/TCX/FIT
    /// parsers. The internal `SlopesActivity` shape is preserved for
    /// callers that need Slopes-specific metadata; this is the surface
    /// the importer uses so all four formats land in the same pipeline.
    static func parseUnified(url: URL, sourceFileHash: String) -> Result<ParsedActivity, SlopesParserError> {
        switch parseActivity(url: url) {
        case .success(let activity):
            return .success(ParsedActivity(
                source: .slopes,
                resortName: activity.resortName,
                sourceFileHash: sourceFileHash,
                segments: activity.runs.map { run in
                    ParsedRunSegment(
                        runNumber: run.runNumber,
                        startTime: run.start,
                        endTime: run.end,
                        durationSeconds: run.durationSeconds,
                        topSpeedMS: run.topSpeedMS > 0 ? run.topSpeedMS : nil,
                        avgSpeedMS: run.avgSpeedMS > 0 ? run.avgSpeedMS : nil,
                        distanceMeters: run.distanceMeters > 0 ? run.distanceMeters : nil,
                        verticalMeters: run.verticalMeters > 0 ? run.verticalMeters : nil,
                        points: run.points
                    )
                }
            ))
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Format sniffing

    private static func readHead(url: URL) -> Result<Data, SlopesParserError> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return .success(try handle.read(upToCount: 16) ?? Data())
        } catch {
            return .failure(.archiveUnreadable(underlying: error))
        }
    }

    private static func looksLikeSQLite(_ head: Data) -> Bool {
        guard head.count >= 15 else { return false }
        let header = String(data: head.prefix(15), encoding: .utf8)
        return header == "SQLite format 3"
    }

    private static func looksLikeZip(_ head: Data) -> Bool {
        // ZIP local-file-header signature is "PK\x03\x04" (0x04034b50, LE).
        // An empty zip with only a central directory starts with "PK\x05\x06"
        // — handle that variant too even though it has no entries.
        guard head.count >= 4 else { return false }
        let b0 = head[0], b1 = head[1], b2 = head[2], b3 = head[3]
        return b0 == 0x50 && b1 == 0x4b && (
            (b2 == 0x03 && b3 == 0x04) ||
            (b2 == 0x05 && b3 == 0x06)
        )
    }

    // MARK: - ZIP path

    /// Pulls a SlopesActivity out of a modern Slopes ZIP. Order of
    /// preference:
    ///   1. `Metadata.xml` + `GPS.csv` → fully-segmented activity
    ///   2. `GPS.csv` alone → single-run synthetic activity
    ///   3. Inner SQLite (legacy) → single-run synthetic activity
    private static func extractActivityFromZip(zipURL: URL) -> Result<SlopesActivity, SlopesParserError> {
        let reader: ZipReader
        do {
            reader = try ZipReader(url: zipURL)
        } catch {
            return .failure(.archiveUnreadable(underlying: error))
        }

        // Try metadata-driven path first.
        if let metaEntry = reader.fileEntries.first(where: {
            $0.name.caseInsensitiveCompare("Metadata.xml") == .orderedSame
        }), let csvEntry = preferredCSVEntry(in: reader) {
            do {
                let metaBytes = try reader.read(metaEntry)
                let csvBytes = try reader.read(csvEntry)
                switch SlopesMetadataParser.parse(data: metaBytes) {
                case .success(let metadata):
                    let allPoints = parsePoints(fromCSV: csvBytes)
                    return .success(buildActivity(from: metadata, allPoints: allPoints))
                case .failure:
                    // Metadata unparseable — drop to GPS-only path below.
                    let points = parsePoints(fromCSV: csvBytes)
                    if !points.isEmpty {
                        return .success(syntheticActivity(points: points))
                    }
                }
            } catch {
                return .failure(.archiveUnreadable(underlying: error))
            }
        }

        // No metadata — fall back to CSV-only.
        if let csvEntry = preferredCSVEntry(in: reader) {
            do {
                let csvBytes = try reader.read(csvEntry)
                let points = parsePoints(fromCSV: csvBytes)
                if !points.isEmpty {
                    return .success(syntheticActivity(points: points))
                }
            } catch {
                return .failure(.archiveUnreadable(underlying: error))
            }
        }

        // Legacy: inner SQLite DB.
        let dbEntry: ZipReader.Entry
        if let byExt = reader.firstEntry(withExtensions: ["db", "sqlite", "sqlite3"]) {
            dbEntry = byExt
        } else {
            do {
                guard let byMagic = try reader.firstSQLiteEntry() else {
                    return .failure(.sqliteNotFoundInArchive)
                }
                dbEntry = byMagic
            } catch {
                return .failure(.archiveUnreadable(underlying: error))
            }
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopes_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.archiveUnreadable(underlying: error))
        }
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("activity.db")
        do {
            let bytes = try reader.read(dbEntry)
            try bytes.write(to: dbURL, options: .atomic)
        } catch {
            return .failure(.archiveUnreadable(underlying: error))
        }

        switch readDatabase(at: dbURL) {
        case .success(let tracks): return .success(syntheticActivity(from: tracks))
        case .failure(let err):    return .failure(err)
        }
    }

    /// Joins parsed metadata to GPS points by time-window slicing. Each
    /// `Action type="Run"` claims the points whose timestamps fall within
    /// `[start, end]`. Slopes' actions are non-overlapping by construction,
    /// so a binary-search-bracketed scan would also work — linear is fine
    /// at the sizes we see (≤ 5K points per day, ≤ 30 actions).
    private static func buildActivity(
        from meta: SlopesMetadata,
        allPoints: [GPXTrackPoint]
    ) -> SlopesActivity {
        // Sort once so per-action slicing is monotone.
        let sortedPoints = allPoints.sorted {
            ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
        }

        var runs: [SlopesRun] = []
        runs.reserveCapacity(meta.runs.count)

        for action in meta.runs {
            // Inclusive on both ends — Slopes' action boundaries are at
            // GPS-fix granularity, so a missed-by-one-second exclusive
            // bound would drop the first/last fix of the run.
            let slice = sortedPoints.filter { pt in
                guard let t = pt.timestamp else { return false }
                return t >= action.start && t <= action.end
            }
            runs.append(SlopesRun(
                runNumber: action.runNumber,
                start: action.start,
                end: action.end,
                durationSeconds: action.durationSeconds,
                topSpeedMS: action.topSpeedMS,
                avgSpeedMS: action.avgSpeedMS,
                distanceMeters: action.distanceMeters,
                verticalMeters: action.verticalMeters,
                points: slice
            ))
        }

        return SlopesActivity(
            resortName: meta.header.locationName,
            recordStart: meta.header.recordStart,
            recordEnd: meta.header.recordEnd,
            activityStart: meta.header.start,
            activityEnd: meta.header.end,
            totalDurationSeconds: meta.header.durationSeconds,
            totalDistanceMeters: meta.header.distanceMeters,
            totalVerticalMeters: meta.header.verticalMeters,
            activityTopSpeedMS: meta.header.topSpeedMS,
            runs: runs
        )
    }

    /// Wrap a flat point list into a SlopesActivity carrying a single
    /// synthetic run — used by the legacy fallback paths (CSV-only, bare
    /// SQLite). Stats are zero so the importer falls back to graph-derived
    /// values for these cases.
    private static func syntheticActivity(points: [GPXTrackPoint]) -> SlopesActivity {
        let start = points.first?.timestamp
        let end = points.last?.timestamp
        let duration = (start.flatMap { s in end.map { $0.timeIntervalSince(s) } }) ?? 0
        return SlopesActivity(
            resortName: nil,
            recordStart: start,
            recordEnd: end,
            activityStart: start,
            activityEnd: end,
            totalDurationSeconds: duration,
            totalDistanceMeters: 0,
            totalVerticalMeters: 0,
            activityTopSpeedMS: 0,
            runs: [SlopesRun(
                runNumber: 1,
                start: start ?? Date(),
                end: end ?? Date(),
                durationSeconds: duration,
                topSpeedMS: 0,
                avgSpeedMS: 0,
                distanceMeters: 0,
                verticalMeters: 0,
                points: points
            )]
        )
    }

    private static func syntheticActivity(from tracks: [GPXTrack]) -> SlopesActivity {
        syntheticActivity(points: tracks.flatMap { $0.points })
    }

    // MARK: - CSV path
    //
    // CSV format (no header row, comma-separated):
    //   <timestamp> , <lat> , <lon> , <altitude> , <course> , <speed> , <hAccuracy> , <vAccuracy>
    //
    //   timestamp:  Unix epoch seconds (fractional, microsecond precision)
    //   lat / lon:  WGS84 decimal degrees
    //   altitude:   metres above WGS84 ellipsoid
    //   course:     degrees true (0 = North, -1 = unknown)
    //   speed:      m/s (≥ 0)
    //   hAcc/vAcc:  metres

    /// Picks the best CSV entry from a Slopes ZIP. Slopes ships both a
    /// smoothed `GPS.csv` and a raw `RawGPS.csv`; we prefer the smoothed
    /// one because Slopes' own segmentation in Metadata.xml is keyed
    /// against the smoothed timeline (the two CSVs cover the same
    /// wall-clock window, but the smoothed one drops obviously-bad
    /// fixes — using raw points would produce ragged run slices).
    private static func preferredCSVEntry(in reader: ZipReader) -> ZipReader.Entry? {
        let entries = reader.fileEntries
        if let gps = entries.first(where: { $0.name.caseInsensitiveCompare("GPS.csv") == .orderedSame }) {
            return gps
        }
        if let raw = entries.first(where: { $0.name.caseInsensitiveCompare("RawGPS.csv") == .orderedSame }) {
            return raw
        }
        return reader.firstEntry(withExtensions: ["csv"])
    }

    private static func parsePoints(fromCSV data: Data) -> [GPXTrackPoint] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var points: [GPXTrackPoint] = []
        points.reserveCapacity(text.count / 80)

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 4 else { continue }

            guard let timestampRaw = Double(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let lat = Double(cols[1].trimmingCharacters(in: .whitespaces)),
                  let lon = Double(cols[2].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            guard abs(lat) > 0.01, abs(lon) > 0.01,
                  abs(lat) <= 90, abs(lon) <= 180 else { continue }

            let altitude = Double(cols[3].trimmingCharacters(in: .whitespaces))
            let timestamp = decodeTimestamp(timestampRaw)
            // Slopes records device-reported speed in column 5 (m/s);
            // -1 means "unknown". Forward it so the importer can use
            // device speed when available, instead of haversine-derived
            // estimates that are noisy at low sample rates.
            var speed: Double?
            if cols.count >= 6 {
                if let s = Double(cols[5].trimmingCharacters(in: .whitespaces)), s >= 0 {
                    speed = s
                }
            }

            points.append(GPXTrackPoint(
                latitude: lat,
                longitude: lon,
                elevation: altitude,
                timestamp: timestamp,
                speed: speed
            ))
        }

        return points
    }

    // MARK: - SQLite path (legacy)

    private static func readDatabase(at dbURL: URL) -> Result<[GPXTrack], SlopesParserError> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            return .failure(.sqliteOpenFailed(path: dbURL.path))
        }
        defer { sqlite3_close(db) }

        if let points = readPoints(from: db), !points.isEmpty {
            return .success([GPXTrack(name: "Slopes Activity", points: points)])
        }
        if hasAnyLocationTable(db: db) {
            return .failure(.emptyLocationTable)
        }
        return .failure(.noLocationTable)
    }

    private static func readPoints(from db: OpaquePointer) -> [GPXTrackPoint]? {
        let knownQueries: [String] = [
            "SELECT ZLATITUDE, ZLONGITUDE, ZALTITUDE, ZTIMESTAMP FROM ZRECORDEDLOCATION ORDER BY ZTIMESTAMP ASC",
            "SELECT ZLATITUDE, ZLONGITUDE, ZALTITUDE, ZTIME FROM ZRECORDEDLOCATION ORDER BY ZTIME ASC",
            "SELECT ZLATITUDE, ZLONGITUDE, ZALTITUDE, ZTIMESTAMP FROM ZLOCATION ORDER BY ZTIMESTAMP ASC",
            "SELECT ZLATITUDE, ZLONGITUDE, ZELEVATION, ZTIMESTAMP FROM ZLOCATION ORDER BY ZTIMESTAMP ASC",
            "SELECT latitude, longitude, altitude, timestamp FROM location ORDER BY timestamp ASC",
            "SELECT latitude, longitude, altitude, timestamp FROM locations ORDER BY timestamp ASC",
            "SELECT latitude, longitude, elevation, timestamp FROM locations ORDER BY timestamp ASC",
            "SELECT lat, lon, altitude, timestamp FROM locations ORDER BY timestamp ASC",
            "SELECT latitude, longitude, altitude, time FROM gps_data ORDER BY time ASC",
            "SELECT lat, lng, alt, time FROM points ORDER BY time ASC",
        ]
        for query in knownQueries {
            let pts = executeLocationQuery(db: db, query: query)
            if !pts.isEmpty { return pts }
        }
        return discoverAndQuery(db: db)
    }

    private static func hasAnyLocationTable(db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        let q = """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND (
                LOWER(name) LIKE '%location%' OR
                LOWER(name) LIKE '%gps%'      OR
                LOWER(name) LIKE '%track%'    OR
                LOWER(name) LIKE '%point%'
              )
            LIMIT 1
        """
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func executeLocationQuery(db: OpaquePointer, query: String) -> [GPXTrackPoint] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var points: [GPXTrackPoint] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let lat = sqlite3_column_double(stmt, 0)
            let lon = sqlite3_column_double(stmt, 1)

            guard abs(lat) > 0.01, abs(lon) > 0.01,
                  abs(lat) <= 90, abs(lon) <= 180 else { continue }

            let elevation: Double?
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                elevation = sqlite3_column_double(stmt, 2)
            } else {
                elevation = nil
            }

            let timestamp: Date?
            if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                timestamp = decodeTimestamp(sqlite3_column_double(stmt, 3))
            } else {
                timestamp = nil
            }

            points.append(GPXTrackPoint(
                latitude: lat,
                longitude: lon,
                elevation: elevation,
                timestamp: timestamp
            ))
        }

        return points
    }

    /// Branches by magnitude so all three timestamp conventions land on
    /// the right `Date`:
    ///   - value <  978_307_200  → Apple reference date (Core Data NSDate)
    ///   - value <  3_000_000_000 → Unix epoch seconds
    ///   - value >= 3_000_000_000 → Unix epoch milliseconds
    private static func decodeTimestamp(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        if raw < 978_307_200 {
            return Date(timeIntervalSinceReferenceDate: raw)
        } else if raw < 3_000_000_000 {
            return Date(timeIntervalSince1970: raw)
        } else {
            return Date(timeIntervalSince1970: raw / 1000)
        }
    }

    private static func discoverAndQuery(db: OpaquePointer) -> [GPXTrackPoint]? {
        let schemaQuery = """
            SELECT m.name, p.name, p.cid
            FROM sqlite_master m
            JOIN pragma_table_info(m.name) p
            WHERE m.type = 'table'
            ORDER BY m.name, p.cid
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, schemaQuery, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        var schema: [String: [String]] = [:]
        var orderedTables: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let tcStr = sqlite3_column_text(stmt, 0),
                  let ccStr = sqlite3_column_text(stmt, 1) else { continue }
            let table = String(cString: tcStr)
            let column = String(cString: ccStr)
            if schema[table] == nil {
                schema[table] = []
                orderedTables.append(table)
            }
            schema[table]?.append(column)
        }

        let latNames = ["latitude", "lat", "zlatitude", "zlat"]
        let lonNames = ["longitude", "lon", "lng", "zlongitude", "zlon", "zlng"]
        let altNames = ["altitude", "elevation", "alt", "zaltitude", "zelevation", "zalt"]
        let timeNames = ["timestamp", "time", "created_at", "date", "ztimestamp", "ztime", "zdate"]

        let preferred = orderedTables.filter { $0.lowercased().contains("location")
                                            || $0.lowercased().contains("gps")
                                            || $0.lowercased().contains("track")
                                            || $0.lowercased().contains("point") }
        let ordered = preferred + orderedTables.filter { !preferred.contains($0) }

        for table in ordered {
            let columns = schema[table] ?? []
            let colLower = columns.map { $0.lowercased() }

            guard let latIdx = colLower.firstIndex(where: { latNames.contains($0) }),
                  let lonIdx = colLower.firstIndex(where: { lonNames.contains($0) }) else {
                continue
            }
            let altIdx = colLower.firstIndex(where: { altNames.contains($0) })
            let timeIdx = colLower.firstIndex(where: { timeNames.contains($0) })

            let latCol = columns[latIdx]
            let lonCol = columns[lonIdx]
            let altCol = altIdx.map { columns[$0] }
            let timeCol = timeIdx.map { columns[$0] }

            var q = "SELECT \"\(latCol)\", \"\(lonCol)\""
            q += ", \(altCol.map { "\"\($0)\"" } ?? "NULL")"
            q += ", \(timeCol.map { "\"\($0)\"" } ?? "NULL")"
            q += " FROM \"\(table)\""
            if let tc = timeCol { q += " ORDER BY \"\(tc)\" ASC" }

            let pts = executeLocationQuery(db: db, query: q)
            if !pts.isEmpty { return pts }
        }

        return nil
    }
}
