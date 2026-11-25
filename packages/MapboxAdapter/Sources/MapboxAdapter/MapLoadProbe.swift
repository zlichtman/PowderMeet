import Foundation
@preconcurrency import MapboxMaps
import PMLogging

/// Times one map's first load from Mapbox's own events: style, first terrain
/// tile, all tiles for the first view, and the first time the map goes idle.
/// It logs one line per milestone and a summary, and observes nothing after the
/// first idle.
@MainActor
final class MapLoadProbe {
    private let log: PMLog
    private let created = ContinuousClock.now
    private var subscriptions: Set<AnyCancelable> = []
    private var styleMS: Int?
    private var firstTerrainMS: Int?
    private var tilesLoadedMS: Int?
    private var sourceTiles: [String: Int] = [:]
    private var networkTiles = 0
    private var cachedTiles = 0
    private var networkBytes = 0
    /// Style, sprite, glyph, TileJSON and model bytes from the network: a style
    /// change moves cost here as much as into tiles.
    private var otherNetworkBytes = 0
    private var otherNetworkRequests = 0
    /// Network tile bytes per tileset, for telling imagery from DEM from vectors.
    private var tilesetBytes: [String: Int] = [:]
    private var finished = false

    /// Called once, at the first idle after the style loaded.
    var onFirstLoad: ((MapLoadTiming) -> Void)?
    /// The look the first view was drawn in, for comparing their costs.
    var look = MapAppearance.standard.look

    init(map: MapboxMap, log: PMLog) {
        self.log = log
        map.onSourceDataLoaded.observe { [weak self] event in
            let source = event.sourceId
            let isTile = event.type == .tile
            MainActor.assumeIsolated { self?.sourceLoaded(source, isTile: isTile) }
        }.store(in: &subscriptions)
        map.onResourceRequest.observe { [weak self] event in
            guard !event.cancelled, let response = event.response, response.error == nil else { return }
            let fromNetwork = event.source == .network
            let fromCache = event.source == .database
            let bytes = Int(clamping: response.size)
            guard event.request.resource == .tile else {
                guard fromNetwork else { return }
                MainActor.assumeIsolated { self?.otherFetched(bytes: bytes) }
                return
            }
            let tileset = Self.tileset(of: event.request.url)
            MainActor.assumeIsolated {
                self?.tileFetched(fromNetwork: fromNetwork, fromCache: fromCache, bytes: bytes, tileset: tileset)
            }
        }.store(in: &subscriptions)
        map.onMapLoaded.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.tilesLoaded() }
        }.store(in: &subscriptions)
    }

    private var elapsedMS: Int {
        let elapsed = ContinuousClock.now - created
        return Int(elapsed.components.seconds) * 1_000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func styleLoaded() {
        guard styleMS == nil else { return }
        styleMS = elapsedMS
        log.info(.map, "map load: style ready at \(elapsedMS) ms")
    }

    private func sourceLoaded(_ source: String, isTile: Bool) {
        guard !finished, isTile else { return }
        sourceTiles[source, default: 0] += 1
        if source == MapStyle.demSourceID, firstTerrainMS == nil {
            firstTerrainMS = elapsedMS
            log.info(.map, "map load: first terrain tile at \(elapsedMS) ms")
        }
    }

    private func tileFetched(fromNetwork: Bool, fromCache: Bool, bytes: Int, tileset: String) {
        guard !finished else { return }
        if fromNetwork {
            networkTiles += 1
            networkBytes += bytes
            tilesetBytes[tileset, default: 0] += bytes
        } else if fromCache {
            cachedTiles += 1
        }
    }

    private func otherFetched(bytes: Int) {
        guard !finished else { return }
        otherNetworkRequests += 1
        otherNetworkBytes += bytes
    }

    /// The tileset part of a tile URL (`mapbox.satellite`,
    /// `mapbox.mapbox-terrain-dem-v1`, a composite list), never the whole URL:
    /// that carries the access token.
    nonisolated static func tileset(of url: String) -> String {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let name = path.split(separator: "/").first { $0.contains("mapbox.") }
        return name.map { String($0.prefix(80)) } ?? "other"
    }

    private func tilesLoaded() {
        guard !finished, tilesLoadedMS == nil else { return }
        tilesLoadedMS = elapsedMS
        log.info(.map, "map load: first view's tiles loaded at \(elapsedMS) ms")
    }

    /// The map came to rest. The first rest after the style is the end of the load.
    func idle() {
        guard !finished, let styleMS else { return }
        finished = true
        subscriptions.removeAll()
        let timing = MapLoadTiming(
            styleMS: styleMS, firstTerrainMS: firstTerrainMS, tilesLoadedMS: tilesLoadedMS,
            idleMS: elapsedMS, networkTiles: networkTiles, cachedTiles: cachedTiles,
            networkBytes: networkBytes, otherNetworkBytes: otherNetworkBytes,
            otherNetworkRequests: otherNetworkRequests)
        let perSource = sourceTiles.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let perTileset = tilesetBytes.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value / 1_024)kB" }.joined(separator: " ")
        log.info(.map, "map load (\(look.rawValue)): \(timing.summary); tile events: \(perSource); network tile bytes: \(perTileset)")
        onFirstLoad?(timing)
    }
}
