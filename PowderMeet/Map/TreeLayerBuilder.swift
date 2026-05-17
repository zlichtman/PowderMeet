//
//  TreeLayerBuilder.swift
//  PowderMeet
//

import Foundation
import UIKit
import CoreLocation
import MapboxMaps

enum TreeLayerBuilder {

    static let sourceID = "trees-source"
    static let layerID = "trees-layer"
    static let plainImageID = "tree-plain"
    static let snowyImageID = "tree-snowy"

    private static let densityMetersPerTree: Double = 200
    private static let maxTrees = 10_000
    private static let hardCeiling = 12_000
    private static let pisteClearanceMeters: Double = 30
    private static let gridCellMeters: Double = 100
    private static let defaultTreeLineMeters: Double = 2400

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func makeTreeImage(snowy: Bool) -> UIImage {
        let size = CGSize(width: 32, height: 48)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: size))

            let trunkRect = CGRect(x: 13, y: 40, width: 6, height: 8)
            cg.setFillColor(UIColor(red: 0.24, green: 0.16, blue: 0.10, alpha: 1).cgColor)
            cg.fill(trunkRect)

            let canopy = UIBezierPath()
            canopy.move(to: CGPoint(x: 16, y: 2))
            canopy.addLine(to: CGPoint(x: 30, y: 41))
            canopy.addLine(to: CGPoint(x: 2, y: 41))
            canopy.close()
            cg.setFillColor(UIColor(red: 0.18, green: 0.32, blue: 0.20, alpha: 1).cgColor)
            cg.addPath(canopy.cgPath)
            cg.fillPath()

            if snowy {
                let cap = UIBezierPath()
                cap.move(to: CGPoint(x: 16, y: 2))
                cap.addLine(to: CGPoint(x: 25.3, y: 28))
                cap.addLine(to: CGPoint(x: 6.7, y: 28))
                cap.close()
                cg.setFillColor(UIColor(white: 1.0, alpha: 0.95).cgColor)
                cg.addPath(cap.cgPath)
                cg.fillPath()
            }
        }
    }

    static func registerImages(on map: MapboxMap) {
        let plain = makeTreeImage(snowy: false)
        let snowy = makeTreeImage(snowy: true)
        try? map.addImage(plain, id: plainImageID)
        try? map.addImage(snowy, id: snowyImageID)
    }

    static func installLayer(on map: MapboxMap) {
        registerImages(on: map)

        if !map.allSourceIdentifiers.contains(where: { $0.id == sourceID }) {
            var src = GeoJSONSource(id: sourceID)
            src.data = .featureCollection(FeatureCollection(features: []))
            try? map.addSource(src)
        }

        if !map.allLayerIdentifiers.contains(where: { $0.id == layerID }) {
            var trees = SymbolLayer(id: layerID, source: sourceID)
            trees.iconImage = .expression(
                Exp(.match) {
                    Exp(.get) { "snowy" }
                    true; snowyImageID
                    plainImageID
                }
            )
            trees.iconAnchor = .constant(.bottom)
            trees.iconPitchAlignment = .constant(.viewport)
            trees.iconSize = .expression(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.zoom)
                    13; 0.0
                    14; 0.4
                    16; 1.0
                }
            )
            trees.iconAllowOverlap = .constant(false)
            trees.minZoom = 13.5

            let position: LayerPosition
            if map.allLayerIdentifiers.contains(where: { $0.id == MountainMapView.LayerID.friendAccuracyHalo }) {
                position = .below(MountainMapView.LayerID.friendAccuracyHalo)
            } else if map.allLayerIdentifiers.contains(where: { $0.id == MountainMapView.LayerID.liftEndpoints }) {
                position = .above(MountainMapView.LayerID.liftEndpoints)
            } else {
                position = .default
            }
            try? map.addLayer(trees, layerPosition: position)
        }
    }

    static func populate(map: MapboxMap, entry: ResortEntry, graph: MountainGraph?, snowyHint: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fc = generateFeatureCollection(entry: entry, graph: graph, snowyHint: snowyHint)
            DispatchQueue.main.async {
                map.updateGeoJSONSource(withId: sourceID, geoJSON: .featureCollection(fc))
            }
        }
    }

    static func clear(map: MapboxMap) {
        map.updateGeoJSONSource(withId: sourceID, geoJSON: .featureCollection(FeatureCollection(features: [])))
    }

    static func generateFeatureCollection(entry: ResortEntry, graph: MountainGraph?, snowyHint: Bool) -> FeatureCollection {
        let bounds = entry.bounds
        let centerLat = (bounds.minLat + bounds.maxLat) / 2
        let latDegPerMeter = 1.0 / 111_000.0
        let lonDegPerMeter = 1.0 / (111_000 * max(cos(centerLat * .pi / 180), 0.0001))

        let widthMeters = (bounds.maxLon - bounds.minLon) / lonDegPerMeter
        let heightMeters = (bounds.maxLat - bounds.minLat) / latDegPerMeter
        let areaSqMeters = widthMeters * heightMeters
        var targetCount = Int(areaSqMeters / densityMetersPerTree)
        if targetCount > hardCeiling { targetCount = maxTrees }
        if targetCount > maxTrees { targetCount = maxTrees }
        if targetCount < 0 { targetCount = 0 }

        let pisteIndex = buildPisteGrid(graph: graph, bounds: bounds, latDegPerMeter: latDegPerMeter, lonDegPerMeter: lonDegPerMeter)

        var seed: UInt64 = 1469598103934665603
        for byte in entry.id.utf8 {
            seed = (seed ^ UInt64(byte)) &* 1099511628211
        }
        var rng = SeededGenerator(seed: seed)

        var features: [Feature] = []
        features.reserveCapacity(targetCount)

        let attempts = targetCount * 3
        var produced = 0
        for _ in 0..<attempts {
            if produced >= targetCount { break }
            let u = Double(rng.next() % 1_000_000) / 1_000_000.0
            let v = Double(rng.next() % 1_000_000) / 1_000_000.0
            let lon = bounds.minLon + u * (bounds.maxLon - bounds.minLon)
            let lat = bounds.minLat + v * (bounds.maxLat - bounds.minLat)
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

            // HACK: tree-line filter pending entry-elevation wiring (no per-point DEM available client-side; treeLineMeters reserved on ResortEntry, defaults to 2400m, applied once that DEM source lands).
            _ = entry.treeLineMeters ?? defaultTreeLineMeters

            if isWithinPisteClearance(coord: coord, grid: pisteIndex, latDegPerMeter: latDegPerMeter, lonDegPerMeter: lonDegPerMeter) {
                continue
            }

            let snowy: Bool = snowyHint || (rng.next() % 5 == 0)
            var feature = Feature(geometry: Point(coord))
            feature.properties = ["snowy": .boolean(snowy)]
            features.append(feature)
            produced += 1
        }

        return FeatureCollection(features: features)
    }

    private struct PisteGrid {
        let cellMeters: Double
        let originLat: Double
        let originLon: Double
        let latDegPerMeter: Double
        let lonDegPerMeter: Double
        var cells: [Int64: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]]
    }

    private static func buildPisteGrid(
        graph: MountainGraph?,
        bounds: BoundingBox,
        latDegPerMeter: Double,
        lonDegPerMeter: Double
    ) -> PisteGrid {
        var grid = PisteGrid(
            cellMeters: gridCellMeters,
            originLat: bounds.minLat,
            originLon: bounds.minLon,
            latDegPerMeter: latDegPerMeter,
            lonDegPerMeter: lonDegPerMeter,
            cells: [:]
        )
        guard let graph else { return grid }

        for edge in graph.edges where edge.kind == .run || edge.kind == .traverse {
            let pts = edge.geometry
            guard pts.count >= 2 else { continue }
            for i in 0..<(pts.count - 1) {
                let a = pts[i]
                let b = pts[i + 1]
                insertSegment(a: a, b: b, into: &grid)
            }
        }
        return grid
    }

    private static func insertSegment(
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D,
        into grid: inout PisteGrid
    ) {
        let cellLatSpan = grid.cellMeters * grid.latDegPerMeter
        let cellLonSpan = grid.cellMeters * grid.lonDegPerMeter

        let minLat = min(a.latitude, b.latitude)
        let maxLat = max(a.latitude, b.latitude)
        let minLon = min(a.longitude, b.longitude)
        let maxLon = max(a.longitude, b.longitude)

        let iMin = Int(floor((minLat - grid.originLat) / cellLatSpan))
        let iMax = Int(floor((maxLat - grid.originLat) / cellLatSpan))
        let jMin = Int(floor((minLon - grid.originLon) / cellLonSpan))
        let jMax = Int(floor((maxLon - grid.originLon) / cellLonSpan))

        for i in iMin...iMax {
            for j in jMin...jMax {
                let key = (Int64(i) << 32) | (Int64(j) & 0xFFFFFFFF)
                grid.cells[key, default: []].append((a, b))
            }
        }
    }

    private static func isWithinPisteClearance(
        coord: CLLocationCoordinate2D,
        grid: PisteGrid,
        latDegPerMeter: Double,
        lonDegPerMeter: Double
    ) -> Bool {
        let cellLatSpan = grid.cellMeters * grid.latDegPerMeter
        let cellLonSpan = grid.cellMeters * grid.lonDegPerMeter
        let i = Int(floor((coord.latitude - grid.originLat) / cellLatSpan))
        let j = Int(floor((coord.longitude - grid.originLon) / cellLonSpan))

        let clearanceSq = pisteClearanceMeters * pisteClearanceMeters

        for di in -1...1 {
            for dj in -1...1 {
                let key = (Int64(i + di) << 32) | (Int64(j + dj) & 0xFFFFFFFF)
                guard let segs = grid.cells[key] else { continue }
                for (a, b) in segs {
                    let dSq = pointToSegmentDistanceSqMeters(
                        coord: coord, a: a, b: b,
                        latDegPerMeter: latDegPerMeter,
                        lonDegPerMeter: lonDegPerMeter
                    )
                    if dSq < clearanceSq { return true }
                }
            }
        }
        return false
    }

    private static func pointToSegmentDistanceSqMeters(
        coord: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D,
        latDegPerMeter: Double,
        lonDegPerMeter: Double
    ) -> Double {
        let px = (coord.longitude - a.longitude) / lonDegPerMeter
        let py = (coord.latitude - a.latitude) / latDegPerMeter
        let bx = (b.longitude - a.longitude) / lonDegPerMeter
        let by = (b.latitude - a.latitude) / latDegPerMeter
        let segLenSq = bx * bx + by * by
        if segLenSq < 1e-6 {
            return px * px + py * py
        }
        var t = (px * bx + py * by) / segLenSq
        if t < 0 { t = 0 } else if t > 1 { t = 1 }
        let dx = px - t * bx
        let dy = py - t * by
        return dx * dx + dy * dy
    }
}
