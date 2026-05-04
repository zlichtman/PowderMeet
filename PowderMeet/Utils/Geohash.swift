//
//  Geohash.swift
//  PowderMeet
//
//  Pure-Swift geohash encode + neighbor lookup. Used to partition live position
//  traffic into ~1.2km tiles within a resort so a single channel doesn't fan
//  out to every user on the mountain. Friends on the same lift typically end
//  up in the same cell or one of the 8 surrounding neighbors, so the receiver
//  subscribes to its own cell + 8 neighbors and discards anyone else's traffic.
//
//  Precision: caller picks length. We use 6 (~1.2×0.6km at 47° latitude) for
//  live channel partitioning, 5 (~5×5km) only as a coarse "what region" signal.
//

import Foundation
import CoreLocation

enum Geohash {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
    private static let decodeMap: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (i, c) in base32.enumerated() { map[c] = i }
        return map
    }()

    /// Encode lat/lon to a geohash of `precision` characters.
    static func encode(latitude: Double, longitude: Double, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bits = 0
        var bit = 0
        var ch = 0
        var even = true

        while hash.count < precision {
            if even {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    ch |= (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    ch |= (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }
            even.toggle()
            if bit < 4 {
                bit += 1
            } else {
                hash.append(base32[ch])
                bits += 5
                bit = 0
                ch = 0
            }
        }
        return hash
    }

    static func encode(coordinate: CLLocationCoordinate2D, precision: Int) -> String {
        encode(latitude: coordinate.latitude, longitude: coordinate.longitude, precision: precision)
    }

    /// Decode to bounding box (sw, ne).
    static func decodeBounds(_ hash: String) -> (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D)? {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var even = true
        for c in hash {
            guard let idx = decodeMap[c] else { return nil }
            for i in 0..<5 {
                let bit = (idx >> (4 - i)) & 1
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
        return (
            CLLocationCoordinate2D(latitude: latRange.0, longitude: lonRange.0),
            CLLocationCoordinate2D(latitude: latRange.1, longitude: lonRange.1)
        )
    }

    /// Return the 8 surrounding cells at the same precision. If the input is
    /// at a pole edge, missing neighbors are simply omitted (no wraparound).
    static func neighbors(_ hash: String) -> [String] {
        guard let bounds = decodeBounds(hash) else { return [] }
        let centerLat = (bounds.sw.latitude + bounds.ne.latitude) / 2
        let centerLon = (bounds.sw.longitude + bounds.ne.longitude) / 2
        let dLat = bounds.ne.latitude - bounds.sw.latitude
        let dLon = bounds.ne.longitude - bounds.sw.longitude
        let p = hash.count
        var out: [String] = []
        for dy in [-1, 0, 1] {
            for dx in [-1, 0, 1] where !(dy == 0 && dx == 0) {
                let lat = centerLat + Double(dy) * dLat
                let lon = centerLon + Double(dx) * dLon
                guard lat >= -90, lat <= 90 else { continue }
                let wrappedLon = ((lon + 540).truncatingRemainder(dividingBy: 360)) - 180
                out.append(encode(latitude: lat, longitude: wrappedLon, precision: p))
            }
        }
        return out
    }

    /// Cell + its 8 neighbors. Convenience for "what should I subscribe to."
    static func cellAndNeighbors(_ hash: String) -> [String] {
        [hash] + neighbors(hash)
    }
}
