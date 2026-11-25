import AppCore
import Foundation
import MapboxAdapter
import MountainCore
import PMLogging
import PowderMeetAPI

/// Settings → Maps: what is on the phone, and the work in flight.
nonisolated struct MapsSummary: Sendable, Hashable {
    /// Each resort with anything on disk: its trail map, its imagery or both.
    var stored: [String: StoredMap] = [:]
    /// The map style every resort's imagery draws with, stored once.
    var styleBytes: Int64 = 0
    /// Downloads under way, 0...1.
    var progress: [String: Double] = [:]
    /// The downloads the user started, and whether the map was already
    /// complete when they did (Update): stopping one of those keeps the map.
    var userJobs: [String: Bool] = [:]
    /// The last download or removal that failed, by resort.
    var failures: [String: PowderMeetError] = [:]
}

/// One resort's map on disk.
nonisolated struct StoredMap: Sendable, Hashable {
    var bundleID: BundleID?
    var bundleBytes: Int64 = 0
    var imageryBytes: Int64 = 0
    var imageryComplete = false

    var bytes: Int64 { bundleBytes + imageryBytes }
    /// The trail map and every imagery tile are on the phone.
    var isComplete: Bool { bundleID != nil && imageryComplete }
}

/// One resort as Settings → Maps lists it.
nonisolated struct MapRow: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var region: String?
    /// Downloaded or recent; nil for a resort not kept on the phone.
    var place: MapShelf.Place?
    /// What it takes on the phone now.
    var bytes: Int64
    /// About what it would take, before it is downloaded.
    var estimate: Int64?
    var isComplete: Bool
    /// A newer map is published and updates are left to the user.
    var updateWaiting: Bool
    var progress: Double?
    /// The user started the download under way, so it can be stopped.
    var isUserJob: Bool
    var failure: PowderMeetError?
}

extension AppModel {
    static let mapShelfKey = "maps.shelf"

    static func loadMapShelf() -> MapShelf {
        guard let data = UserDefaults.standard.data(forKey: mapShelfKey) else { return MapShelf() }
        do {
            return try JSONDecoder().decode(MapShelf.self, from: data)
        } catch {
            return MapShelf()
        }
    }

