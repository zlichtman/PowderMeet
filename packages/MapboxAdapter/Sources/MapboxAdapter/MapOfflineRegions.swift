import CoreLocation
import Foundation
@preconcurrency import MapboxMaps
import MountainCore
import PMLogging
import Synchronization
import UIKit

/// The map imagery for resorts kept on the phone, so they draw with no signal:
/// the satellite-streets style pack (the style, its sprite and the label
/// glyphs) plus one tile region per resort over its bounding box, holding what
/// the chosen look draws: the terrain DEM (3D terrain and relief) and
/// mapbox-terrain-v2 (contours and tree cover) for every look, and the photo
/// and streets only for Satellite. Which resorts are kept, and when a download
/// may run, is the app's decision (`MapShelf`, `OfflineMapPolicy`); this type
/// only runs it.
@MainActor
public final class MapOfflineRegions {
    public nonisolated static let regionPrefix = "powdermeet-"
    nonisolated static let zoomRange: ClosedRange<UInt8> = 10...16

    /// What one resort's region holds on disk.
    public struct Stored: Sendable, Hashable {
        public var bytes: Int64
        /// Every tile the region asked for is on disk.
        public var isComplete: Bool
    }

    /// Why a download stopped, for the app to put in plain words.
    public enum Failure: Error, Sendable, Hashable {
        case phoneFull
        case failed(String)
    }

    private let log: PMLog
    private let offline = OfflineManager()
    private let store = TileStore.default

    public init(log: PMLog = PMLog()) {
        self.log = log
    }

    /// Downloads a resort's imagery, or brings what is stored up to date (the
    /// SDK fetches only missing and expired tiles), and returns once it is all
    /// on disk. Cancelling the task stops it. Without `allowMetered` the SDK
    /// itself refuses to fetch over cellular, so work that began on Wi-Fi does
    /// not carry on over the phone's data plan.
    ///
    /// A new `look` changes what is held: a region saved for a drawn look has
    /// no photo, and one saved for Satellite would carry it for nothing.
    /// Loading the same region with the new descriptors keeps the tiles both
    /// share.
    public func download(
        resortID: String, bounds: MountainCore.BoundingBox, look: MapLook, allowMetered: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        log.info(.map, "map imagery requested: \(resortID) (\(look.rawValue))\(allowMetered ? " (any network)" : "")")
        let style = MapStyle.styleURI
        guard let packOptions = StylePackLoadOptions(
            glyphsRasterizationMode: .ideographsRasterizedLocally, metadata: ["resortId": resortID],
            acceptExpired: true)
        else { throw Failure.failed("style pack options rejected") }
        let descriptor = offline.createTilesetDescriptor(
            for: Self.descriptorOptions(style: style, photo: look.usesSatellite))
        guard let regionOptions = TileRegionLoadOptions(
            geometry: .polygon(Self.polygon(bounds)), descriptors: [descriptor],
            metadata: ["resortId": resortID], acceptExpired: true,
            networkRestriction: allowMetered ? .none : .disallowExpensive, averageBytesPerSecond: nil)
        else { throw Failure.failed("region options rejected") }

        do {
            try await Self.awaitLoad { done in
                self.offline.loadStylePack(for: style, loadOptions: packOptions) { @Sendable result in
                    done(result.map { _ in () })
                }
            }
            let reported = Mutex(-1)
            try await Self.awaitLoad { done in
                self.store.loadTileRegion(
                    forId: Self.regionPrefix + resortID, loadOptions: regionOptions,
                    progress: { @Sendable step in
                        guard step.requiredResourceCount > 0 else { return }
                        let percent = Int(step.completedResourceCount * 100 / step.requiredResourceCount)
                        // Called once per tile: tell the app only when the whole percent moves.
                        let isNew = reported.withLock { last in
                            guard percent != last else { return false }
                            last = percent
                            return true
                        }
                        if isNew { progress(Double(percent) / 100) }
                    },
                    completion: { @Sendable result in done(result.map { _ in () }) })
            }
            log.info(.map, "map imagery ready: \(resortID)")
        } catch {
            throw Self.failure(error, resortID: resortID, log: log)
        }
    }

