//
//  Resort.swift
//  PowderMeet
//

import Foundation
import CoreLocation

// MARK: - Coordinate

struct Coordinate: Codable, Hashable {
    let lat: Double
    let lon: Double
    let ele: Double?
    /// Stable identity from the source geometry (OSM node ID when available).
    /// Routing uses this—not visual proximity—to prove that ways join.
    let sourceNodeID: Int64?

    nonisolated init(
        lat: Double,
        lon: Double,
        ele: Double? = nil,
        sourceNodeID: Int64? = nil
    ) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.sourceNodeID = sourceNodeID
    }
}

// MARK: - Bounding Box

nonisolated struct BoundingBox: Codable, Hashable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    var center: Coordinate {
        Coordinate(
            lat: (minLat + maxLat) / 2,
            lon: (minLon + maxLon) / 2
        )
    }

    /// Overpass QL bounding box string: south,west,north,east
    nonisolated var overpassBBox: String {
        "\(minLat),\(minLon),\(maxLat),\(maxLon)"
    }

    /// Approximate diagonal distance in meters (haversine).
    nonisolated var diagonalMeters: Double {
        haversine(
            from: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            to: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
        )
    }
}

// MARK: - Lift Type

nonisolated enum LiftType: String, Codable {
    case chairLift = "chair_lift"
    case gondola
    case cableCar = "cable_car"
    case dragLift = "drag_lift"
    case tBar = "t-bar"
    case jBar = "j-bar"
    case platter
    case ropeTow = "rope_tow"
    case magicCarpet = "magic_carpet"
    case funicular
    case zipLine = "zip_line"
    case station
    case unknown

    var displayName: String {
        switch self {
        case .chairLift:   return "Chairlift"
        case .gondola:     return "Gondola"
        case .cableCar:    return "Cable Car"
        case .dragLift:    return "Drag Lift"
        case .tBar:        return "T-Bar"
        case .jBar:        return "J-Bar"
        case .platter:     return "Platter"
        case .ropeTow:     return "Rope Tow"
        case .magicCarpet: return "Magic Carpet"
        case .funicular:   return "Funicular"
        case .zipLine:     return "Zip Line"
        case .station:     return "Station"
        case .unknown:     return "Lift"
        }
    }

    var icon: String {
        switch self {
        case .gondola, .cableCar, .funicular: return "cablecar"
        case .chairLift:                      return "tram.fill"
        default:                              return "arrow.up.circle"
        }
    }

    nonisolated static func from(osmValue: String?) -> LiftType {
        guard let val = osmValue?.lowercased() else { return .unknown }
        switch val {
        case "chair_lift":   return .chairLift
        case "gondola":      return .gondola
        case "cable_car":    return .cableCar
        case "drag_lift":    return .dragLift
        case "t-bar":        return .tBar
        case "j-bar":        return .jBar
        case "platter":      return .platter
        case "rope_tow":     return .ropeTow
        case "magic_carpet": return .magicCarpet
        case "funicular":    return .funicular
        case "zip_line":     return .zipLine
        case "station":      return .station
        default:             return .unknown
        }
    }
}

// MARK: - Trail

// `nonisolated` — Trail is decoded inside detached graph build /
// snapshot tasks; lengthMeters / displayName accessors must be callable
// without an actor hop.
nonisolated struct Trail: Codable, Identifiable {
    let id: Int64
    let name: String?
    let difficulty: RunDifficulty?
    let grooming: String?
    let coordinates: [Coordinate]
    let lit: Bool
    let ref: String?
    var isOpen: Bool

    var displayName: String {
        name ?? ref ?? "Unnamed \(difficulty?.displayName ?? "Unknown") Trail"
    }

    /// Approximate length in meters via Haversine
    var lengthMeters: Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<coordinates.count {
            total += haversine(from: coordinates[i-1], to: coordinates[i])
        }
        return total
    }

    var lengthDisplay: String {
        let m = lengthMeters
        if m >= 1000 {
            return String(format: "%.1f km", m / 1000)
        }
        return "\(Int(m)) m"
    }

    /// Elevation drop in meters
    var verticalDrop: Double? {
        let elevations = coordinates.compactMap { $0.ele }
        guard let maxEle = elevations.max(), let minEle = elevations.min() else { return nil }
        return maxEle - minEle
    }
}

