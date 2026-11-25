import Foundation
import MountainCore
import PMLogging
import PowderMeetAPI

/// The on-disk cache that keeps the map available offline: stored bundle bytes by
/// `bundle_id`, each resort's last known active bundle, and the last status and
/// conditions rows. Bundle bytes are verified against their id on every load
/// (I-17); a file that fails is deleted, never trusted.
///
/// `directory` is a cache iOS may purge. The trail maps of the resorts the user
/// downloaded (`keep`) live in `keptDirectory` instead, so their imagery is
/// never left without its map; status, conditions, the catalog and every other
/// map stay in the cache. Reads look in both, so a move cut short loses nothing.
public struct BundleStore: Sendable {
    public let directory: URL
    /// Application Support, out of the iCloud backup; nil keeps everything in
    /// `directory`.
    public let keptDirectory: URL?
    private let log: PMLog

    public init(directory: URL, keptDirectory: URL? = nil, log: PMLog = PMLog()) {
        self.directory = directory
        self.keptDirectory = keptDirectory
        self.log = log
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func keptURL(_ name: String) -> URL? { keptDirectory?.appendingPathComponent(name) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Where the file is: kept, else the cache, else nowhere.
    private func location(_ name: String) -> URL? {
        if let kept = keptURL(name), exists(kept) { return kept }
        return exists(url(name)) ? url(name) : nil
    }

    private func isKept(_ resortID: String) -> Bool {
        keptURL("\(resortID).kept").map(exists) ?? false
    }

    /// Writes through a temporary file renamed over the old one (`.atomic`), so a
    /// failed write leaves the earlier copy whole. False when nothing was written.
    @discardableResult
    private func write(_ data: Data, to name: String, kept: Bool = false) -> Bool {
        let target = kept ? keptURL(name) ?? url(name) : url(name)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            log.error(.resort, "cache write of \(name) failed: \(error)")
            return false
        }
        // One copy only, so the one read is the one just written.
        for other in [url(name), keptURL(name)].compactMap({ $0 }) where other != target && exists(other) {
            do {
                try FileManager.default.removeItem(at: other)
            } catch {
                log.error(.resort, "could not delete the old copy of \(name): \(error)")
            }
        }
        return true
    }

    private func read(_ name: String) -> Data? {
        guard let location = location(name) else { return nil }
        do {
            return try Data(contentsOf: location)
        } catch {
            log.error(.resort, "cache read of \(name) failed: \(error)")
            return nil
        }
    }

    /// The cached bundle, verified and decoded, or nil when absent or damaged.
    public func bundle(_ id: BundleID) -> ResortBundle? {
        let name = "\(id.rawValue).json.gz"
        guard let data = read(name) else { return nil }
        do {
            return try BundleLoader.load(data: data, expectedID: id)
        } catch {
            log.fault(.resort, "cached bundle \(id.rawValue.prefix(12)) failed verification: \(error)")
            do {
                if let location = location(name) { try FileManager.default.removeItem(at: location) }
            } catch {
                log.error(.resort, "could not remove the damaged bundle: \(error)")
            }
            return nil
        }
    }

    /// The stored bytes, unverified: the caller runs them through
    /// `BundleLoader.load` (the demo republishes them on its own server).
    public func storedData(_ id: BundleID) -> Data? {
        read("\(id.rawValue).json.gz")
    }

    /// Stores bytes that have already passed `BundleLoader.load`. The map it
    /// replaces is deleted: a resort keeps one map on the phone.
    ///
    /// The pointer moves, and the old map goes, only once the new map is on
    /// disk: with the phone full, a failed write leaves the working map in use
    /// (specs/07-CLIENT.md section 4, "a failed refresh leaves the working map
    /// alone").
    public func save(_ data: Data, as id: BundleID, activeFor resortID: String) {
        let previous = activeBundleID(resortID: resortID)
        let kept = isKept(resortID)
        let name = "\(id.rawValue).json.gz"
        guard write(data, to: name, kept: kept) else { return }
        guard write(Data(id.rawValue.utf8), to: "\(resortID).active", kept: kept) else {
            // Nothing points at the new map, so it would only take space.
            if previous != id { delete(name) }
            return
        }
        if let previous, previous != id { delete("\(previous.rawValue).json.gz") }
    }

    /// Deletes everything stored for a resort: its map, the pointer to it and
    /// the last status and conditions. Throws when a file could not be
    /// deleted, so the space is never reported as freed when it was not.
    public func remove(resortID: String) throws {
        for name in files(resortID: resortID) {
            for copy in [url(name), keptURL(name)].compactMap({ $0 }) where exists(copy) {
                try FileManager.default.removeItem(at: copy)
            }
        }
    }

    /// The resorts with a map on the phone.
    public func storedResortIDs() -> Set<String> {
        Self.names(in: directory, ending: ".active").union(keptDirectory.map { Self.names(in: $0, ending: ".active") } ?? [])
    }

    /// The names before `suffix` of the files in `folder` that end in it.
    private static func names(in folder: URL, ending suffix: String) -> Set<String> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            return []
        }
        return Set(names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
    }

