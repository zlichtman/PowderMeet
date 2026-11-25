import DescentKit
import Foundation
import MountainCore
import PMLogging
import PowderMeetAPI

/// Live run recording (`specs/08-ACTIVITY.md` section 2, `specs/00-PRODUCT.md`
/// J6). While recording is on it reads the shared fix stream; at a published
/// resort the fixes go into a `LiveRunBuffer`, and every run the buffer
/// closes is stored through `ActivityLibrary.storeLive` (source `live`), which
/// uploads it or leaves it in the outbox. Leaving the resort or turning
/// recording off ends the run in progress.
///
/// The buffer and the day's figures are written to one file per user after
/// every change, so a relaunch (or iOS ending the app overnight) loses no
/// points; the file is removed when recording stops.
///
/// It does not start or stop location itself: the app's location driver keeps
/// fixes coming while `LocationDemand.recordingOn` is set.
public actor LiveRecorder {
    /// What the ACTIVITY page shows while recording.
    public struct Status: Sendable, Hashable, Codable {
        /// The resort the phone is at, or nil while waiting to arrive.
        public var resortID: String?
        public var resortName: String?
        /// `yyyy-MM-dd` at the resort of the runs counted below.
        public var day: String?
        public var runsToday = 0
        public var verticalTodayM = 0.0
        public var lastRunEndedAt: Date?
        /// Runs saved on the phone, waiting for a signal.
        public var queued = 0

        public init() {}
    }

    private struct Saved: Codable {
        var buffer: LiveRunBuffer
        var status: Status
    }

    /// How often the buffer is written while points arrive.
    static let saveIntervalS: TimeInterval = 20
    /// How long to wait before asking for the catalog again after a failure.
    static let catalogRetryS: TimeInterval = 120

    private let deps: Dependencies
    private let library: ActivityLibrary
    private let user: UUID
    private let file: URL
    private var buffer = LiveRunBuffer()
    private var status = Status()
    private var resorts: [PublishedResort] = []
    private var lastSaved: Date?
    private let statusCast = Multicast<Status>()
    private let runCast = Multicast<Status>()
    private var stopping = false

    public init(dependencies: Dependencies, directory: URL, user: UUID) {
        deps = dependencies
        library = ActivityLibrary(dependencies: dependencies)
        self.user = user
        file = Self.file(of: user, in: directory)
    }

    private static func file(of user: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(user.uuidString.lowercased()).json")
    }

    /// The account was deleted: the run in progress is dropped, not stored,
    /// since a sign-out keeps this file only so signing back in resumes it,
    /// and a deleted account never signs back in. Call it once the
    /// recorder's tasks have ended, so no late save writes the file again.
    public static func discardRecording(of user: UUID, in directory: URL) throws(PowderMeetError) {
        let file = file(of: user, in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw .data(.recordingNotRemoved)
        }
    }

    /// The status now, then every change.
    public func statuses() -> AsyncStream<Status> { statusCast.stream(initial: status) }

    /// The status after each store that saved at least one run.
    public func savedRuns() -> AsyncStream<Status> { runCast.stream() }

    /// Records until cancelled or `stop()`. Call `stop()` first to end the run in
    /// progress and remove the file; a plain cancellation (sign-out) keeps it.
    public func run() async {
        restore()
        let fixes = deps.location.deviceFixes()
        let catalog = Task { [weak self] in await self?.loadCatalog() }
        defer { catalog.cancel() }
        for await fix in fixes {
            if Task.isCancelled || stopping { break }
            await ingest(fix)
        }
    }

    /// Recording was turned off: the run in progress is stored and the file goes.
    public func stop() async {
        stopping = true
        await store(buffer.flush())
        status.resortID = nil
        status.resortName = nil
        publish()
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            deps.log.error(.activity, "live: could not remove the recording file: \(error)")
        }
    }

    // MARK: Fixes

    private func ingest(_ fix: Fix) async {
        let at = ResortVicinity.resort(at: fix.coordinate, in: resorts, current: status.resortID)
        if at?.id != status.resortID {
            if status.resortID != nil {
                // Left the resort: whatever was in progress has ended.
                // Logs are public: which resort the skier is at stays out of them.
                deps.log.info(.activity, "live: left the resort")
                await store(buffer.flush())
            }
            status.resortID = at?.id
            status.resortName = at?.name
            if at != nil { deps.log.info(.activity, "live: at a resort") }
            publish()
            save(force: true)
        }
        guard at != nil else { return }
        let point = TrackPoint(
            lat: fix.coordinate.lat, lon: fix.coordinate.lon, elevationM: fix.altitudeM,
            timestamp: fix.capturedAt, speedMS: fix.speedMS
        )
        let closed = buffer.append(point, accuracyM: fix.accuracyM)
        if closed.isEmpty {
            save(force: false)
        } else {
            await store(closed)
        }
    }

    private func store(_ runs: [Descent]) async {
        guard !runs.isEmpty else {
            save(force: true)
            return
        }
        // Saved first: if the upload below is cut short the runs are already
        // out of the buffer, and the outbox holds what did not go. The upload
        // holds background time, so a run that ends as the phone locks (or
        // the last one, when recording stops in the background) still goes.
        save(force: true)
        let library = library, resorts = resorts, user = user
        let outcome = await deps.background.hold("live-run-save") {
            await library.storeLive(runs, resorts: resorts, user: user)
        }
        switch outcome {
        case .imported(let imported):
            let zone = resorts.first { $0.id == status.resortID }.flatMap { TimeZone(identifier: $0.timezone) }
                ?? ActivityDay.approximateZone(lon: runs[0].points.first?.lon ?? 0)
            let day = ActivityDay.string(runs[0].startedAt, in: zone)
            if status.day != day {
                status.day = day
                status.runsToday = 0
                status.verticalTodayM = 0
                status.queued = 0
            }
            let saved = imported.runsAdded + imported.runsQueued
            status.runsToday += saved
            status.verticalTodayM += imported.verticalM
            status.queued += imported.runsQueued
            status.lastRunEndedAt = runs.last?.endedAt
            deps.log.info(.activity, "live: \(runs.count) runs closed, \(saved) saved")
            if saved > 0 { runCast.send(status) }
        case .failed(let reason):
            deps.log.error(.activity, "live: \(runs.count) runs not saved: \(reason)")
        }
        publish()
        save(force: true)
    }

    // MARK: Catalog

    /// The published resorts, for "is the phone at a ski area". Asked again
    /// until it answers; until then nothing is recorded.
    private func loadCatalog() async {
        while !Task.isCancelled {
            do {
                resorts = try await deps.backend.publishedResorts()
                return
            } catch {
                deps.log.notice(.activity, "live: catalog unavailable, waiting: \(error)")
            }
            do {
                try await deps.clock.sleep(for: Self.catalogRetryS)
            } catch {
                return
            }
        }
    }

    // MARK: Persistence

    private func restore() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            buffer = saved.buffer
            status = saved.status
            // Where the phone is now is for the next fix to say.
            status.resortID = nil
            status.resortName = nil
            deps.log.info(.activity, "live: resumed with \(buffer.points.count) points")
        } catch {
            deps.log.fault(.activity, "live: recording file unreadable, starting afresh: \(error)")
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                deps.log.error(.activity, "live: could not remove the unreadable file: \(error)")
            }
        }
        publish()
    }

    private func save(force: Bool) {
        // Once `stop()` has begun, an `ingest` resuming from an upload must
        // not write the file it removes back with old counts.
        guard !stopping else { return }
        let now = deps.clock.now
        if !force, let lastSaved, now.timeIntervalSince(lastSaved) < Self.saveIntervalS { return }
        lastSaved = now
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Saved(buffer: buffer, status: status))
            try data.write(to: file, options: .atomic)
        } catch {
            deps.log.error(.activity, "live: could not save the recording: \(error)")
        }
    }

    private func publish() { statusCast.send(status) }
}
