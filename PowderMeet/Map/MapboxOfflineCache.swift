//
//  MapboxOfflineCache.swift
//  PowderMeet
//
//  Pre-warms Mapbox satellite-streets tiles for the active resort so
//  panning around the mountain on a chairlift with marginal LTE doesn't
//  stream-in tiles ("sky loads when you move around"). Wraps the SDK's
//  TileStore + OfflineManager v11 API in one fire-and-forget entrypoint.
//
//  Strategy:
//    - Per resort, request a TileRegion covering the resort bbox at
//      zoom 10–16. Zoom 10 is "I see the whole valley"; zoom 16 is
//      "I see individual lift towers." Most ski use sits at 13–15.
//    - Request a StylePack so the satellite-streets style metadata,
//      sprites, and fonts are downloaded once. Without this, even
//      cached tiles render with a "loading" overlay until the style
//      assets stream in.
//    - Mapbox dedups internally — calling load* with a region id that
//      already exists is a no-op once the download completes. We
//      additionally short-circuit in-memory so a session that switches
//      between resorts doesn't requeue the same fetch every time.
//    - Failures are silent: the resort still works, satellite tiles
//      just stream the old way. Cache pre-warming is opportunistic.
//
//  All work happens off the main thread; the entrypoint returns
//  immediately. No UI gating — the user sees a degraded-but-working
//  map while the background fetch fills in.
//

import Foundation
import MapboxMaps
import CoreLocation

@MainActor
final class MapboxOfflineCache {
    static let shared = MapboxOfflineCache()

    /// Resorts we've already kicked off prefetches for this session.
    /// On disk, Mapbox itself dedups; this just avoids re-issuing the
    /// load command on every onChange of `selectedEntry` for the same
    /// resort within a session.
    private var queuedResortIds: Set<String> = []

    /// Stable style URI for the satellite-streets style PowderMeet uses.
    /// MUST match `MountainMapView.makeUIView`'s styleURI or the
    /// pre-cached style won't satisfy the live map's tile requests.
    private let styleURI: StyleURI = StyleURI(rawValue: "mapbox://styles/mapbox/satellite-streets-v12") ?? .satelliteStreets

    private init() {}

    /// Kick off a background prefetch for `resort`. Idempotent within
    /// a process lifetime. Safe to call from any actor — bounces to
    /// main internally for SDK access.
    func prewarm(resort: ResortEntry) {
        guard !queuedResortIds.contains(resort.id) else { return }
        queuedResortIds.insert(resort.id)

        let bounds = resort.bounds
        let resortId = resort.id
        let styleURI = self.styleURI

        // Build geometry on the calling actor (it's pure value-type
        // construction); SDK calls go to the offline manager / tile
        // store which manage their own queues.
        let polygon = Self.makePolygon(
            minLat: bounds.minLat, maxLat: bounds.maxLat,
            minLon: bounds.minLon, maxLon: bounds.maxLon
        )

        // Build the descriptor, then request the style pack and the
        // tile region. Both calls are completion-handler-based in the
        // v11 SDK — the SDK runs them on its own dispatch queue, so
        // we don't bridge into async/await here. We only log results.
        let offlineManager = OfflineManager()
        guard let tilesetOptions = TilesetDescriptorOptions(
            styleURI: styleURI,
            zoomRange: 10...16,
            tilesets: nil
        ) as TilesetDescriptorOptions? else { return }
        let descriptor = offlineManager.createTilesetDescriptor(for: tilesetOptions)

        guard let stylePackOptions = StylePackLoadOptions(
            glyphsRasterizationMode: .ideographsRasterizedLocally,
            metadata: ["resortId": resortId],
            acceptExpired: true
        ) else { return }
        offlineManager.loadStylePack(
            for: styleURI,
            loadOptions: stylePackOptions
        ) { result in
            switch result {
            case .success:
                print("[OfflineCache] resort=\(resortId) stylePack ready")
            case .failure(let err):
                print("[OfflineCache] resort=\(resortId) stylePack failed: \(err.localizedDescription)")
            }
        }

        guard let regionOptions = TileRegionLoadOptions(
            geometry: .polygon(polygon),
            descriptors: [descriptor],
            metadata: ["resortId": resortId],
            acceptExpired: true,
            networkRestriction: .none,
            averageBytesPerSecond: nil
        ) else { return }
        TileStore.default.loadTileRegion(
            forId: "powdermeet-\(resortId)",
            loadOptions: regionOptions
        ) { result in
            switch result {
            case .success:
                print("[OfflineCache] resort=\(resortId) tile region ready")
            case .failure(let err):
                print("[OfflineCache] resort=\(resortId) tile region failed: \(err.localizedDescription)")
            }
        }
    }

    /// Min/max lat-lon → closed-ring Polygon. Mapbox expects the outer
    /// ring as `[Coordinate]` with the first point repeated at the end.
    private static func makePolygon(
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    ) -> Polygon {
        // Add a small buffer (~500 m at typical resort latitudes) so
        // tiles just outside the catalog bbox are also cached — users
        // routinely pan slightly past the resort boundary on the map.
        let bufferDeg = 0.005  // ≈ 555 m latitude / 350-450 m longitude
        let s = minLat - bufferDeg
        let n = maxLat + bufferDeg
        let w = minLon - bufferDeg
        let e = maxLon + bufferDeg
        let ring: [LocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: s, longitude: w),
            CLLocationCoordinate2D(latitude: s, longitude: e),
            CLLocationCoordinate2D(latitude: n, longitude: e),
            CLLocationCoordinate2D(latitude: n, longitude: w),
            // Close the ring.
            CLLocationCoordinate2D(latitude: s, longitude: w),
        ]
        return Polygon([ring])
    }
}