/// A source-authored connector such as OSM `piste:type=connection`.
/// It is deliberately separate from ski runs so display/run counts remain clean.
nonisolated struct PisteConnection: Codable, Identifiable {
    let id: Int64
    let name: String?
    let coordinates: [Coordinate]
    var isOpen: Bool
}

// MARK: - Lift

struct Lift: Codable, Identifiable {
    let id: Int64
    let name: String?
    let type: LiftType
    let coordinates: [Coordinate]
    let capacity: Int?
    let occupancy: Int?
    var isOpen: Bool

    var isBidirectional: Bool? = nil

    var displayName: String {
        name ?? type.displayName
    }
}

// MARK: - Point of Interest

enum POIType: String, Codable {
    case station, lodge, restaurant, firstAid, rental, parking, restroom, summit, base
}

struct PointOfInterest: Codable, Identifiable {
    let id: Int64
    let name: String?
    let type: POIType
    let coordinate: Coordinate
}

// MARK: - Graph build hints (optional JSON overrides per resort)

struct ResortGraphBuildHints: Codable, Hashable, Sendable {
    /// When false, skip merging distinct named traverse ways by trail name (default true).
    var mergeNamedTraverseGroups: Bool?
}

// MARK: - Resort Data (full bundle)

nonisolated struct ResortData: Codable {
    let name: String
    let bounds: BoundingBox
    let trails: [Trail]
    let lifts: [Lift]
    /// Optional for backward decoding of older frozen ResortData payloads.
    let connections: [PisteConnection]?
    let pois: [PointOfInterest]
    let fetchDate: Date
    /// Optional tuning for `GraphBuilder.assignTrailGroups`; omitted in Overpass JSON.
    let graphBuildHints: ResortGraphBuildHints?

    nonisolated init(
        name: String,
        bounds: BoundingBox,
        trails: [Trail],
        lifts: [Lift],
        connections: [PisteConnection]? = nil,
        pois: [PointOfInterest],
        fetchDate: Date,
        graphBuildHints: ResortGraphBuildHints?
    ) {
        self.name = name
        self.bounds = bounds
        self.trails = trails
        self.lifts = lifts
        self.connections = connections
        self.pois = pois
        self.fetchDate = fetchDate
        self.graphBuildHints = graphBuildHints
    }

    var namedTrails: [Trail] {
        trails.filter { $0.name != nil }
    }

    /// Unique named runs (OSM splits one run into many way segments)
    var uniqueRunCount: Int {
        Set(trails.compactMap { $0.name }).count
    }

    var trailsByDifficulty: [RunDifficulty: [Trail]] {
        var result: [RunDifficulty: [Trail]] = [:]
        for trail in trails {
            guard let difficulty = trail.difficulty else { continue }
            result[difficulty, default: []].append(trail)
        }
        return result
    }

    /// Replace graph-build hints when `hints` is non-nil (e.g. curated JSON override).
    func withGraphBuildHints(_ hints: ResortGraphBuildHints?) -> ResortData {
        guard let hints else { return self }
        return ResortData(
            name: name,
            bounds: bounds,
            trails: trails,
            lifts: lifts,
            connections: connections,
            pois: pois,
            fetchDate: fetchDate,
            graphBuildHints: hints
        )
    }
}

// MARK: - BoundingBox Helpers

nonisolated extension BoundingBox {
    nonisolated func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        coord.latitude >= minLat && coord.latitude <= maxLat &&
        coord.longitude >= minLon && coord.longitude <= maxLon
    }
}

// MARK: - Haversine Helper

/// Great-circle distance in metres. This is the single canonical
/// implementation for the app — `MeetingPointSolver.haversineMeters`,
/// `BoundingBox.diagonalMeters`, and the `Coordinate` overload below all
/// route through it, so the formula (and its Earth radius) live in exactly
/// one place and can't drift.
nonisolated func haversine(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let R = 6_371_000.0 // Earth radius in meters
    let dLat = (b.latitude - a.latitude) * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180

    let x = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    let c = 2 * atan2(sqrt(x), sqrt(1 - x))
    return R * c
}

nonisolated func haversine(from a: Coordinate, to b: Coordinate) -> Double {
    haversine(
        from: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
        to: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
    )
}