    func saveMapShelf() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(mapShelf), forKey: Self.mapShelfKey)
        } catch {
            deps.log.error(.resort, "could not save the maps list: \(error)")
        }
        keepDownloadedMaps()
    }

    /// The trail maps the user downloaded live out of the purgeable cache
    /// (`BundleStore.keep`); at launch this also moves maps downloaded before,
    /// with no new download. A few renames on one volume, so it runs here, in
    /// step with the shelf it follows and before a download saves into it.
    func keepDownloadedMaps() {
        deps.bundles.keep(mapShelf.downloaded)
    }

    // MARK: What the page shows

    /// Every resort with a published map, A to Z.
    var mapRows: [MapRow] {
        let look = ThemeManager.shared.mapLook
        return catalog.resorts.filter(\.hasMap).map { resort in
            let stored = maps.stored[resort.id]
            let place = mapShelf.place(of: resort.id, opened: recentResorts)
            return MapRow(
                id: resort.id, name: resort.name, region: resort.region, place: place,
                bytes: stored?.bytes ?? 0,
                estimate: resort.bbox.map { MapOfflineRegions.estimatedBytes(bounds: $0, look: look) },
                isComplete: stored?.isComplete ?? false,
                updateWaiting: place != nil && !mapShelf.updatesAutomatically
                    && stored?.bundleID != nil && stored?.bundleID != resort.bundleID,
                progress: maps.progress[resort.id], isUserJob: maps.userJobs[resort.id] != nil,
                failure: maps.failures[resort.id])
        }
    }

    /// The maps on the phone: downloaded or recent, with something stored.
    var mapsOnPhone: (count: Int, bytes: Int64) {
        let held = mapShelf.held(opened: recentResorts).filter { maps.stored[$0] != nil }
        guard !held.isEmpty else { return (0, 0) }
        let bytes = held.reduce(maps.styleBytes) { $0 + (maps.stored[$1]?.bytes ?? 0) }
        return (held.count, bytes)
    }

    /// "Update downloaded maps automatically".
    var mapsUpdateAutomatically: Bool {
        get { mapShelf.updatesAutomatically }
        set {
            mapShelf.updatesAutomatically = newValue
            saveMapShelf()
            if newValue { syncMaps() }
        }
    }

    // MARK: Intents

    /// Download: the trail map and the imagery, kept until removed.
    func downloadMap(_ id: String) {
        mapShelf.keep(id)
        saveMapShelf()
        startMapDownload(id)
    }

    /// Keep on a recent resort: it stays when it falls off the recent list.
    func keepMap(_ id: String) {
        mapShelf.keep(id)
        saveMapShelf()
        if maps.stored[id]?.isComplete != true { startMapDownload(id) }
    }

    /// Update, when updates are left to the user.
    func updateMap(_ id: String) {
        startMapDownload(id)
    }

    /// Stop on a download the user started. A map that was already complete
    /// (an update) stays as it was; anything else goes, as it never finished.
    func stopMapDownload(_ id: String) {
        guard let wasComplete = maps.userJobs[id] else { return }
        if wasComplete {
            endMapJob(id)
            refreshMaps()
        } else {
            removeMap(id)
        }
    }

    /// Remove: everything stored for the resort is deleted.
    func removeMap(_ id: String) {
        endMapJob(id)
        if mapSyncResortID == id { work["maps-sync"]?.cancel() }
        mapShelf.remove(id)
        saveMapShelf()
        maps.failures[id] = nil
        run("map-remove-\(id)") { [weak self] in
            guard let self else { return }
            do {
                try await deleteMap(id)
            } catch {
                maps.failures[id] = .data(.mapNotRemoved(resortID: id))
            }
            await refreshMapStorage()
        }
    }

    /// Settings opened: read what is on disk.
    func refreshMaps() {
        run("maps-storage") { [weak self] in await self?.refreshMapStorage() }
    }

    /// Settings → Maps → Check for updates: asks the catalog again, which
    /// brings the maps on the phone up to date.
    func checkMapUpdates() {
        guard !catalog.isLoading else { return }
        loadCatalog()
    }

    /// A deleted account: the recent resorts and the maps kept on the phone
    /// show where the person skied, so none of it stays (a sign-out keeps
    /// them). Work in flight stops first, or a download finishing would save
    /// the shelf again. A map that cannot be deleted now is no longer held,
    /// so the next map pass clears it.
    func forgetMapsAndRecentResorts() {
        for id in Array(mapJobs.keys) { endMapJob(id) }
        work["maps-sync"]?.cancel()
        mapSyncResortID = nil
        recentResorts = []
        UserDefaults.standard.removeObject(forKey: recentResortsKey)
        mapShelf = MapShelf()
        UserDefaults.standard.removeObject(forKey: Self.mapShelfKey)
        // Marks nothing as kept, which moves the kept maps back out of their folder.
        keepDownloadedMaps()
        imageryChecked = []
        maps = MapsSummary()
        let bundles = deps.bundles, offlineMaps = offlineMaps, log = deps.log
        run("maps-forget") { [weak self] in
            let onDisk = await Task.detached { bundles.storedResortIDs() }.value
            let regions = await offlineMaps?.stored() ?? [:]
            for id in onDisk.union(regions.keys) {
                do {
                    try await offlineMaps?.remove(resortID: id)
                    try await Task.detached { try bundles.remove(resortID: id) }.value
                } catch {
                    log.error(.resort, "a deleted account's map of \(id) is still on the phone: \(error)")
                    self?.maps.failures[id] = .data(.mapNotRemoved(resortID: id))
                }
            }
            await self?.refreshMapStorage()
        }
    }

    // MARK: Work

    private func endMapJob(_ id: String) {
        mapJobs[id]?.cancel()
        mapJobs[id] = nil
        maps.userJobs[id] = nil
        maps.progress[id] = nil
    }

    private func startMapDownload(_ id: String) {
        guard let resort = catalog.resorts.first(where: { $0.id == id }), resort.hasMap else { return }
        let wasComplete = maps.userJobs[id] ?? (maps.stored[id]?.isComplete == true)
        endMapJob(id)
        maps.failures[id] = nil
        guard OfflineMapPolicy.mayStart(connection: connection) else {
            maps.failures[id] = .network(.offline)
            return
        }
        maps.progress[id] = 0
        maps.userJobs[id] = wasComplete
        let background = deps.background
        mapJobs[id] = Task {
            await background.hold("map-download") { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await fetchMap(resort, allowMetered: true, takeNewer: true)
                } catch {
                    // A stop or a removal cleans up after itself.
                    if Task.isCancelled || error is CancellationError { return }
                    maps.failures[id] = mapFailure(error, resortID: id)
                }
                guard !Task.isCancelled else { return }
                maps.progress[id] = nil
                maps.userJobs[id] = nil
                mapJobs[id] = nil
                await refreshMapStorage()
            }
        }
    }

    /// Fetches a resort's trail map when the phone has none (or `takeNewer`
    /// and a newer one is published), then its imagery. Decoding and
    /// verifying the map run off the main actor.
    private func fetchMap(_ resort: PublishedResort, allowMetered: Bool, takeNewer: Bool) async throws {
        guard let offlineMaps else { return }
        let id = resort.id, bundles = deps.bundles, backend = deps.backend
        let storedID = await Task.detached { bundles.activeBundleID(resortID: id) }.value
        var bounds = resort.bbox
        if let published = resort.bundleID, storedID == nil || (takeNewer && storedID != published) {
            let data = try await backend.bundleData(resortID: id, bundleID: published)
            bounds = try await Task.detached {
                let bundle: ResortBundle
                do {
                    bundle = try BundleLoader.load(data: data, expectedID: published)
                } catch {
                    throw PowderMeetError.data(.bundleCorrupt(published))
                }
                bundles.save(data, as: published, activeFor: id)
                return bundle.bbox
            }.value
        } else if bounds == nil, let storedID {
            bounds = await Task.detached { bundles.bundle(storedID)?.bbox }.value
        }
        guard let bounds else { throw PowderMeetError.data(.bundleUnavailable(resortID: id)) }
        try Task.checkCancellation()
        maps.progress[id] = 0.05
        let look = ThemeManager.shared.mapLook
        try await offlineMaps.download(
            resortID: id, bounds: bounds, look: look, allowMetered: allowMetered
        ) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, maps.progress[id] != nil else { return }
                maps.progress[id] = 0.05 + 0.95 * fraction
            }
        }
        mapShelf.imageryLooks[id] = look.rawValue
        saveMapShelf()
        imageryChecked.insert(id)
    }

    private func deleteMap(_ id: String) async throws {
        let bundles = deps.bundles
        try await offlineMaps?.remove(resortID: id)
        try await Task.detached { try bundles.remove(resortID: id) }.value
        mapShelf.imageryLooks[id] = nil
        saveMapShelf()
        imageryChecked.remove(id)
    }

    private func mapFailure(_ error: any Error, resortID: String) -> PowderMeetError {
        switch error {
        case MapOfflineRegions.Failure.phoneFull:
            return .data(.phoneFull)
        case is MapOfflineRegions.Failure:
            return connection == .offline ? .network(.offline) : .data(.mapNotDownloaded(resortID: resortID))
        default:
            return PowderMeetError(error)
        }
    }

    /// Reads what each resort has on disk, off the main actor.
    func refreshMapStorage() async {
        let bundles = deps.bundles
        let files = await Task.detached {
            bundles.storedResortIDs().map { id in
                (id, bundles.activeBundleID(resortID: id), bundles.storedBytes(resortID: id))
            }
        }.value
        let imagery = await offlineMaps?.stored() ?? [:]
        let style = await offlineMaps?.styleBytes() ?? 0
        var stored: [String: StoredMap] = [:]
        for (id, bundleID, bytes) in files {
            stored[id] = StoredMap(bundleID: bundleID, bundleBytes: bytes)
        }
        for (id, region) in imagery {
            stored[id, default: StoredMap()].imageryBytes = region.bytes
            stored[id, default: StoredMap()].imageryComplete = region.isComplete
        }
        maps.stored = stored
        maps.styleBytes = style
    }

    /// The work nobody asked for: clears what is no longer kept, then, when
    /// `OfflineMapPolicy` allows it, caches the recent resorts and brings
    /// every kept map up to date. Runs when the catalog answers, the
    /// network or the look changes, the open map settles and the app comes
    /// and goes, inside the app's background grace so it can finish after the
    /// phone is locked.
    func syncMaps() {
        guard offlineMaps != nil, !catalog.resorts.isEmpty else { return }
        let background = deps.background
        run("maps-sync") {
            await background.hold("maps-sync") { @MainActor [weak self] in
                await self?.runMapSync()
            }
        }
    }

    private func runMapSync() async {
        await refreshMapStorage()
        // Clearing empties the map's tile cache, which blocks the tile store:
        // never under the open map's first view.
        let mapLoading = resort.map { settledResortID != $0.resortID } ?? false
        guard !mapLoading else { return }
        let held = mapShelf.held(opened: recentResorts)
        for id in Set(maps.stored.keys).subtracting(held) where mapJobs[id] == nil {
            guard !Task.isCancelled else { return }
            do {
                try await deleteMap(id)
                deps.log.info(.resort, "cleared the cached map of \(id)")
            } catch {
                deps.log.error(.resort, "could not clear the cached map of \(id): \(error)")
            }
        }
        guard OfflineMapPolicy.mayRunUnattended(
            connection: connection, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            mapLoading: mapLoading)
        else {
            await refreshMapStorage()
            return
        }
        let look = ThemeManager.shared.mapLook.rawValue
        let automatic = mapShelf.updatesAutomatically
        // The open resort first, then the other recent ones, then the rest.
        let order = mapShelf.recent(recentResorts) + mapShelf.downloaded.sorted()
        for id in order where mapJobs[id] == nil {
            guard !Task.isCancelled else { break }
            guard let resort = catalog.resorts.first(where: { $0.id == id }), resort.hasMap else { continue }
            let stored = maps.stored[id]
            let unfinished = stored?.isComplete != true || mapShelf.imageryLooks[id] != look
            let outdated = stored?.bundleID != resort.bundleID || !imageryChecked.contains(id)
            guard unfinished || (automatic && outdated) else { continue }
            mapSyncResortID = id
            maps.progress[id] = 0
            do {
                try await fetchMap(resort, allowMetered: false, takeNewer: automatic)
            } catch {
                deps.log.notice(.resort, "map of \(id) not brought up to date: \(error)")
            }
            // A download the user started on this resort meanwhile owns its row.
            if maps.userJobs[id] == nil { maps.progress[id] = nil }
            mapSyncResortID = nil
        }
        await refreshMapStorage()
    }
}
