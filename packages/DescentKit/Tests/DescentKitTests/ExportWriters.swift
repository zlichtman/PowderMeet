import Foundation
@testable import DescentKit

/// Writers for the formats `DescentKit` reads, so a track can be re-exported
/// the way another app would write it. They exist to build cross-format pairs
/// of one ski day and small files that isolate one parser behaviour; they are
/// written from the format documentation, not from the parsers.
enum ExportWriters {
    // MARK: GPX and TCX

    /// `secondsOnly` rounds times to whole seconds and coordinates to six
    /// places, as most GPX exporters do. `zone` false writes times with no
    /// zone designator.
    static func gpx(
        _ points: [TrackPoint], creator: String = "StravaGPX", secondsOnly: Bool = true,
        elevation: Bool = true, time: Bool = true, zone: Bool = true
    ) -> Data {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        text += "<gpx creator=\"\(creator)\" version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        text += "<trk><name>Ski day</name><type>alpine_ski</type><trkseg>\n"
        for point in points {
            let lat = secondsOnly ? String(format: "%.6f", point.lat) : "\(point.lat)"
            let lon = secondsOnly ? String(format: "%.6f", point.lon) : "\(point.lon)"
            text += "<trkpt lat=\"\(lat)\" lon=\"\(lon)\">"
            if elevation, let metres = point.elevationM {
                text += "<ele>\(secondsOnly ? String(format: "%.1f", metres) : "\(metres)")</ele>"
            }
            if time, let stamp = point.timestamp {
                text += "<time>\(iso(stamp, secondsOnly: secondsOnly, zone: zone))</time>"
            }
            text += "</trkpt>\n"
        }
        text += "</trkseg></trk></gpx>\n"
        return Data(text.utf8)
    }

    static func tcx(_ points: [TrackPoint], device: String = "Forerunner 965") -> Data {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        text += "<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\">"
        text += "<Activities><Activity Sport=\"Other\">"
        let start = points.first?.timestamp ?? Date(timeIntervalSince1970: 0)
        text += "<Id>\(iso(start, secondsOnly: true, zone: true))</Id>"
        text += "<Lap StartTime=\"\(iso(start, secondsOnly: true, zone: true))\"><Track>\n"
        for point in points {
            guard let stamp = point.timestamp else { continue }
            text += "<Trackpoint><Time>\(iso(stamp, secondsOnly: true, zone: true))</Time>"
            text += "<Position><LatitudeDegrees>\(String(format: "%.6f", point.lat))</LatitudeDegrees>"
            text += "<LongitudeDegrees>\(String(format: "%.6f", point.lon))</LongitudeDegrees></Position>"
            if let metres = point.elevationM {
                text += "<AltitudeMeters>\(String(format: "%.1f", metres))</AltitudeMeters>"
            }
            text += "</Trackpoint>\n"
        }
        text += "</Track></Lap><Creator><Name>\(device)</Name></Creator></Activity></Activities>"
        text += "</TrainingCenterDatabase>\n"
        return Data(text.utf8)
    }

