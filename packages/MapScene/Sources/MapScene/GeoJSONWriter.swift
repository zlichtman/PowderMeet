import Foundation
import MountainCore

extension SceneSource {
    /// This source as a GeoJSON FeatureCollection. Each feature's id is written both
    /// as the feature `id` and as an `id` property, so the adapter can address it
    /// for feature-state and read it back from a tap.
    public func geoJSON() -> String { GeoJSONWriter.featureCollection(features) }
}

/// Writes GeoJSON text directly. The map SDK parses a string off the main thread,
/// so a scene never passes through an untyped dictionary or a second decode.
public enum GeoJSONWriter {
    public static func featureCollection(_ features: [SceneFeature]) -> String {
        var out = "{\"type\":\"FeatureCollection\",\"features\":["
        out.reserveCapacity(features.count * 256)
        for (i, feature) in features.enumerated() {
            if i > 0 { out.append(",") }
            write(feature, to: &out)
        }
        out.append("]}")
        return out
    }

    private static func write(_ feature: SceneFeature, to out: inout String) {
        out.append("{\"type\":\"Feature\",\"id\":")
        write(feature.id, to: &out)
        out.append(",\"properties\":{\"id\":")
        write(feature.id, to: &out)
        for key in feature.properties.keys.sorted() where key != "id" {
            out.append(",")
            write(key, to: &out)
            out.append(":")
            switch feature.properties[key] {
            case .string(let value): write(value, to: &out)
            case .number(let value): write(value, to: &out)
            case .bool(let value): out.append(value ? "true" : "false")
            case nil: out.append("null")
            }
        }
        out.append("},\"geometry\":{\"type\":")
        switch feature.shape {
        case .point(let c):
            out.append("\"Point\",\"coordinates\":")
            write(c, to: &out)
        case .line(let line):
            out.append("\"LineString\",\"coordinates\":")
            write(line, to: &out)
        case .lines(let lines):
            out.append("\"MultiLineString\",\"coordinates\":[")
            for (i, line) in lines.enumerated() {
                if i > 0 { out.append(",") }
                write(line, to: &out)
            }
            out.append("]")
        case .polygon(let ring):
            out.append("\"Polygon\",\"coordinates\":[")
            write(ring, to: &out)
            out.append("]")
        }
        out.append("}}")
    }

    private static func write(_ line: [Coordinate], to out: inout String) {
        out.append("[")
        for (i, c) in line.enumerated() {
            if i > 0 { out.append(",") }
            write(c, to: &out)
        }
        out.append("]")
    }

    private static func write(_ c: Coordinate, to out: inout String) {
        out.append("[")
        write(c.lon, places: 1e7, to: &out)
        out.append(",")
        write(c.lat, places: 1e7, to: &out)
        out.append("]")
    }

    /// Fixed-point with no exponent; `places` is the rounding scale (1e7 is about a
    /// centimetre of longitude).
    private static func write(_ value: Double, places: Double = 1e4, to out: inout String) {
        guard value.isFinite else {
            out.append("0")
            return
        }
        let scaled = (abs(value) * places).rounded()
        guard scaled < 9e15 else {
            out.append(String(Int64(value.rounded())))
            return
        }
        let whole = Int64(scaled / places)
        let fraction = Int64(scaled) - whole * Int64(places)
        if value < 0, scaled > 0 { out.append("-") }
        out.append(String(whole))
        guard fraction > 0 else { return }
        var digits = String(fraction)
        let width = String(Int64(places)).count - 1
        digits = String(repeating: "0", count: width - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        out.append(".")
        out.append(digits)
    }

    private static func write(_ text: String, to out: inout String) {
        out.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}
