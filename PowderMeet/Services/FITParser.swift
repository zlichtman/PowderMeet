//
//  FITParser.swift
//  PowderMeet
//
//  Focused binary parser for Garmin FIT (Flexible and Interoperable Data Transfer) files.
//  Extracts GPS record messages (mesg_num = 20) with lat, lon, altitude, timestamp.
//  Outputs [GPXTrack] for pipeline compatibility.
//
//  FIT format reference: https://developer.garmin.com/fit/protocol/
//  - 14-byte header (or 12-byte legacy)
//  - Data records with definition + data messages
//  - Record message (mesg_num 20): fields 0=lat, 1=lon, 2=altitude, 253=timestamp
//  - Lat/lon stored as semicircles: degrees = value × (180 / 2^31)
//  - Timestamp: seconds since 1989-12-31 00:00:00 UTC (FIT epoch)
//

import Foundation

nonisolated struct FITParser {
    // FIT epoch: 1989-12-31 00:00:00 UTC. Using a Unix epoch offset (instead
    // of `Calendar.date(from:)` which can theoretically return nil) so the
    // value can be a true compile-time constant — no force-unwrap.
    // 631065600 = 1989-12-31 00:00:00 UTC, in seconds since 1970-01-01 UTC.
    private static let fitEpoch: Date = Date(timeIntervalSince1970: 631_065_600)

    private static let semicircleToDegrees: Double = 180.0 / Double(Int64(1) << 31)

    // MARK: - Public API

    /// Lap-level stats extracted from FIT `mesg_num=21` (lap) messages.
    /// Each ski run on Garmin watches is normally written as one lap;
    /// the device computes top speed, distance, and descent at lap-close
    /// time so we can use them directly instead of re-deriving from the
    /// per-second record stream.
    private struct ParsedLap {
        let startTime: Date
        let totalElapsedSeconds: Double
        let totalDistanceMeters: Double?
        let maxSpeedMS: Double?
        let avgSpeedMS: Double?
        let totalDescentMeters: Double?
    }

    /// Returns the combined point/lap stream from one or more chained FIT
    /// members. Every member must pass its own size, CRC, definition, and
    /// record-boundary validation; one corrupt member rejects the whole source
    /// so callers never receive a plausible-looking partial activity.
    private static func parseInternal(data: Data) -> (points: [GPXTrackPoint], laps: [ParsedLap]) {
        var cursor = 0
        var allPoints: [GPXTrackPoint] = []
        var allLaps: [ParsedLap] = []

        while cursor < data.count {
            guard cursor <= data.count - 12 else { return ([], []) }
            let headerSize = Int(data[cursor])
            guard headerSize == 12 || headerSize == 14 else { return ([], []) }
            let dataSize = Int(readUInt32(data, at: cursor + 4, littleEndian: true))
            let memberSize = headerSize + dataSize + 2
            guard memberSize >= headerSize + 2,
                  cursor <= data.count - memberSize else {
                return ([], [])
            }
            let member = data.subdata(in: cursor..<(cursor + memberSize))
            guard let parsed = parseSingleFile(data: member) else {
                return ([], [])
            }
            allPoints.append(contentsOf: parsed.points)
            allLaps.append(contentsOf: parsed.laps)
            cursor += memberSize
        }

        return (allPoints, allLaps)
    }

    private static func parseSingleFile(
        data: Data
    ) -> (points: [GPXTrackPoint], laps: [ParsedLap])? {
        guard data.count >= 14 else { return nil }
        let headerSize = Int(data[0])
        guard headerSize == 12 || headerSize == 14 else { return nil }
        let sig = String(data: data[8..<12], encoding: .ascii)
        guard sig == ".FIT" else { return nil }
        let dataSize = Int(readUInt32(data, at: 4, littleEndian: true))
        let dataEnd = headerSize + dataSize
        guard dataEnd >= headerSize, dataEnd + 2 == data.count else {
            return nil
        }
        if headerSize == 14 {
            let declaredHeaderCRC = readUInt16(data, at: 12, littleEndian: true)
            if declaredHeaderCRC != 0,
               declaredHeaderCRC != crc16(Data(data[0..<12])) {
                return nil
            }
        }
        let declaredFileCRC = readUInt16(data, at: dataEnd, littleEndian: true)
        guard declaredFileCRC == crc16(Data(data[0..<dataEnd])) else {
            return nil
        }

        var points: [GPXTrackPoint] = []
        var laps: [ParsedLap] = []
        var offset = headerSize
        var definitions: [UInt8: FieldDefinition] = [:]
        var lastTimestamp: UInt32?

        while offset < dataEnd {
            let recordHeader = data[offset]
            offset += 1
            let isCompressedTimestamp = (recordHeader & 0x80) != 0
            if isCompressedTimestamp {
                let localType = (recordHeader >> 5) & 0x03
                guard let def = definitions[localType],
                      offset + def.totalFieldSize <= dataEnd else {
                    return nil
                }
                let messageStart = offset
                guard let previous = lastTimestamp else { return nil }
                let timestamp = reconstructedTimestamp(
                    previous: previous,
                    offset: recordHeader & 0x1F
                )
                lastTimestamp = timestamp
                if def.globalMesgNum == 20,
                   let point = parseRecord(
                       data: data,
                       def: def,
                       messageStart: messageStart,
                       timestampOverride: timestamp
                   ) {
                    points.append(point)
                } else if def.globalMesgNum == 21,
                          let lap = parseLap(
                              data: data,
                              def: def,
                              messageStart: messageStart
                          ) {
                    laps.append(lap)
                }
                offset = messageStart + def.totalFieldSize
                continue
            }
            guard (recordHeader & 0x10) == 0 else { return nil }
            let isDefinition = (recordHeader & 0x40) != 0
            let localType = recordHeader & 0x0F

            if isDefinition {
                guard offset + 5 <= dataEnd else { return nil }
                let arch = data[offset + 1]
                guard arch <= 1 else { return nil }
                let isLittleEndian = arch == 0
                offset += 2
                let globalMesgNum: UInt16
                if isLittleEndian {
                    globalMesgNum = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                } else {
                    globalMesgNum = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
                }
                offset += 2
                let numFields = Int(data[offset]); offset += 1
                guard offset + numFields * 3 <= dataEnd else { return nil }
                var fields: [(fieldNum: UInt8, size: UInt8, baseType: UInt8)] = []
                var totalSize = 0
                for _ in 0..<numFields {
                    fields.append((data[offset], data[offset + 1], data[offset + 2]))
                    totalSize += Int(data[offset + 1])
                    offset += 3
                }
                let hasDeveloperFields = (recordHeader & 0x20) != 0
                var devFieldsSize = 0
                if hasDeveloperFields {
                    guard offset < dataEnd else { return nil }
                    let numDevFields = Int(data[offset]); offset += 1
                    guard offset + numDevFields * 3 <= dataEnd else { return nil }
                    for _ in 0..<numDevFields {
                        devFieldsSize += Int(data[offset + 1])
                        offset += 3
                    }
                }
                definitions[localType] = FieldDefinition(
                    globalMesgNum: globalMesgNum,
                    isLittleEndian: isLittleEndian,
                    fields: fields,
                    totalFieldSize: totalSize + devFieldsSize
                )
            } else {
                guard let def = definitions[localType],
                      offset + def.totalFieldSize <= dataEnd else {
                    return nil
                }
                let messageStart = offset
                if let timestamp = timestampValue(
                    data: data,
                    def: def,
                    messageStart: messageStart
                ) {
                    lastTimestamp = timestamp
                }

                if def.globalMesgNum == 20 { // record
                    if let pt = parseRecord(
                        data: data,
                        def: def,
                        messageStart: messageStart
                    ) {
                        points.append(pt)
                    }
                } else if def.globalMesgNum == 21 { // lap
                    if let lap = parseLap(data: data, def: def, messageStart: messageStart) {
                        laps.append(lap)
                    }
                }

                offset = messageStart + def.totalFieldSize
                guard offset >= messageStart else { return nil }
            }
        }

        return (points, laps)
    }

    /// Garmin FIT compressed timestamp headers carry the low five bits of the
    /// next timestamp and roll over every 32 seconds.
    static func reconstructedTimestamp(previous: UInt32, offset: UInt8) -> UInt32 {
        let lowBits = UInt32(offset & 0x1F)
        let previousLowBits = previous & 0x1F
        let base = previous & 0xFFFF_FFE0
        return base + lowBits + (lowBits < previousLowBits ? 0x20 : 0)
    }

    private static func timestampValue(
        data: Data,
        def: FieldDefinition,
        messageStart: Int
    ) -> UInt32? {
        var fieldOffset = messageStart
        for field in def.fields {
            guard fieldOffset + Int(field.size) <= data.count else {
                return nil
            }
            if field.fieldNum == 253, field.size == 4 {
                let value = readUInt32(
                    data,
                    at: fieldOffset,
                    littleEndian: def.isLittleEndian
                )
                return value == UInt32.max ? nil : value
            }
            fieldOffset += Int(field.size)
        }
        return nil
    }

    static func parse(data: Data) -> [GPXTrack] {
        let result = parseInternal(data: data)
        guard !result.points.isEmpty else { return [] }
        return [GPXTrack(name: "FIT Activity", points: result.points)]
    }

    /// Unified entry — emits one `ParsedRunSegment` per FIT lap message
    /// (mesg_num=21), with native top/avg speed, distance, and descent.
    /// Falls back to a single synthetic segment containing every record
    /// point when the file has no lap messages (some Garmin profiles
    /// don't write them for ski activities).
    static func parseUnified(data: Data, sourceFileHash: String) -> ParsedActivity {
        let result = parseInternal(data: data)
        var segments: [ParsedRunSegment] = []
        if !result.laps.isEmpty {
            for (idx, lap) in result.laps.enumerated() {
                let endTime = lap.startTime.addingTimeInterval(lap.totalElapsedSeconds)
                let pointsInLap = result.points.filter { p in
                    guard let t = p.timestamp else { return false }
                    return t >= lap.startTime && t <= endTime
                }
                segments.append(ParsedRunSegment(
                    runNumber: idx + 1,
                    startTime: lap.startTime,
                    endTime: endTime,
                    durationSeconds: lap.totalElapsedSeconds,
                    topSpeedMS: lap.maxSpeedMS,
                    avgSpeedMS: lap.avgSpeedMS,
                    distanceMeters: lap.totalDistanceMeters,
                    verticalMeters: lap.totalDescentMeters,
                    points: pointsInLap
                ))
            }
        } else if !result.points.isEmpty {
            // No lap messages — single synthetic segment so the importer
            // still imports the activity. It'll fall back to elevation-
            // segmentation downstream if it cares about per-run splits.
            let start = result.points.first?.timestamp ?? Date()
            let end = result.points.last?.timestamp ?? start
            segments.append(ParsedRunSegment(
                runNumber: 0,  // sentinel: synthesized, not a real lap
                startTime: start,
                endTime: end,
                durationSeconds: end.timeIntervalSince(start),
                topSpeedMS: nil,
                avgSpeedMS: nil,
                distanceMeters: nil,
                verticalMeters: nil,
                points: result.points
            ))
        }
        return ParsedActivity(
            source: .fit,
            resortName: nil,  // FIT doesn't carry a resort/place name natively
            sourceFileHash: sourceFileHash,
            segments: segments
        )
    }

    // MARK: - Per-message decoders

    private static func parseRecord(
        data: Data,
        def: FieldDefinition,
        messageStart: Int,
        timestampOverride: UInt32? = nil
    ) -> GPXTrackPoint? {
        var lat: Int32?
        var lon: Int32?
        var alt: UInt16?
        var enhancedAlt: UInt32?
        var speedRaw: UInt16?
        var enhancedSpeed: UInt32?
        var timestamp: UInt32?

        var fieldOffset = messageStart
        for field in def.fields {
            guard fieldOffset + Int(field.size) <= data.count else { break }
            switch field.fieldNum {
            case 0: if field.size == 4 { lat = readSInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 1: if field.size == 4 { lon = readSInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 2: if field.size == 2 { alt = readUInt16(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 6: if field.size == 2 { speedRaw = readUInt16(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 73: if field.size == 4 { enhancedSpeed = readUInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 78: if field.size == 4 { enhancedAlt = readUInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 253: if field.size == 4 { timestamp = readUInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            default: break
            }
            fieldOffset += Int(field.size)
        }
        guard let latVal = lat, let lonVal = lon,
              latVal != Int32.max, lonVal != Int32.max else { return nil }
        let latDeg = Double(latVal) * semicircleToDegrees
        let lonDeg = Double(lonVal) * semicircleToDegrees
        let elevation: Double?
        if let eAlt = enhancedAlt, eAlt != UInt32.max { elevation = Double(eAlt) / 5.0 - 500.0 }
        else if let alt, alt != UInt16.max { elevation = Double(alt) / 5.0 - 500.0 }
        else { elevation = nil }
        let resolvedTimestamp = timestampOverride
            ?? timestamp.flatMap { $0 == UInt32.max ? nil : $0 }
        let date = resolvedTimestamp.map {
            fitEpoch.addingTimeInterval(Double($0))
        }
        let speed: Double?
        if let eSpeed = enhancedSpeed, eSpeed != UInt32.max { speed = Double(eSpeed) / 1000.0 }
        else if let speedRaw, speedRaw != UInt16.max { speed = Double(speedRaw) / 1000.0 }
        else { speed = nil }
        return GPXTrackPoint(latitude: latDeg, longitude: lonDeg, elevation: elevation, timestamp: date, speed: speed)
    }

    /// Lap message decoder — FIT mesg_num=21. Field numbers:
    ///   2:  start_time (uint32, FIT epoch seconds)
    ///   7:  total_elapsed_time (uint32, scale 1000 → seconds)
    ///   9:  total_distance (uint32, scale 100 → meters)
    ///   13: avg_speed (uint16, scale 1000 → m/s)
    ///   14: max_speed (uint16, scale 1000 → m/s)
    ///   22: total_descent (uint16, scale 1 → meters)
    private static func parseLap(data: Data, def: FieldDefinition, messageStart: Int) -> ParsedLap? {
        var startTimeRaw: UInt32?
        var totalElapsedRaw: UInt32?
        var totalDistanceRaw: UInt32?
        var avgSpeedRaw: UInt16?
        var maxSpeedRaw: UInt16?
        var totalDescentRaw: UInt16?

        var fieldOffset = messageStart
        for field in def.fields {
            guard fieldOffset + Int(field.size) <= data.count else { break }
            switch field.fieldNum {
            case 2: if field.size == 4 { startTimeRaw = readUInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 7: if field.size == 4 { totalElapsedRaw = readUInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 9: if field.size == 4 { totalDistanceRaw = readUInt32(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 13: if field.size == 2 { avgSpeedRaw = readUInt16(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 14: if field.size == 2 { maxSpeedRaw = readUInt16(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            case 22: if field.size == 2 { totalDescentRaw = readUInt16(data, at: fieldOffset, littleEndian: def.isLittleEndian) }
            default: break
            }
            fieldOffset += Int(field.size)
        }

        guard let startRaw = startTimeRaw, startRaw != UInt32.max,
              let elapsedRaw = totalElapsedRaw, elapsedRaw != UInt32.max else {
            return nil
        }
        let startTime = fitEpoch.addingTimeInterval(Double(startRaw))
        let elapsed = Double(elapsedRaw) / 1000.0

        return ParsedLap(
            startTime: startTime,
            totalElapsedSeconds: elapsed,
            totalDistanceMeters: (totalDistanceRaw != nil && totalDistanceRaw! != UInt32.max)
                ? Double(totalDistanceRaw!) / 100.0 : nil,
            maxSpeedMS: (maxSpeedRaw != nil && maxSpeedRaw! != UInt16.max)
                ? Double(maxSpeedRaw!) / 1000.0 : nil,
            avgSpeedMS: (avgSpeedRaw != nil && avgSpeedRaw! != UInt16.max)
                ? Double(avgSpeedRaw!) / 1000.0 : nil,
            totalDescentMeters: (totalDescentRaw != nil && totalDescentRaw! != UInt16.max)
                ? Double(totalDescentRaw!) : nil
        )
    }


    // MARK: - Binary Helpers

    private struct FieldDefinition {
        let globalMesgNum: UInt16
        let isLittleEndian: Bool
        let fields: [(fieldNum: UInt8, size: UInt8, baseType: UInt8)]
        let totalFieldSize: Int
    }

    private static func readUInt16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        if littleEndian {
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        if littleEndian {
            return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
                   (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        } else {
            return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
                   (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }
    }

    private static func readSInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> Int32 {
        Int32(bitPattern: readUInt32(data, at: offset, littleEndian: littleEndian))
    }

    /// Garmin FIT CRC-16, computed nibble-by-nibble per the official protocol.
    /// Internal visibility keeps fixture generation honest without duplicating
    /// a second checksum implementation in tests.
    static func crc16(_ data: Data) -> UInt16 {
        let table: [UInt16] = [
            0x0000, 0xCC01, 0xD801, 0x1400,
            0xF001, 0x3C00, 0x2800, 0xE401,
            0xA001, 0x6C00, 0x7800, 0xB401,
            0x5000, 0x9C01, 0x8801, 0x4400,
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
