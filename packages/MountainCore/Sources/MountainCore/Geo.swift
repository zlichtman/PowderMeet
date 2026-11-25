import Foundation

/// A longitude/latitude pair in degrees (WGS 84). Encoded as `[lon, lat]`.
public struct Coordinate: Hashable, Sendable, Codable {
    public var lon: Double
    public var lat: Double

    public init(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        lon = try container.decode(Double.self)
        lat = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(lon)
        try container.encode(lat)
    }

    public var isValid: Bool {
        lon.isFinite && lat.isFinite && (-180...180).contains(lon) && (-90...90).contains(lat)
    }
}

/// One vertex of an edge's source geometry. Encoded as `[lon, lat, ele_m]`.
public struct GeoPoint: Hashable, Sendable, Codable {
    public var lon: Double
    public var lat: Double
    public var eleM: Double

    public init(lon: Double, lat: Double, eleM: Double) {
        self.lon = lon
        self.lat = lat
        self.eleM = eleM
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        lon = try container.decode(Double.self)
        lat = try container.decode(Double.self)
        eleM = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(lon)
        try container.encode(lat)
        try container.encode(eleM)
    }

    public var coordinate: Coordinate { Coordinate(lon: lon, lat: lat) }
}

/// `[minLon, minLat, maxLon, maxLat]`.
public struct BoundingBox: Hashable, Sendable, Codable {
    public var minLon: Double
    public var minLat: Double
    public var maxLon: Double
    public var maxLat: Double

    public init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon
        self.minLat = minLat
        self.maxLon = maxLon
        self.maxLat = maxLat
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        minLon = try container.decode(Double.self)
        minLat = try container.decode(Double.self)
        maxLon = try container.decode(Double.self)
        maxLat = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(minLon)
        try container.encode(minLat)
        try container.encode(maxLon)
        try container.encode(maxLat)
    }

    public func contains(_ c: Coordinate, tolerance: Double = 1e-7) -> Bool {
        c.lon >= minLon - tolerance && c.lon <= maxLon + tolerance
            && c.lat >= minLat - tolerance && c.lat <= maxLat + tolerance
    }
}

/// A GPS sample. `capturedAt` is the sensor's capture time, never a send time.
public struct Fix: Hashable, Sendable, Codable {
    public var coordinate: Coordinate
    public var accuracyM: Double
    public var capturedAt: Date
    /// GPS altitude above sea level, when the fix has one. Live recording needs
    /// it to tell runs from lift rides; routing does not read it.
    public var altitudeM: Double?
    /// Ground speed in m/s, when the device measured one.
    public var speedMS: Double?

    public init(
        coordinate: Coordinate, accuracyM: Double, capturedAt: Date,
        altitudeM: Double? = nil, speedMS: Double? = nil
    ) {
        self.coordinate = coordinate
        self.accuracyM = accuracyM
        self.capturedAt = capturedAt
        self.altitudeM = altitudeM
        self.speedMS = speedMS
    }
}

/// Where a point falls on a polyline.
public struct PolylineProjection: Hashable, Sendable {
    /// 0...1 by arc length from the first vertex.
    public var fraction: Double
    public var distanceM: Double
    public var closest: Coordinate
}

public enum Geo {
    public static let earthRadiusM = 6_371_000.0

