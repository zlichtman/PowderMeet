import Foundation

/// Garmin FIT (Flexible and Interoperable Data Transfer) binary files, as
/// written by Garmin, Suunto, Coros and Wahoo devices and by phone apps that
/// export FIT.
///
/// - 12 or 14 byte header, then definition and data messages, then a CRC-16.
/// - File id (global 0): 1 manufacturer, 2 product.
/// - Session (global 18): 5 sport, 23 total descent, 26 lap count.
/// - Lap (global 19): counted only. Ski watches write a lap per detected run,
///   but the count is unreliable, so laps never set run boundaries.
/// - Record (global 20): 0 lat, 1 lon, 2 altitude, 6 speed, 73 enhanced speed,
///   78 enhanced altitude, 253 timestamp.
/// - Field description (global 206): developer fields. One that declares a
///   native record altitude or speed field, or is named for one, fills that
///   value when the record has no native field.
/// - Latitude and longitude are semicircles; timestamps count seconds from
///   1989-12-31 00:00:00 UTC.
///
/// The result is one segment holding every record with a position.
/// `DescentSegmenter` finds the runs.
public enum FITParser: ActivityParser {
    public static let source = ActivitySource.fit

    /// 1989-12-31 00:00:00 UTC as seconds since 1970.
    private static let fitEpoch = Date(timeIntervalSince1970: 631_065_600)
    private static let semicircleToDegrees = 180.0 / Double(Int64(1) << 31)

    private struct Field {
        var number: UInt8
        var size: Int
    }

    private struct DeveloperField {
        var number: UInt8
        var size: Int
        var developerIndex: UInt8
    }

    private struct Definition {
        var globalMessage: UInt16
        var littleEndian: Bool
        var fields: [Field]
        var developerFields: [DeveloperField]
        var totalSize: Int
    }

    /// What a developer field holds, from its field description message.
    private struct DeveloperMeaning {
        enum Target { case altitude, speed }
        var target: Target
        var baseType: UInt8
        var scale: Double?
        var offset: Double?
    }

    private struct Member {
        var points: [TrackPoint] = []
        var lapCount = 0
        var manufacturer: UInt16?
        var sport: UInt8?
        var sessionDescentM: Double?
        var sessionLaps: Int?
    }

    public static func parse(_ data: Data) throws(ActivityParseError) -> ParsedActivity {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[8..<12]) == Array(".FIT".utf8) else {
            throw .notThisFormat
        }
        let file = try parseChain(bytes)

