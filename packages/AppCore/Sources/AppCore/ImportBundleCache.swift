import Foundation
import MountainCore
import PMLogging
import PowderMeetAPI

/// The resort bundles one import batch has opened. Files are matched several
/// at once, and a day's files are usually at one resort, so the first file to
/// want a bundle opens it and the others wait for that same load instead of
/// each reading or downloading it again.
actor ImportBundleCache {
    private let deps: Dependencies
    /// A load is stored before its first suspension, so a second caller that
    /// arrives while the first is downloading joins it.
    private var loads: [String: Task<ResortBundle?, Never>] = [:]

    init(deps: Dependencies) {
        self.deps = deps
    }

    /// The resort's active bundle from the phone's cache, else downloaded and
    /// verified. Nil (and remembered for the batch) when it cannot be had.
    func bundle(for resort: PublishedResort) async -> ResortBundle? {
        if let load = loads[resort.id] { return await load.value }
        let deps = deps
        let load = Task { await Self.open(resort, deps: deps) }
        loads[resort.id] = load
        // The load is unstructured so that several files can share it; an
        // import that is cancelled takes it down too.
        return await withTaskCancellationHandler {
            await load.value
        } onCancel: {
            load.cancel()
        }
    }

    /// Nonisolated, so decoding a bundle runs off this actor and two resorts
    /// open at the same time.
    private static func open(_ resort: PublishedResort, deps: Dependencies) async -> ResortBundle? {
        if let bundle = deps.bundles.activeBundleID(resortID: resort.id).flatMap({ deps.bundles.bundle($0) }) {
            return bundle
        }
        guard let id = resort.bundleID else { return nil }
        if let bundle = deps.bundles.bundle(id) { return bundle }
        do {
            let data = try await deps.backend.bundleData(resortID: resort.id, bundleID: id)
            let bundle = try BundleLoader.load(data: data, expectedID: id)
            deps.bundles.save(data, as: id, activeFor: resort.id)
            return bundle
        } catch {
            deps.log.error(.activity, "import: no map for \(resort.id), runs stay unnamed: \(error)")
            return nil
        }
    }
}