    private static func iso(_ date: Date, secondsOnly: Bool, zone: Bool) -> String {
        // Built by hand so the tests do not depend on a formatter's locale.
        let total = date.timeIntervalSince1970
        let whole = secondsOnly ? Int(total.rounded()) : Int(total.rounded(.down))
        let fraction = secondsOnly ? 0 : Int(((total - Double(whole)) * 1_000).rounded())
        var days = whole / 86_400
        let clock = whole % 86_400
        // Civil date from days since 1970 (proleptic Gregorian).
        days += 719_468
        let era = days / 146_097
        let dayOfEra = days - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        var text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, clock / 3_600, clock / 60 % 60, clock % 60
        )
        if !secondsOnly { text += String(format: ".%03d", min(fraction, 999)) }
        if zone { text += "Z" }
        return text
    }

    // MARK: FIT

    struct FITOptions {
        var manufacturer: UInt16 = 1
        var sport: UInt8 = 13
        var laps = 0
        var sessionDescentM: UInt16? = nil
        /// Write altitude as a developer field (float32 metres, named
        /// "altitude") instead of the native field.
        var altitudeAsDeveloperField = false
        var zeroFileCRC = false
    }

    static func fit(_ points: [TrackPoint], options: FITOptions = FITOptions()) -> Data {
        var body: [UInt8] = []
        func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func u32(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
        }
        func define(_ local: UInt8, global: UInt16, fields: [(UInt8, UInt8, UInt8)], developer: [(UInt8, UInt8, UInt8)] = []) {
            body.append((developer.isEmpty ? 0x40 : 0x60) | local)
            body += [0, 0] + u16(global) + [UInt8(fields.count)]
            for field in fields { body += [field.0, field.1, field.2] }
            if !developer.isEmpty {
                body.append(UInt8(developer.count))
                for field in developer { body += [field.0, field.1, field.2] }
            }
        }
        func stamp(_ date: Date?) -> UInt32 {
            UInt32(max(0, (date?.timeIntervalSince1970 ?? 631_065_600) - 631_065_600).rounded())
        }

        // File id: type (activity), manufacturer, product.
        define(0, global: 0, fields: [(0, 1, 0x00), (1, 2, 0x84), (2, 2, 0x84)])
        body += [0, 4] + u16(options.manufacturer) + u16(1)

        if options.altitudeAsDeveloperField {
            // Field description: developer index, field number, base type
            // (float32), name, units.
            define(1, global: 206, fields: [(0, 1, 0x02), (1, 1, 0x02), (2, 1, 0x02), (3, 16, 0x07), (8, 4, 0x07)])
            body += [1, 0, 0, 0x88]
            body += Array("altitude".utf8) + [UInt8](repeating: 0, count: 8)
            body += Array("m".utf8) + [0, 0, 0]
            define(2, global: 20, fields: [(253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85)], developer: [(0, 4, 0)])
        } else {
            define(2, global: 20, fields: [(253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85), (2, 2, 0x84)])
        }
        let semicircles = Double(Int64(1) << 31) / 180.0
        for point in points {
            body.append(2)
            body += u32(stamp(point.timestamp))
            body += u32(UInt32(bitPattern: Int32((point.lat * semicircles).rounded())))
            body += u32(UInt32(bitPattern: Int32((point.lon * semicircles).rounded())))
            if options.altitudeAsDeveloperField {
                body += u32(Float(point.elevationM ?? 0).bitPattern)
            } else {
                body += u16(point.elevationM.map { UInt16((($0 + 500) * 5).rounded()) } ?? 0xFFFF)
            }
        }

        if options.laps > 0 {
            // Lap: timestamp, start time, elapsed time (ms).
            define(3, global: 19, fields: [(253, 4, 0x86), (2, 4, 0x86), (7, 4, 0x86)])
            for _ in 0..<options.laps {
                body.append(3)
                body += u32(stamp(points.last?.timestamp)) + u32(stamp(points.first?.timestamp)) + u32(60_000)
            }
        }
        // Session: timestamp, sport, total descent, lap count.
        define(4, global: 18, fields: [(253, 4, 0x86), (5, 1, 0x00), (23, 2, 0x84), (26, 2, 0x84)])
        body.append(4)
        body += u32(stamp(points.last?.timestamp)) + [options.sport]
        body += u16(options.sessionDescentM ?? 0xFFFF) + u16(UInt16(options.laps))

        var file: [UInt8] = [14, 0x20] + u16(2_140) + u32(UInt32(body.count)) + Array(".FIT".utf8)
        file += u16(FITParser.crc16(file))
        file += body
        file += u16(options.zeroFileCRC ? 0 : FITParser.crc16(file))
        return Data(file)
    }

    // MARK: Ski Tracks

    /// A `.skiz` archive as the two open-source tools describe it. `runs` are
    /// the time windows Ski Tracks would have labelled as ski runs.
    static func skiz(
        _ points: [TrackPoint], runs: [(start: Date, end: Date)], declaredDescents: Int? = nil,
        segmentClockOffsetS: Double = 0, descentsText: String? = nil
    ) -> Data {
        var nodes = ""
        for point in points {
            guard let stamp = point.timestamp else { continue }
            nodes += String(
                format: "%.3f,%.6f,%.6f,%.2f,0.00,%.6f,5,0.25\n", stamp.timeIntervalSince1970,
                point.lat, point.lon, point.elevationM ?? 0, point.speedMS ?? 0
            )
        }
        var segments = "4\n"
        for (index, run) in runs.enumerated() {
            let start = run.start.timeIntervalSince1970 + segmentClockOffsetS
            let end = run.end.timeIntervalSince1970 + segmentClockOffsetS
            segments += String(format: "%.6f,%.6f,8,0,%d,Ski Run %d,,ski_run,,,", start, end, index + 1, index + 1)
            segments += "00000000-0000-0000-0000-00000000000\(index % 10),"
            segments += String(format: "%.1f,8.0,1200.0,-300.0,15.0,25.0,40.0,2000.0,2300.0,2300.0,2000.0\n", end - start)
        }
        var track = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        track += "<track version=\"1.0\" name=\"Day at the hill\" activity=\"skiing\" tz=\"-07:00\">"
        track += "<metrics><totaldescent>3000.0</totaldescent>"
        track += "<descents>\(descentsText ?? String(declaredDescents ?? runs.count))</descents></metrics></track>\n"
        return zip([
            ("Track.xml", Data(track.utf8)), ("Nodes.csv", Data(nodes.utf8)), ("Segment.csv", Data(segments.utf8)),
        ])
    }

    /// A zip with stored (uncompressed) entries.
    static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func u32(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
        }
        var output: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            let name = Array(entry.name.utf8)
            let bytes = [UInt8](entry.data)
            let crc = crc32(bytes)
            let offset = UInt32(output.count)
            let shared = u16(20) + u16(0) + u16(0) + u16(0) + u16(0x21)
                + u32(crc) + u32(UInt32(bytes.count)) + u32(UInt32(bytes.count)) + u16(name.count) + u16(0)
            output += u32(0x0403_4B50) + shared + name + bytes
            central += u32(0x0201_4B50) + u16(20) + shared + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + name
        }
        let centralOffset = UInt32(output.count)
        output += central
        output += u32(0x0605_4B50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count)
            + u32(UInt32(central.count)) + u32(centralOffset) + u16(0)
        return Data(output)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }
}