        var segments: [ParsedSegment] = []
        if !file.points.isEmpty {
            let start = file.points.first?.timestamp
            let end = file.points.last?.timestamp
            segments.append(ParsedSegment(
                number: 1,
                startTime: start,
                endTime: end,
                durationS: start.flatMap { s in end.map { $0.timeIntervalSince(s) } },
                points: file.points
            ))
        }
        // Lap counts mean runs only in a ski or snowboard activity.
        let isSnowSport = file.sport == 13 || file.sport == 14
        let laps = file.sessionLaps ?? (file.lapCount > 0 ? file.lapCount : nil)
        // FIT carries no resort or place name.
        return ParsedActivity(
            source: .fit, resortName: nil, segments: segments,
            sourceApp: file.manufacturer.map(manufacturerName),
            declared: DeclaredTotals(
                runCount: isSnowSport ? laps : nil,
                verticalM: file.sessionDescentM,
                sport: file.sport.map(sportName)
            )
        )
    }

    static func manufacturerName(_ id: UInt16) -> String {
        switch id {
        case 1: "Garmin"
        case 13: "Dynastream"
        case 23: "Suunto"
        case 32: "Wahoo"
        case 123: "Polar"
        case 255: "FIT development id"
        case 260: "Zwift"
        case 265: "Strava"
        case 294: "Coros"
        default: "FIT manufacturer \(id)"
        }
    }

    static func sportName(_ id: UInt8) -> String {
        switch id {
        case 1: "running"
        case 2: "cycling"
        case 12: "cross_country_skiing"
        case 13: "alpine_skiing"
        case 14: "snowboarding"
        default: "sport \(id)"
        }
    }

    /// Reads one or more chained FIT members. Every member must pass its own
    /// size, CRC, definition and record-boundary checks; one corrupt member
    /// rejects the whole source, so no plausible-looking partial activity is
    /// ever returned.
    private static func parseChain(_ bytes: [UInt8]) throws(ActivityParseError) -> Member {
        var cursor = 0
        var file = Member()
        while cursor < bytes.count {
            guard cursor <= bytes.count - 12 else { throw .malformed("truncated FIT header") }
            let headerSize = Int(bytes[cursor])
            guard headerSize == 12 || headerSize == 14 else { throw .malformed("bad FIT header size") }
            let dataSize = Int(u32(bytes, cursor + 4, littleEndian: true))
            let memberSize = headerSize + dataSize + 2
            guard cursor <= bytes.count - memberSize else { throw .malformed("truncated FIT member") }
            let member = Array(bytes[cursor..<(cursor + memberSize)])
            guard let parsed = parseMember(member) else { throw .malformed("corrupt FIT member") }
            file.points.append(contentsOf: parsed.points)
            file.lapCount += parsed.lapCount
            file.manufacturer = file.manufacturer ?? parsed.manufacturer
            file.sport = file.sport ?? parsed.sport
            if let descent = parsed.sessionDescentM {
                file.sessionDescentM = (file.sessionDescentM ?? 0) + descent
            }
            if let laps = parsed.sessionLaps { file.sessionLaps = (file.sessionLaps ?? 0) + laps }
            cursor += memberSize
        }
        return file
    }

    private static func parseMember(_ data: [UInt8]) -> Member? {
        guard data.count >= 14 else { return nil }
        let headerSize = Int(data[0])
        guard headerSize == 12 || headerSize == 14 else { return nil }
        guard Array(data[8..<12]) == Array(".FIT".utf8) else { return nil }
        let dataSize = Int(u32(data, 4, littleEndian: true))
        let dataEnd = headerSize + dataSize
        guard dataEnd + 2 == data.count else { return nil }
        if headerSize == 14 {
            let declared = u16(data, 12, littleEndian: true)
            if declared != 0, declared != crc16(data[0..<12]) { return nil }
        }
        // Some phone exporters leave the file CRC as zero; the structural
        // checks below still reject a damaged body.
        let fileCRC = u16(data, dataEnd, littleEndian: true)
        guard fileCRC == 0 || fileCRC == crc16(data[0..<dataEnd]) else { return nil }

        var member = Member()
        var offset = headerSize
        var definitions: [UInt8: Definition] = [:]
        var meanings: [UInt16: DeveloperMeaning] = [:]
        var lastTimestamp: UInt32?

        func handle(_ definition: Definition, at offset: Int, timestampOverride: UInt32?) {
            switch definition.globalMessage {
            case 0:
                if let value = unsigned(data, definition, field: 1, at: offset), value != 0xFFFF {
                    member.manufacturer = UInt16(truncatingIfNeeded: value)
                }
            case 18:
                if let value = unsigned(data, definition, field: 5, at: offset), value != 0xFF {
                    member.sport = UInt8(truncatingIfNeeded: value)
                }
                if let value = unsigned(data, definition, field: 23, at: offset), value != 0xFFFF {
                    member.sessionDescentM = (member.sessionDescentM ?? 0) + Double(value)
                }
                if let value = unsigned(data, definition, field: 26, at: offset), value != 0xFFFF {
                    member.sessionLaps = (member.sessionLaps ?? 0) + Int(value)
                }
            case 19:
                member.lapCount += 1
            case 20:
                if let point = record(
                    data, definition, at: offset, timestampOverride: timestampOverride, meanings: meanings
                ) {
                    member.points.append(point)
                }
            case 206:
                if let (key, meaning) = developerMeaning(data, definition, at: offset) {
                    meanings[key] = meaning
                }
            default:
                break
            }
        }

        while offset < dataEnd {
            let header = data[offset]
            offset += 1

            if header & 0x80 != 0 {
                // Compressed timestamp header: two-bit local type, five-bit offset.
                let localType = (header >> 5) & 0x03
                guard let definition = definitions[localType],
                      offset + definition.totalSize <= dataEnd,
                      let previous = lastTimestamp else { return nil }
                let timestamp = reconstructedTimestamp(previous: previous, offset: header & 0x1F)
                lastTimestamp = timestamp
                handle(definition, at: offset, timestampOverride: timestamp)
                offset += definition.totalSize
                continue
            }

            guard header & 0x10 == 0 else { return nil }
            let localType = header & 0x0F

            if header & 0x40 != 0 {
                guard offset + 5 <= dataEnd else { return nil }
                let architecture = data[offset + 1]
                guard architecture <= 1 else { return nil }
                let littleEndian = architecture == 0
                let globalMessage = u16(data, offset + 2, littleEndian: littleEndian)
                let fieldCount = Int(data[offset + 4])
                offset += 5
                guard offset + fieldCount * 3 <= dataEnd else { return nil }
                var fields: [Field] = []
                var totalSize = 0
                for _ in 0..<fieldCount {
                    fields.append(Field(number: data[offset], size: Int(data[offset + 1])))
                    totalSize += Int(data[offset + 1])
                    offset += 3
                }
                var developerFields: [DeveloperField] = []
                if header & 0x20 != 0 {
                    // Developer fields follow the native ones in each message.
                    guard offset < dataEnd else { return nil }
                    let developerCount = Int(data[offset])
                    offset += 1
                    guard offset + developerCount * 3 <= dataEnd else { return nil }
                    for _ in 0..<developerCount {
                        developerFields.append(DeveloperField(
                            number: data[offset], size: Int(data[offset + 1]), developerIndex: data[offset + 2]
                        ))
                        totalSize += Int(data[offset + 1])
                        offset += 3
                    }
                }
                definitions[localType] = Definition(
                    globalMessage: globalMessage, littleEndian: littleEndian,
                    fields: fields, developerFields: developerFields, totalSize: totalSize
                )
            } else {
                guard let definition = definitions[localType],
                      offset + definition.totalSize <= dataEnd else { return nil }
                if let timestamp = timestampField(data, definition, at: offset) {
                    lastTimestamp = timestamp
                }
                handle(definition, at: offset, timestampOverride: nil)
                offset += definition.totalSize
            }
        }
        return member
    }

    /// An unsigned native field of 1, 2 or 4 bytes; nil when absent.
    private static func unsigned(
        _ data: [UInt8], _ definition: Definition, field number: UInt8, at start: Int
    ) -> UInt32? {
        var offset = start
        for field in definition.fields {
            if field.number == number {
                switch field.size {
                case 1: return UInt32(data[offset])
                case 2: return UInt32(u16(data, offset, littleEndian: definition.littleEndian))
                case 4: return u32(data, offset, littleEndian: definition.littleEndian)
                default: return nil
                }
            }
            offset += field.size
        }
        return nil
    }

    /// Reads a field description (global 206) and says whether the developer
    /// field it describes is an altitude or a speed for record messages.
    private static func developerMeaning(
        _ data: [UInt8], _ definition: Definition, at start: Int
    ) -> (UInt16, DeveloperMeaning)? {
        var developerIndex: UInt8?
        var fieldNumber: UInt8?
        var baseType: UInt8?
        var name = ""
        var units = ""
        var scale: Double?
        var fieldOffset: Double?
        var nativeMessage: UInt16?
        var nativeField: UInt8?

        var offset = start
        for field in definition.fields {
            switch field.number {
            case 0 where field.size == 1: developerIndex = data[offset]
            case 1 where field.size == 1: fieldNumber = data[offset]
            case 2 where field.size == 1: baseType = data[offset]
            case 3: name = string(data, offset, field.size)
            case 6 where field.size == 1: if data[offset] != 0xFF, data[offset] != 0 { scale = Double(data[offset]) }
            case 7 where field.size == 1: if data[offset] != 0x7F { fieldOffset = Double(Int8(bitPattern: data[offset])) }
            case 8: units = string(data, offset, field.size)
            case 14 where field.size == 2:
                let value = u16(data, offset, littleEndian: definition.littleEndian)
                if value != 0xFFFF { nativeMessage = value }
            case 15 where field.size == 1: if data[offset] != 0xFF { nativeField = data[offset] }
            default: break
            }
            offset += field.size
        }
        guard let developerIndex, let fieldNumber, let baseType else { return nil }

        var target: DeveloperMeaning.Target?
        if nativeMessage == 20, let nativeField {
            if nativeField == 2 || nativeField == 78 { target = .altitude }
            if nativeField == 6 || nativeField == 73 { target = .speed }
        } else if nativeMessage == nil {
            // No native mapping: go by the name, and only in SI units.
            let lowered = name.lowercased()
            if lowered == "altitude" || lowered == "enhanced_altitude" || lowered == "elevation",
               units.lowercased() == "m" { target = .altitude }
            if lowered == "speed" || lowered == "enhanced_speed", units.lowercased() == "m/s" { target = .speed }
        }
        guard let target else { return nil }
        let key = UInt16(developerIndex) << 8 | UInt16(fieldNumber)
        return (key, DeveloperMeaning(target: target, baseType: baseType, scale: scale, offset: fieldOffset))
    }

    private static func string(_ data: [UInt8], _ offset: Int, _ size: Int) -> String {
        let raw = data[offset..<(offset + size)].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    /// A developer field's number by its FIT base type; nil for an invalid
    /// value or a type that is not numeric.
    private static func developerValue(
        _ data: [UInt8], _ offset: Int, size: Int, baseType: UInt8, littleEndian le: Bool
    ) -> (value: Double, isFloat: Bool)? {
        switch (baseType & 0x1F, size) {
        case (0x01, 1): return data[offset] == 0x7F ? nil : (Double(Int8(bitPattern: data[offset])), false)
        case (0x02, 1): return data[offset] == 0xFF ? nil : (Double(data[offset]), false)
        case (0x03, 2):
            let raw = u16(data, offset, littleEndian: le)
            return raw == 0x7FFF ? nil : (Double(Int16(bitPattern: raw)), false)
        case (0x04, 2):
            let raw = u16(data, offset, littleEndian: le)
            return raw == 0xFFFF ? nil : (Double(raw), false)
        case (0x05, 4):
            let raw = u32(data, offset, littleEndian: le)
            return raw == 0x7FFF_FFFF ? nil : (Double(Int32(bitPattern: raw)), false)
        case (0x06, 4):
            let raw = u32(data, offset, littleEndian: le)
            return raw == .max ? nil : (Double(raw), false)
        case (0x08, 4):
            let value = Float(bitPattern: u32(data, offset, littleEndian: le))
            return value.isFinite ? (Double(value), true) : nil
        case (0x09, 8):
            let high = UInt64(u32(data, le ? offset + 4 : offset, littleEndian: le))
            let low = UInt64(u32(data, le ? offset : offset + 4, littleEndian: le))
            let value = Double(bitPattern: high << 32 | low)
            return value.isFinite ? (value, true) : nil
        default:
            return nil
        }
    }

    /// A compressed timestamp header carries the low five bits of the next
    /// timestamp, which roll over every 32 seconds.
    static func reconstructedTimestamp(previous: UInt32, offset: UInt8) -> UInt32 {
        let lowBits = UInt32(offset & 0x1F)
        let previousLowBits = previous & 0x1F
        let base = previous & 0xFFFF_FFE0
        return base &+ lowBits &+ (lowBits < previousLowBits ? 0x20 : 0)
    }

    private static func timestampField(_ data: [UInt8], _ definition: Definition, at start: Int) -> UInt32? {
        var offset = start
        for field in definition.fields {
            if field.number == 253, field.size == 4 {
                let value = u32(data, offset, littleEndian: definition.littleEndian)
                return value == .max ? nil : value
            }
            offset += field.size
        }
        return nil
    }

    private static func record(
        _ data: [UInt8], _ definition: Definition, at start: Int, timestampOverride: UInt32?,
        meanings: [UInt16: DeveloperMeaning]
    ) -> TrackPoint? {
        var lat: Int32?
        var lon: Int32?
        var altitude: UInt16?
        var enhancedAltitude: UInt32?
        var speed: UInt16?
        var enhancedSpeed: UInt32?
        var timestamp: UInt32?
        let le = definition.littleEndian

        var offset = start
        for field in definition.fields {
            switch (field.number, field.size) {
            case (0, 4): lat = Int32(bitPattern: u32(data, offset, littleEndian: le))
            case (1, 4): lon = Int32(bitPattern: u32(data, offset, littleEndian: le))
            case (2, 2): altitude = u16(data, offset, littleEndian: le)
            case (6, 2): speed = u16(data, offset, littleEndian: le)
            case (73, 4): enhancedSpeed = u32(data, offset, littleEndian: le)
            case (78, 4): enhancedAltitude = u32(data, offset, littleEndian: le)
            case (253, 4): timestamp = u32(data, offset, littleEndian: le)
            default: break
            }
            offset += field.size
        }
        guard let lat, let lon, lat != .max, lon != .max else { return nil }

        var elevation: Double?
        if let enhancedAltitude, enhancedAltitude != .max {
            elevation = Double(enhancedAltitude) / 5.0 - 500.0
        } else if let altitude, altitude != .max {
            elevation = Double(altitude) / 5.0 - 500.0
        }
        var speedMS: Double?
        if let enhancedSpeed, enhancedSpeed != .max {
            speedMS = Double(enhancedSpeed) / 1000.0
        } else if let speed, speed != .max {
            speedMS = Double(speed) / 1000.0
        }
        if elevation == nil || speedMS == nil, !meanings.isEmpty {
            for field in definition.developerFields {
                defer { offset += field.size }
                let key = UInt16(field.developerIndex) << 8 | UInt16(field.number)
                guard let meaning = meanings[key], let read = developerValue(
                    data, offset, size: field.size, baseType: meaning.baseType, littleEndian: le
                ) else { continue }
                switch meaning.target {
                case .altitude where elevation == nil:
                    // A float is already metres; an integer uses the declared
                    // scale, or the native altitude encoding when none is given.
                    elevation = read.isFloat && meaning.scale == nil
                        ? read.value
                        : read.value / (meaning.scale ?? 5) - (meaning.offset ?? (meaning.scale == nil ? 500 : 0))
                case .speed where speedMS == nil:
                    let value = read.isFloat && meaning.scale == nil
                        ? read.value : read.value / (meaning.scale ?? 1_000)
                    if value >= 0 { speedMS = value }
                default:
                    break
                }
            }
        }
        let resolved = timestampOverride ?? timestamp.flatMap { $0 == .max ? nil : $0 }
        return TrackPoint(
            lat: Double(lat) * semicircleToDegrees,
            lon: Double(lon) * semicircleToDegrees,
            elevationM: elevation,
            timestamp: resolved.map { fitEpoch.addingTimeInterval(Double($0)) },
            speedMS: speedMS
        )
    }

    private static func u16(_ data: [UInt8], _ offset: Int, littleEndian: Bool) -> UInt16 {
        littleEndian
            ? UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            : (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func u32(_ data: [UInt8], _ offset: Int, littleEndian: Bool) -> UInt32 {
        littleEndian
            ? UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            : (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    /// Garmin FIT CRC-16, computed a nibble at a time as the protocol defines.
    static func crc16(_ data: some Sequence<UInt8>) -> UInt16 {
        let table: [UInt16] = [
            0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
            0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
        ]
        var crc: UInt16 = 0
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = ((crc >> 4) & 0x0FFF) ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = ((crc >> 4) & 0x0FFF) ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
