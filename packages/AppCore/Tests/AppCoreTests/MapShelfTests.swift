import Foundation
import MountainCore
import Testing
@testable import AppCore

// Settings → Maps: a removed map frees its storage, and a resort that falls
// off the recent list is no longer held.

private func store() throws -> BundleStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return BundleStore(directory: directory)
}

private func bundleID(_ digit: Character) throws -> BundleID {
    try #require(BundleID(String(repeating: digit, count: 64)))
}

@Test func removingAMapDeletesItsFiles() throws {
    let bundles = try store()
    let first = try bundleID("a"), second = try bundleID("b")
    bundles.save(Data(repeating: 1, count: 1_000), as: first, activeFor: "whistler")
    bundles.save(Data(repeating: 2, count: 2_000), as: second, activeFor: "whistler")
    // The replaced map is gone; only the new one is counted.
    #expect(bundles.storedData(first) == nil)
    #expect(bundles.storedBytes(resortID: "whistler") > 2_000)
    #expect(bundles.storedResortIDs() == ["whistler"])

    try bundles.remove(resortID: "whistler")
    #expect(bundles.storedData(second) == nil)
    #expect(bundles.storedBytes(resortID: "whistler") == 0)
    #expect(bundles.storedResortIDs().isEmpty)
}

@Test func onlyTheLastFewOpenedAreHeldAsRecent() {
    var shelf = MapShelf()
    shelf.keep("revelstoke")
    let opened = ["whistler", "revelstoke", "baker", "stevens"]
    #expect(shelf.held(opened: opened) == ["revelstoke", "whistler", "baker"])
    #expect(shelf.place(of: "stevens", opened: opened) == nil)

    shelf.remove("whistler")
    #expect(shelf.place(of: "whistler", opened: opened) == nil)
    shelf.opened("whistler")
    #expect(shelf.place(of: "whistler", opened: opened) == .recent)
}

/// A downloaded map lives out of the purgeable cache: keeping moves the map
/// already on the phone, a later update lands beside it, and letting it go
/// moves it back; status stays a cache either way.
@Test func aDownloadedMapLivesOutOfTheCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("bundles"), kept = root.appendingPathComponent("maps")
    let bundles = BundleStore(directory: cache, keptDirectory: kept)
    let first = try bundleID("a"), second = try bundleID("b")
    func exists(_ folder: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
    bundles.save(Data(repeating: 1, count: 1_000), as: first, activeFor: "whistler")
    bundles.save(ResortStatus(
        resortID: "whistler", observedAt: .now, expiresAt: .now.addingTimeInterval(600), source: .epic, groups: [:]
    ))

    bundles.keep(["whistler"])
    #expect(exists(kept, "\(first.rawValue).json.gz") && exists(kept, "whistler.active"))
    #expect(!exists(cache, "\(first.rawValue).json.gz") && !exists(cache, "whistler.active"))
    #expect(exists(cache, "whistler.status.json"))
    #expect(try kept.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(bundles.storedData(first) == Data(repeating: 1, count: 1_000))
    #expect(bundles.storedResortIDs() == ["whistler"])
    // Moving again changes nothing.
    bundles.keep(["whistler"])
    #expect(bundles.activeBundleID(resortID: "whistler") == first)

    bundles.save(Data(repeating: 2, count: 2_000), as: second, activeFor: "whistler")
    #expect(exists(kept, "\(second.rawValue).json.gz") && !exists(kept, "\(first.rawValue).json.gz"))
    #expect(bundles.storedBytes(resortID: "whistler") > 2_000)

    bundles.keep([])
    #expect(exists(cache, "\(second.rawValue).json.gz") && !exists(kept, "whistler.active"))
    #expect(bundles.activeBundleID(resortID: "whistler") == second)
    try bundles.remove(resortID: "whistler")
    #expect(bundles.storedResortIDs().isEmpty)
}

/// The phone is full when an update arrives: the new map does not land, and the
/// map already on the phone stays the one in use.
@Test func aFailedMapWriteKeepsTheWorkingMap() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundles = BundleStore(directory: root)
    let first = try bundleID("a"), second = try bundleID("b")
    bundles.save(Data(repeating: 1, count: 1_000), as: first, activeFor: "whistler")
    // A folder in the new map's place makes only that write fail.
    let blocker = root.appendingPathComponent("\(second.rawValue).json.gz", isDirectory: true)
    try FileManager.default.createDirectory(
        at: blocker.appendingPathComponent("inside"), withIntermediateDirectories: true)

    bundles.save(Data(repeating: 2, count: 2_000), as: second, activeFor: "whistler")
    #expect(bundles.activeBundleID(resortID: "whistler") == first)
    #expect(bundles.storedData(first) == Data(repeating: 1, count: 1_000))
}
