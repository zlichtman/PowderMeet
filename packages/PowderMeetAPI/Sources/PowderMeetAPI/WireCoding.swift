import Foundation

/// JSON coding for everything that crosses the wire: PostgREST rows, RPC results
/// and realtime payloads. Keys are spelled out per type (snake_case), so the only
/// shared rule is the timestamp format.
public enum WireCoding {
    /// Parses a Postgres `timestamptz` as JSON prints it: ISO 8601 with a `T` or a
    /// space, zero to nine fractional digits, and `Z`, `+00`, `+00:00` or `+0000`.
    public static func date(from text: String) -> Date? {
        let bytes = Array(text.utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[index..<index + count] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            index += count
            return value
        }
        func skip(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), skip(45), let month = digits(2), skip(45), let day = digits(2),
              skip(84) || skip(32) || skip(116),
              let hour = digits(2), skip(58), let minute = digits(2), skip(58), let second = digits(2)
        else { return nil }

        var fraction = 0.0
        if skip(46) {
            var scale = 0.1
            var any = false
            while index < bytes.count, (48...57).contains(bytes[index]) {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
                any = true
            }
            guard any else { return nil }
        }

        var offsetS = 0
        if skip(90) || skip(122) {
            // UTC.
        } else if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
            let sign = bytes[index] == 43 ? 1 : -1
            index += 1
            guard let offsetHour = digits(2) else { return nil }
            var offsetMinute = 0
            if index < bytes.count {
                _ = skip(58)
                guard let parsed = digits(2) else { return nil }
                offsetMinute = parsed
            }
            offsetS = sign * (offsetHour * 3_600 + offsetMinute * 60)
        } else {
            return nil
        }
        guard index == bytes.count, (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60 else { return nil }

        // Days from the civil date (proleptic Gregorian), then seconds.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetS
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// ISO 8601 in UTC with millisecond precision, which Postgres accepts.
    public static func string(from date: Date) -> String {
        let total = (date.timeIntervalSince1970 * 1_000).rounded()
        let millis = Int(total)
        var days = millis / 86_400_000
        var rest = millis % 86_400_000
        if rest < 0 {
            rest += 86_400_000
            days -= 1
        }
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let hour = rest / 3_600_000, minute = rest / 60_000 % 60
        let second = rest / 1_000 % 60, milli = rest % 1_000
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):"
            + "\(pad(second, 2)).\(pad(milli, 3))Z"
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected a timestamp, got \(text)"
                ))
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Any JSON value: `jsonb` arguments and columns whose shape the client does not own.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