    /// Every resort's region on disk, by resort id, with its size. Empty when
    /// the store cannot be listed: this is what the shelf shows.
    public func stored() async -> [String: Stored] {
        do {
            return try await listing()
        } catch {
            log.error(.map, "map imagery listing failed: \(error.localizedDescription)")
            return [:]
        }
    }

    /// The regions on disk, or the store's error: deciding what to delete
    /// must not mistake a failed listing for an empty one.
    private func listing() async throws -> [String: Stored] {
        try await withCheckedThrowingContinuation { continuation in
            store.allTileRegions { @Sendable result in
                switch result {
                case .success(let regions):
                    var stored: [String: Stored] = [:]
                    for region in regions where region.id.hasPrefix(Self.regionPrefix) {
                        stored[String(region.id.dropFirst(Self.regionPrefix.count))] = Stored(
                            bytes: Int64(clamping: region.completedResourceSize),
                            isComplete: region.requiredResourceCount > 0
                                && region.completedResourceCount >= region.requiredResourceCount)
                    }
                    continuation.resume(returning: stored)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The style pack every region draws with.
    public func styleBytes() async -> Int64 {
        await withCheckedContinuation { continuation in
            offline.stylePack(for: MapStyle.styleURI) { @Sendable result in
                if case .success(let pack) = result {
                    continuation.resume(returning: Int64(clamping: pack.completedResourceSize))
                } else {
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Deletes a resort's region, and the style pack with the last one. A
    /// removed region's tiles only move to the SDK's ambient cache, so that
    /// is emptied too: the space is freed now, not someday. The map on screen
    /// streams what it needs again.
    public func remove(resortID: String) async throws {
        // A resort with only a trail map (one opened for an import) has
        // nothing here, and clearing the cache would cost the open map.
        let before: [String: Stored]
        do { before = try await listing() } catch { throw Self.failure(error, resortID: resortID, log: log) }
        guard before[resortID] != nil else { return }
        let id = Self.regionPrefix + resortID
        do {
            try await Self.awaitLoad { done in
                self.store.removeRegion(forId: id) { @Sendable result in
                    if case .failure(let error) = result, case .doesNotExist = error as? TileRegionError {
                        done(.success(()))
                    } else {
                        done(result.map { _ in () })
                    }
                }
                return nil
            }
        } catch {
            throw Self.failure(error, resortID: resortID, log: log)
        }
        // Only a listing that worked and is empty frees the shared style pack;
        // the region itself is gone either way.
        do {
            if try await listing().isEmpty { offline.removeStylePack(for: MapStyle.styleURI) }
        } catch {
            log.error(.map, "map imagery listing failed, style pack kept: \(error.localizedDescription)")
        }
        let log = log
        store.clearAmbientCache { @Sendable result in
            if case .failure(let error) = result {
                log.error(.map, "map cache clear failed: \(error.localizedDescription)")
            }
        }
        log.info(.map, "map imagery removed: \(resortID)")
    }

    /// About how much a resort's imagery takes once downloaded, from the tiles
    /// its box covers: the size shown before a download, when the SDK would
    /// need the network and seconds per resort to say.
    public nonisolated static func estimatedBytes(bounds: MountainCore.BoundingBox, look: MapLook) -> Int64 {
        let box = padded(bounds)
        var tiles = 0
        for zoom in zoomRange {
            let n = Double(1 << Int(zoom))
            func column(_ lon: Double) -> Int { Int(((lon + 180) / 360 * n).rounded(.down)) }
            func row(_ lat: Double) -> Int {
                let radians = lat * .pi / 180
                return Int(((1 - Foundation.log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * n).rounded(.down))
            }
            tiles += (column(box.e) - column(box.w) + 1) * (row(box.s) - row(box.n) + 1)
        }
        return look.usesSatellite
            ? baseBytesWithPhoto + Int64(tiles) * bytesPerTileWithPhoto
            : baseBytesDrawn + Int64(tiles) * bytesPerTileDrawn
    }

    /// Fitted to downloaded resorts (Snow Valley, June Mountain, Palisades
    /// Tahoe, Whistler Blackcomb, 21 Nov 2026). The SDK fetches whole tile
    /// packs, so even a small resort costs a fixed share of the low zooms
    /// before each tile of its own box adds to it.
    nonisolated static let baseBytesDrawn: Int64 = 28_000_000
    nonisolated static let bytesPerTileDrawn: Int64 = 54_000
    nonisolated static let baseBytesWithPhoto: Int64 = 39_000_000
    nonisolated static let bytesPerTileWithPhoto: Int64 = 184_000

    // MARK: Plumbing

    /// One SDK load as an async call that a task's cancellation stops.
    private static func awaitLoad(
        _ start: @escaping (@escaping @Sendable (Result<Void, any Error>) -> Void) -> (any Cancelable)?
    ) async throws {
        let handle = CancelHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                handle.hold(start { result in continuation.resume(with: result) })
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func failure(_ error: any Error, resortID: String, log: PMLog) -> any Error {
        if error is CancellationError { return error }
        switch error as? TileRegionError {
        case .canceled: return CancellationError()
        case .diskFull:
            log.error(.map, "map imagery for \(resortID): phone full")
            return Failure.phoneFull
        default: break
        }
        if case .canceled = error as? StylePackError { return CancellationError() }
        if case .diskFull = error as? StylePackError { return Failure.phoneFull }
        log.error(.map, "map imagery failed for \(resortID): \(error.localizedDescription)")
        return Failure.failed(error.localizedDescription)
    }

    /// The tiles a look draws. Satellite takes the style's own tilesets (the
    /// photo and streets) and the DEM, as before; a drawn look names only its
    /// two tilesets against an empty style, which the SDK allows, so no photo
    /// or street tile is fetched for it.
    private static func descriptorOptions(style: StyleURI, photo: Bool) -> TilesetDescriptorOptions {
        let terrain = [MapStyle.demTileset, MapStyle.terrainTileset]
        if photo {
            return TilesetDescriptorOptions(styleURI: style, zoomRange: zoomRange, tilesets: [MapStyle.demTileset])
        }
        return TilesetDescriptorOptions(
            styleURI: "", minZoom: zoomRange.lowerBound, maxZoom: zoomRange.upperBound,
            pixelRatio: Float(max(1, UITraitCollection.current.displayScale)), tilesets: terrain, stylePack: nil, extraOptions: nil)
    }

    /// The resort box with about 500 m of margin.
    private nonisolated static func padded(_ b: MountainCore.BoundingBox) -> (s: Double, n: Double, w: Double, e: Double) {
        let pad = 0.005
        return (b.minLat - pad, b.maxLat + pad, b.minLon - pad, b.maxLon + pad)
    }

    /// The padded box as a closed ring.
    private static func polygon(_ b: MountainCore.BoundingBox) -> Polygon {
        let box = padded(b)
        return Polygon([[
            CLLocationCoordinate2D(latitude: box.s, longitude: box.w),
            CLLocationCoordinate2D(latitude: box.s, longitude: box.e),
            CLLocationCoordinate2D(latitude: box.n, longitude: box.e),
            CLLocationCoordinate2D(latitude: box.n, longitude: box.w),
            CLLocationCoordinate2D(latitude: box.s, longitude: box.w),
        ]])
    }
}

/// The SDK's handle on one load, cancelled from whichever thread the task's
/// cancellation runs on; a cancel that comes first stops the load as it starts.
// `@unchecked`: `Cancelable` is the SDK's thread-safe handle but not marked
// Sendable, so a `Mutex` cannot take it; the lock guards both fields.
private final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var load: (any Cancelable)?
    private var cancelled = false

    func hold(_ load: (any Cancelable)?) {
        lock.lock()
        self.load = load
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { load?.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let load = load
        lock.unlock()
        load?.cancel()
    }
}
