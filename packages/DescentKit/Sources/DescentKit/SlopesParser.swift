import CSQLite
import Foundation

/// Slopes app exports (`.slopes`), in three flavours:
///
/// 1. Modern zip with `GPS.csv`, `RawGPS.csv` and `Metadata.xml`. The XML is
///    authoritative: each `Action type="Run"` becomes one segment marked
///    `.authoritativeDownhillRun`, with Slopes' own statistics and the GPS
///    fixes inside its time window.
/// 2. Legacy zip holding a SQLite database (older Slopes and some third-party
///    exporters).
/// 3. A bare SQLite database, recognised by its header.
///
/// Flavours 2 and 3, and a zip whose metadata cannot be read, give one
/// whole-activity segment that `DescentSegmenter` splits into descents.
///
/// Slopes is built on Core Data, so its tables use `Z`-prefixed names and its
/// timestamps count from 2001-01-01. The decoder accepts that, Unix seconds
/// and Unix milliseconds, choosing by magnitude.
public enum SlopesParser: ActivityParser {
    public static let source = ActivitySource.slopes

    public static func parse(_ data: Data) throws(ActivityParseError) -> ParsedActivity {
        try parse(data, honouringRunList: true)
    }

    /// With `honouringRunList` false the archive's `Metadata.xml` is ignored
    /// and the whole GPS log comes back as one segment. The corpus test uses
    /// this to measure `DescentSegmenter` against Slopes' own run list.
    static func parse(_ data: Data, honouringRunList: Bool) throws(ActivityParseError) -> ParsedActivity {
        let head = [UInt8](data.prefix(16))
        if head.count >= 4, head[0] == 0x50, head[1] == 0x4b,
           (head[2] == 0x03 && head[3] == 0x04) || (head[2] == 0x05 && head[3] == 0x06) {
            return try parseZip(data, honouringRunList: honouringRunList)
        }
        if head.count >= 15, Array(head[0..<15]) == Array("SQLite format 3".utf8) {
            return wholeActivity(points: try readDatabase(data))
        }
        throw .notThisFormat
    }

    // MARK: - Zip

    /// In order of preference: `Metadata.xml` with a CSV, a CSV alone, then an
    /// inner SQLite database.
    private static func parseZip(
        _ data: Data, honouringRunList: Bool
    ) throws(ActivityParseError) -> ParsedActivity {
        let reader: ZipReader
        do { reader = try ZipReader(data: data) } catch { throw .archive(error) }

        var csvPoints: [TrackPoint] = []
        if let csvEntry = preferredCSV(in: reader) {
            let csv: Data
            do { csv = try reader.read(csvEntry) } catch { throw .archive(error) }
            csvPoints = points(fromCSV: csv)

            if honouringRunList, let metadataEntry = reader.entry(baseName: "Metadata.xml") {
                let xml: Data
                do { xml = try reader.read(metadataEntry) } catch { throw .archive(error) }
                if let metadata = SlopesMetadata.parse(xml) {
                    return try activity(from: metadata, points: csvPoints)
                }
            }
            if !csvPoints.isEmpty { return wholeActivity(points: csvPoints) }
        }

        let databaseEntry: ZipReader.Entry
        if let byExtension = reader.firstEntry(withExtensions: ["db", "sqlite", "sqlite3"]) {
            databaseEntry = byExtension
        } else {
            let byMagic: ZipReader.Entry?
            do { byMagic = try reader.firstSQLiteEntry() } catch { throw .archive(error) }
            guard let byMagic else { throw reader.fileEntries.isEmpty ? .sqliteNotFoundInArchive : .unknownArchive }
            databaseEntry = byMagic
        }
        let database: Data
        do { database = try reader.read(databaseEntry) } catch { throw .archive(error) }
        return wholeActivity(points: try readDatabase(database))
    }

    /// Each run action claims the fixes whose timestamps fall inside
    /// `[start, end]`, inclusive at both ends because action boundaries sit at
    /// GPS-fix granularity.
    private static func activity(
        from metadata: SlopesMetadata, points: [TrackPoint]
    ) throws(ActivityParseError) -> ParsedActivity {
        let slices = try TimedFixes(points).slices(metadata.runs.map { ($0.start, $0.end) })
        let segments = zip(metadata.runs, slices).map { action, inside in
            ParsedSegment(
                number: action.number,
                startTime: action.start,
                endTime: action.end,
                durationS: action.durationS,
                topSpeedMS: action.topSpeedMS > 0 ? action.topSpeedMS : nil,
                avgSpeedMS: action.avgSpeedMS > 0 ? action.avgSpeedMS : nil,
                distanceM: action.distanceM > 0 ? action.distanceM : nil,
                verticalM: action.verticalM > 0 ? action.verticalM : nil,
                points: inside,
                boundary: .authoritativeDownhillRun
            )
        }
        return ParsedActivity(
            source: .slopes, resortName: metadata.header.locationName, segments: segments,
            sourceApp: "Slopes", fullTrack: points,
            declared: DeclaredTotals(
                runCount: metadata.runs.count,
                verticalM: metadata.header.verticalM > 0 ? metadata.header.verticalM : nil
            )
        )
    }