/// Synthetic ski days with known answers.
enum SyntheticTrack {
    static let base = Date(timeIntervalSince1970: 1_768_000_000)

    /// A chairlift ride: straight, one speed, climbing.
    static func lift(from start: TrackPoint, climbM: Double, seconds: Int, speedMS: Double = 2.5) -> [TrackPoint] {
        (1...seconds).map { second in
            TrackPoint(
                lat: start.lat + Double(second) * speedMS / 111_320,
                lon: start.lon,
                elevationM: (start.elevationM ?? 0) + climbM * Double(second) / Double(seconds),
                timestamp: start.timestamp?.addingTimeInterval(Double(second))
            )
        }
    }

    /// A ski run: turns across the fall line at a speed that keeps changing.
    static func run(from start: TrackPoint, dropM: Double, seconds: Int, speedMS: Double = 9) -> [TrackPoint] {
        var lat = start.lat
        return (1...seconds).map { second in
            let phase = Double(second) / 6
            let speed = speedMS * (1 + 0.45 * sin(phase * 0.9))
            lat -= speed * 0.8 / 111_320
            return TrackPoint(
                lat: lat,
                lon: start.lon + 0.0006 * sin(phase),
                elevationM: (start.elevationM ?? 0) - dropM * Double(second) / Double(seconds),
                timestamp: start.timestamp?.addingTimeInterval(Double(second))
            )
        }
    }

    /// Standing still, with a little GPS wander.
    static func wait(at point: TrackPoint, seconds: Int) -> [TrackPoint] {
        (1...seconds).map { second in
            TrackPoint(
                lat: point.lat + 0.000003 * sin(Double(second)),
                lon: point.lon + 0.000003 * cos(Double(second)),
                elevationM: (point.elevationM ?? 0) + 0.4 * sin(Double(second) / 7),
                timestamp: point.timestamp?.addingTimeInterval(Double(second))
            )
        }
    }

    static var origin: TrackPoint {
        TrackPoint(lat: 39.6, lon: -106.5, elevationM: 2_800, timestamp: base)
    }

    /// `laps` lift rides each followed by a run back down, 300 m of vertical.
    static func day(laps: Int, from start: TrackPoint = origin) -> [TrackPoint] {
        var points = [start]
        for _ in 0..<laps {
            points += lift(from: points[points.count - 1], climbM: 300, seconds: 400)
            points += wait(at: points[points.count - 1], seconds: 40)
            points += run(from: points[points.count - 1], dropM: 300, seconds: 180)
            points += wait(at: points[points.count - 1], seconds: 60)
        }
        return points
    }
}
