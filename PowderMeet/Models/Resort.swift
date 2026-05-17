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

    nonisolated init(lat: Double, lon: Double, ele: Double? = nil) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
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
        let dLat = (maxLat - minLat) * .pi / 180
        let dLon = (maxLon - minLon) * .pi / 180
        let lat1 = minLat * .pi / 180
        let lat2 = maxLat * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
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

// MARK: - Lift

struct Lift: Codable, Identifiable {
    let id: Int64
    let name: String?
    let type: LiftType
    let coordinates: [Coordinate]
    let capacity: Int?
    let occupancy: Int?
    var isOpen: Bool

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
    let pois: [PointOfInterest]
    let fetchDate: Date
    /// Optional tuning for `GraphBuilder.assignTrailGroups`; omitted in Overpass JSON.
    let graphBuildHints: ResortGraphBuildHints?

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

nonisolated func haversine(from a: Coordinate, to b: Coordinate) -> Double {
    let R = 6371000.0 // Earth radius in meters
    let dLat = (b.lat - a.lat) * .pi / 180
    let dLon = (b.lon - a.lon) * .pi / 180
    let lat1 = a.lat * .pi / 180
    let lat2 = b.lat * .pi / 180

    let x = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    let c = 2 * atan2(sqrt(x), sqrt(1 - x))
    return R * c
}