    /// One segment holding every fix, with no statistics: a hint to segment.
    private static func wholeActivity(points: [TrackPoint]) -> ParsedActivity {
        let start = points.first?.timestamp
        let end = points.last?.timestamp
        return ParsedActivity(source: .slopes, resortName: nil, segments: [ParsedSegment(
            number: 1,
            startTime: start,
            endTime: end,
            durationS: start.flatMap { s in end.map { $0.timeIntervalSince(s) } },
            points: points
        )], sourceApp: "Slopes")
    }

    // MARK: - CSV

    /// Slopes ships a smoothed `GPS.csv` and a raw `RawGPS.csv`. The smoothed
    /// one is preferred because the actions in `Metadata.xml` are keyed
    /// against its timeline.
    private static func preferredCSV(in reader: ZipReader) -> ZipReader.Entry? {
        // By base name: Finder re-zipping the export wraps it in a folder.
        reader.entry(baseName: "GPS.csv") ?? reader.entry(baseName: "RawGPS.csv")
            ?? reader.firstEntry(withExtensions: ["csv"])
    }

    /// No header row; columns are timestamp (Unix seconds, fractional), lat,
    /// lon, altitude (m), course (degrees, -1 unknown), speed (m/s, -1
    /// unknown), horizontal accuracy, vertical accuracy.
    static func points(fromCSV data: Data) -> [TrackPoint] {
        var points: [TrackPoint] = []
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 4, let rawTime = Double(columns[0]),
                  let lat = Double(columns[1]), let lon = Double(columns[2]),
                  isPlausible(lat: lat, lon: lon) else { continue }
            var speed: Double?
            if columns.count >= 6, let s = Double(columns[5]), s >= 0 { speed = s }
            points.append(TrackPoint(
                lat: lat, lon: lon, elevationM: Double(columns[3]),
                timestamp: decodeTimestamp(rawTime), speedMS: speed
            ))
        }
        return points
    }

    /// Rejects the (0, 0) "no fix" placeholder and out-of-range values.
    private static func isPlausible(lat: Double, lon: Double) -> Bool {
        abs(lat) > 0.01 && abs(lon) > 0.01 && abs(lat) <= 90 && abs(lon) <= 180
    }

    /// Below 978,307,200 the value counts from 2001 (Core Data); below
    /// 3,000,000,000 it is Unix seconds; above, Unix milliseconds.
    static func decodeTimestamp(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        if raw < 978_307_200 { return Date(timeIntervalSinceReferenceDate: raw) }
        if raw < 3_000_000_000 { return Date(timeIntervalSince1970: raw) }
        return Date(timeIntervalSince1970: raw / 1_000)
    }

    // MARK: - SQLite (legacy)

    /// Reads the database image in memory (`sqlite3_deserialize`), so nothing
    /// is written to disk.
    private static func readDatabase(_ data: Data) throws(ActivityParseError) -> [TrackPoint] {
        var image = [UInt8](data)
        guard image.count >= 100 else { throw .sqliteOpenFailed }
        // Header bytes 18 and 19 are the file-format versions; 2 means WAL,
        // which an in-memory image cannot use. The image is self-contained, so
        // reading it in rollback mode is safe.
        if image[18] == 2 { image[18] = 1 }
        if image[19] == 2 { image[19] = 1 }

        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        guard opened == SQLITE_OK, let database = handle else { throw .sqliteOpenFailed }

        // The image must outlive every query, so all reading happens inside.
        let size = Int64(image.count)
        let outcome: Result<[TrackPoint], ActivityParseError> = image.withUnsafeMutableBufferPointer { buffer in
            let attached = sqlite3_deserialize(
                database, "main", buffer.baseAddress, size, size, UInt32(SQLITE_DESERIALIZE_READONLY)
            )
            guard attached == SQLITE_OK else { return .failure(.sqliteOpenFailed) }
            // The database is the file's: a view can be defined to never end.
            let budget = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            budget.initialize(to: maximumProgressCalls)
            defer {
                sqlite3_progress_handler(database, 0, nil, nil)
                budget.deallocate()
            }
            sqlite3_progress_handler(database, Int32(progressCallOps), { context in
                guard let remaining = context?.assumingMemoryBound(to: Int.self) else { return 1 }
                remaining.pointee -= 1
                return remaining.pointee < 0 ? 1 : 0
            }, budget)
            do throws(ActivityParseError) {
                if let points = try readPoints(database), !points.isEmpty { return .success(points) }
            } catch {
                return .failure(error)
            }
            return .failure(hasLocationTable(database) ? .emptyLocationTable : .noLocationTable)
        }
        // Detach before `image` goes away.
        sqlite3_close(handle)
        handle = nil
        return try outcome.get()
    }

    /// Every query on one file shares this many progress calls, each
    /// `progressCallOps` virtual-machine steps: room for many days of fixes,
    /// and well under a second of work.
    static let progressCallOps = 10_000
    static let maximumProgressCalls = 5_000
    /// More fixes than a week of one-second logging: past this the table is not a recording.
    static let maximumDatabaseRows = 2_000_000

    private static func readPoints(_ database: OpaquePointer) throws(ActivityParseError) -> [TrackPoint]? {
        let knownQueries = [
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
            let points = try locations(database, query: query)
            if !points.isEmpty { return points }
        }
        return try discoverAndQuery(database)
    }

    private static func hasLocationTable(_ database: OpaquePointer) -> Bool {
        let query = """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND (
                LOWER(name) LIKE '%location%' OR LOWER(name) LIKE '%gps%' OR
                LOWER(name) LIKE '%track%' OR LOWER(name) LIKE '%point%')
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Runs a four-column query: latitude, longitude, altitude, timestamp.
    private static func locations(
        _ database: OpaquePointer, query: String
    ) throws(ActivityParseError) -> [TrackPoint] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var points: [TrackPoint] = []
        var rows = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_INTERRUPT { throw .malformed("the database takes too long to read") }
            guard step == SQLITE_ROW else { break }
            rows += 1
            guard rows <= maximumDatabaseRows else { throw .malformed("the database holds too many fixes") }
            let lat = sqlite3_column_double(statement, 0)
            let lon = sqlite3_column_double(statement, 1)
            guard isPlausible(lat: lat, lon: lon) else { continue }
            let elevation = sqlite3_column_type(statement, 2) != SQLITE_NULL
                ? sqlite3_column_double(statement, 2) : nil
            let timestamp = sqlite3_column_type(statement, 3) != SQLITE_NULL
                ? decodeTimestamp(sqlite3_column_double(statement, 3)) : nil
            points.append(TrackPoint(lat: lat, lon: lon, elevationM: elevation, timestamp: timestamp))
        }
        return points
    }

    /// For a schema none of the known queries fit: find a table with
    /// latitude and longitude columns under their common names.
    private static func discoverAndQuery(_ database: OpaquePointer) throws(ActivityParseError) -> [TrackPoint]? {
        let schemaQuery = """
            SELECT m.name, p.name FROM sqlite_master m
            JOIN pragma_table_info(m.name) p
            WHERE m.type = 'table'
            ORDER BY m.name, p.cid
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, schemaQuery, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var schema: [String: [String]] = [:]
        var tables: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_INTERRUPT { throw .malformed("the database takes too long to read") }
            guard step == SQLITE_ROW else { break }
            guard let tableText = sqlite3_column_text(statement, 0),
                  let columnText = sqlite3_column_text(statement, 1) else { continue }
            let table = String(cString: tableText)
            if schema[table] == nil { tables.append(table) }
            schema[table, default: []].append(String(cString: columnText))
        }

        let latNames = ["latitude", "lat", "zlatitude", "zlat"]
        let lonNames = ["longitude", "lon", "lng", "zlongitude", "zlon", "zlng"]
        let altNames = ["altitude", "elevation", "alt", "zaltitude", "zelevation", "zalt"]
        let timeNames = ["timestamp", "time", "created_at", "date", "ztimestamp", "ztime", "zdate"]

        func looksLikeLocations(_ table: String) -> Bool {
            let name = table.lowercased()
            return ["location", "gps", "track", "point"].contains { name.contains($0) }
        }
        func quoted(_ identifier: String) -> String {
            "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        for table in tables.filter(looksLikeLocations) + tables.filter({ !looksLikeLocations($0) }) {
            let columns = schema[table] ?? []
            let lowered = columns.map { $0.lowercased() }
            guard let latIndex = lowered.firstIndex(where: latNames.contains),
                  let lonIndex = lowered.firstIndex(where: lonNames.contains) else { continue }
            let altitude = lowered.firstIndex(where: altNames.contains).map { quoted(columns[$0]) }
            let time = lowered.firstIndex(where: timeNames.contains).map { quoted(columns[$0]) }

            var query = "SELECT \(quoted(columns[latIndex])), \(quoted(columns[lonIndex])), "
            query += "\(altitude ?? "NULL"), \(time ?? "NULL") FROM \(quoted(table))"
            if let time { query += " ORDER BY \(time) ASC" }
            let points = try locations(database, query: query)
            if !points.isEmpty { return points }
        }
        return nil
    }
}