    public static func haversineM(_ a: Coordinate, _ b: Coordinate) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.lat - a.lat) * radians
        let dLon = (b.lon - a.lon) * radians
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * radians) * cos(b.lat * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * asin(sqrt(min(1, max(0, h))))
    }

    /// Initial bearing in degrees clockwise from north, 0..<360.
    public static func bearingDeg(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Horizontal length of a polyline.
    public static func lengthM(_ line: [Coordinate]) -> Double {
        guard line.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<line.count { total += haversineM(line[i - 1], line[i]) }
        return total
    }

    /// Slope length of a polyline: each segment's horizontal run and rise combined.
    public static func slopeLengthM(_ line: [GeoPoint]) -> Double {
        guard line.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<line.count {
            let run = haversineM(line[i - 1].coordinate, line[i].coordinate)
            let rise = line[i].eleM - line[i - 1].eleM
            total += (run * run + rise * rise).squareRoot()
        }
        return total
    }

    /// Closest point on a polyline. Ties prefer the earlier point so progress never
    /// jumps forward where a line doubles back on itself.
    public static func project(_ point: Coordinate, onto line: [Coordinate]) -> PolylineProjection? {
        guard let first = line.first else { return nil }
        guard line.count > 1 else {
            return PolylineProjection(
                fraction: 0, distanceM: haversineM(point, first), closest: first
            )
        }
        var segmentLengths: [Double] = []
        segmentLengths.reserveCapacity(line.count - 1)
        var total = 0.0
        for i in 0..<(line.count - 1) {
            let length = haversineM(line[i], line[i + 1])
            segmentLengths.append(length)
            total += length
        }
        var best: PolylineProjection?
        var before = 0.0
        for i in 0..<(line.count - 1) {
            let (closest, t) = projectOntoSegment(point, line[i], line[i + 1])
            let along = before + segmentLengths[i] * t
            let candidate = PolylineProjection(
                fraction: total > 0 ? max(0, min(1, along / total)) : 0,
                distanceM: haversineM(point, closest),
                closest: closest
            )
            if best.map({ candidate.distanceM < $0.distanceM - 0.01 }) ?? true { best = candidate }
            before += segmentLengths[i]
        }
        return best
    }

    /// Point at `fraction` of a polyline's arc length.
    public static func interpolate(along line: [Coordinate], fraction: Double) -> Coordinate? {
        guard let first = line.first else { return nil }
        guard line.count > 1, fraction > 0 else { return first }
        if fraction >= 1, let last = line.last { return last }
        let total = lengthM(line)
        guard total > 0 else { return first }
        let target = total * fraction
        var accumulated = 0.0
        for i in 0..<(line.count - 1) {
            let segment = haversineM(line[i], line[i + 1])
            guard segment > 0 else { continue }
            if accumulated + segment >= target {
                let t = (target - accumulated) / segment
                return Coordinate(
                    lon: line[i].lon + (line[i + 1].lon - line[i].lon) * t,
                    lat: line[i].lat + (line[i + 1].lat - line[i].lat) * t
                )
            }
            accumulated += segment
        }
        return line.last
    }

    /// Local equirectangular projection: stable and accurate over a trail segment.
    private static func projectOntoSegment(
        _ p: Coordinate, _ a: Coordinate, _ b: Coordinate
    ) -> (Coordinate, Double) {
        let scale = max(0.01, cos((a.lat + b.lat + p.lat) / 3 * .pi / 180))
        let dx = (b.lon - a.lon) * scale
        let dy = b.lat - a.lat
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared <= 1e-18
            ? 0
            : max(0, min(1, (((p.lon - a.lon) * scale) * dx + (p.lat - a.lat) * dy) / lengthSquared))
        return (Coordinate(lon: a.lon + (b.lon - a.lon) * t, lat: a.lat + (b.lat - a.lat) * t), t)
    }
}

/// Geohash encode and neighbour lookup, used to partition a resort into cells.
public enum Geohash {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    public static func encode(_ c: Coordinate, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var ch = 0
        var even = true
        while hash.count < precision {
            if even {
                let mid = (lonRange.0 + lonRange.1) / 2
                if c.lon >= mid { ch |= 1 << (4 - bit); lonRange.0 = mid } else { lonRange.1 = mid }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if c.lat >= mid { ch |= 1 << (4 - bit); latRange.0 = mid } else { latRange.1 = mid }
            }
            even.toggle()
            if bit < 4 {
                bit += 1
            } else {
                hash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }
        return hash
    }

    public static func bounds(_ hash: String) -> BoundingBox? {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var even = true
        for character in hash {
            guard let index = base32.firstIndex(of: character) else { return nil }
            for i in 0..<5 {
                let bit = (index >> (4 - i)) & 1
                if even {
                    let mid = (lonRange.0 + lonRange.1) / 2
                    if bit == 1 { lonRange.0 = mid } else { lonRange.1 = mid }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2
                    if bit == 1 { latRange.0 = mid } else { latRange.1 = mid }
                }
                even.toggle()
            }
        }
        return BoundingBox(
            minLon: lonRange.0, minLat: latRange.0, maxLon: lonRange.1, maxLat: latRange.1
        )
    }

    /// The up-to-eight surrounding cells at the same precision. Cells past a pole
    /// are omitted; longitude wraps.
    public static func neighbors(_ hash: String) -> [String] {
        guard let box = bounds(hash) else { return [] }
        let centerLat = (box.minLat + box.maxLat) / 2
        let centerLon = (box.minLon + box.maxLon) / 2
        let dLat = box.maxLat - box.minLat
        let dLon = box.maxLon - box.minLon
        var out: [String] = []
        for dy in [-1, 0, 1] {
            for dx in [-1, 0, 1] where !(dy == 0 && dx == 0) {
                let lat = centerLat + Double(dy) * dLat
                guard lat >= -90, lat <= 90 else { continue }
                let lon = (centerLon + Double(dx) * dLon + 540)
                    .truncatingRemainder(dividingBy: 360) - 180
                out.append(encode(Coordinate(lon: lon, lat: lat), precision: hash.count))
            }
        }
        return out
    }
}