    /// The bytes a resort's map, status and conditions take on disk.
    public func storedBytes(resortID: String) -> Int64 {
        files(resortID: resortID).reduce(0) { total, name in
            guard let location = location(name) else { return total }
            do {
                let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
                return total + (size?.int64Value ?? 0)
            } catch {
                return total
            }
        }
    }

    private func files(resortID: String) -> [String] {
        var names = ["\(resortID).active", "\(resortID).status.json", "\(resortID).conditions.json"]
        if let id = activeBundleID(resortID: resortID) { names.append("\(id.rawValue).json.gz") }
        return names
    }

    private func delete(_ name: String) {
        for copy in [url(name), keptURL(name)].compactMap({ $0 }) where exists(copy) {
            do {
                try FileManager.default.removeItem(at: copy)
            } catch {
                log.error(.resort, "could not delete \(name): \(error)")
            }
        }
    }

    /// The resorts whose maps the user downloaded: their trail maps move out
    /// of the cache into `keptDirectory`, and a resort no longer listed moves
    /// back. Maps already on the phone are moved, not downloaded again, so the
    /// first launch with this moves every earlier download. Safe to stop at
    /// any point and to repeat: a resort is marked before its files move.
    public func keep(_ resortIDs: Set<String>) {
        guard let keptDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: keptDirectory, withIntermediateDirectories: true)
            var folder = keptDirectory
            var values = URLResourceValues()
            // Downloaded again in a minute; not worth the user's iCloud space.
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        } catch {
            log.error(.resort, "the folder for downloaded maps could not be made: \(error)")
            return
        }
        let marked = Self.names(in: keptDirectory, ending: ".kept")
        for resortID in marked.subtracting(resortIDs) {
            move(resortID, kept: false)
            delete("\(resortID).kept")
        }
        for resortID in resortIDs {
            if !marked.contains(resortID) { write(Data(), to: "\(resortID).kept", kept: true) }
            move(resortID, kept: true)
        }
    }

    /// Moves a resort's map and its pointer into or out of `keptDirectory`.
    private func move(_ resortID: String, kept: Bool) {
        var names = ["\(resortID).active"]
        if let id = activeBundleID(resortID: resortID) { names.insert("\(id.rawValue).json.gz", at: 0) }
        for name in names {
            guard let keptCopy = keptURL(name) else { return }
            let (from, to) = kept ? (url(name), keptCopy) : (keptCopy, url(name))
            guard exists(from) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if exists(to) {
                    try FileManager.default.removeItem(at: from)
                } else {
                    try FileManager.default.moveItem(at: from, to: to)
                }
            } catch {
                log.error(.resort, "could not move \(name): \(error)")
            }
        }
    }

    /// The last resort catalog the server sent, so the picker and Settings →
    /// Maps still list the maps on this phone with no connection.
    public func save(catalog: [PublishedResort]) {
        save(catalog, to: "catalog.json")
    }

    public func catalog() -> [PublishedResort]? {
        load([PublishedResort].self, from: "catalog.json")
    }

    public func activeBundleID(resortID: String) -> BundleID? {
        read("\(resortID).active").flatMap { BundleID(String(decoding: $0, as: UTF8.self)) }
    }

    public func save(_ status: ResortStatus) {
        save(status, to: "\(status.resortID).status.json")
    }

    public func save(_ conditions: Conditions) {
        save(conditions, to: "\(conditions.resortID).conditions.json")
    }

    public func status(resortID: String) -> ResortStatus? {
        load(ResortStatus.self, from: "\(resortID).status.json")
    }

    public func conditions(resortID: String) -> Conditions? {
        load(Conditions.self, from: "\(resortID).conditions.json")
    }

    private func save(_ value: some Encodable, to name: String) {
        do {
            write(try WireCoding.encoder().encode(value), to: name)
        } catch {
            log.error(.resort, "could not encode \(name): \(error)")
        }
    }

    private func load<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let data = read(name) else { return nil }
        do {
            return try WireCoding.decoder().decode(type, from: data)
        } catch {
            log.error(.resort, "cached \(name) is unreadable: \(error)")
            return nil
        }
    }
}
