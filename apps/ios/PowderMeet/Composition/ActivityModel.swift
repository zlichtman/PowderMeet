import AppCore
import Foundation
import Observation
import PMLogging
import PowderMeetAPI

/// The Profile's activity side: run history, lifetime totals, file and Apple
/// Health import, live recording and run details (`specs/07-CLIENT.md`
/// section 2, "Profile and history"). The work is `ActivityLibrary`'s and
/// `LiveRecorder`'s, off the main actor; this is what the views read.
@Observable
final class ActivityModel {
    nonisolated enum ImportPhase: Sendable, Hashable {
        case idle
        case working(done: Int, total: Int)
        case finished([ActivityLibrary.FileReport])
    }

    private(set) var history = ActivityHistory()
    /// True once the history on screen came from the backend.
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var failure: PowderMeetError?
    private(set) var importPhase = ImportPhase.idle
    /// Days and runs with a delete in flight, by their history ids.
    private(set) var deleting: Set<String> = []
    private(set) var isResetting = false
    /// Runs removed so far by the reset in flight, out of how many.
    private(set) var resetProgress: (done: Int, total: Int)?
    /// The report sheet: shown after a batch in which a file failed.
    var showsReport = false

    /// Live recording, as the user set it on this phone for this account.
    private(set) var isRecordingOn = false
    /// What the recorder says while it runs; nil when recording is off.
    private(set) var recording: LiveRecorder.Status?
    /// When Apple Health was last read for this account, nil if never.
    private(set) var healthImportedAt: Date?
    private(set) var isReadingHealth = false
    /// Run details by run id, loaded when a run is opened.
    private(set) var details: [UUID: DetailState] = [:]
    /// Activity → Back up: the `.powdermeet` file being made, then shared.
    private(set) var backup = BackupState.idle

    nonisolated enum BackupState: Sendable, Hashable {
        case idle
        /// Descents read so far.
        case exporting(Int)
        /// Written to a temporary file, for the share sheet.
        case ready(URL)
    }

    nonisolated enum DetailState: Sendable, Hashable {
        case loading
        case loaded(RunDetail)
        case missing
        case failed(PowderMeetError)
    }

    /// Told after every successful load, so pace calibration can follow the runs.
    var onHistoryLoaded: ((ActivityHistory) -> Void)?

    private let library: ActivityLibrary
    private let toasts: Toasts
    private let deps: Dependencies
    private let health = HealthKitService()
    private let notifier = LocalNotifier()
    /// A tag in the activity keys; empty since the demo backend went away.
    private let storageTag: String
    private let recordingDirectory: URL
    private var user: UUID?
    private var recorder: LiveRecorder?
    private var recorderTasks: [Task<Void, Never>] = []
    /// Files waiting for sign-in or for the running batch to finish.
    private var waiting: [URL] = []
    /// Files finished in earlier batches of this import, and their reports: files
    /// added while a batch runs join the same count and the same toast.
    private var runDone = 0
    private var runReports: [ActivityLibrary.FileReport] = []
    private var loadTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?
    /// Runs named by an older matcher, matched again once per sign-in.
    private var rematchTask: Task<Void, Never>?
    private var rematchStarted = false

    init(dependencies: Dependencies) {
        library = ActivityLibrary(dependencies: dependencies)
        toasts = dependencies.toasts
        deps = dependencies
        storageTag = ""
        recordingDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowderMeet/live-recording", isDirectory: true)
    }

    static var isHealthAvailable: Bool { HealthKitService.isAvailable }

    /// The demand the location driver needs from recording.
    var recordingAtResort: Bool? {
        guard isRecordingOn, let recording else { return nil }
        return recording.resortID != nil
    }

    private func key(_ name: String, _ user: UUID) -> String {
        "activity.\(name).\(storageTag)\(user.uuidString.lowercased())"
    }

    var isImporting: Bool {
        if case .working = importPhase { true } else { false }
    }

    /// The last batch's reports, for the report sheet.
    var lastReports: [ActivityLibrary.FileReport] {
        if case .finished(let reports) = importPhase { reports } else { [] }
    }

    // MARK: Lifecycle

    func signedIn(_ user: UUID) {
        guard self.user != user else { return }
        self.user = user
        healthImportedAt = UserDefaults.standard.object(forKey: key("healthImportedAt", user)) as? Date
        // Recording carries on across launches until the user turns it off.
        isRecordingOn = UserDefaults.standard.bool(forKey: key("liveRecording", user))
        if isRecordingOn { startRecorder(user) }
        refresh()
        startWaiting()
    }

    /// A sign-out keeps the recording file, the recording switch and the Health
    /// watermark, so signing back in carries on; a deleted account keeps nothing.
    func signedOut(_ reason: AppSession.SignOutReason) {
        let leaving = user
        let ending = recorderTasks + [importTask].compactMap { $0 }
        loadTask?.cancel()
        importTask?.cancel()
        stopRematch()
        rematchStarted = false
        stopRecorderTasks()
        if reason == .accountDeleted, let leaving { forget(leaving, after: ending) }
        // The day summary names this account's resort and runs: whoever signs
        // in next must not see it. After the recorder, which can still schedule one.
        Task { [notifier] in
            for task in ending { await task.value }
            await notifier.forgetDaySummaries()
        }
        isRecordingOn = false
        recording = nil
        healthImportedAt = nil
        details = [:]
        user = nil
        waiting = []
        runDone = 0
        runReports = []
        history = ActivityHistory()
        hasLoaded = false
        isLoading = false
        failure = nil
        importPhase = .idle
        // A Health read still waiting on its sheet belongs to the account
        // that left; it returns without touching the next one.
        isReadingHealth = false
        showsReport = false
        isResetting = false
        resetProgress = nil
        deleting = []
        backupTask?.cancel()
        finishBackup()
    }

    /// Removes what this phone holds of a deleted account. The recorder and an
    /// import end first: either can still save the recording or queue a run
    /// while it stops, after the session's own sweep of the outbox.
    private func forget(_ user: UUID, after ending: [Task<Void, Never>]) {
        UserDefaults.standard.removeObject(forKey: key("liveRecording", user))
        UserDefaults.standard.removeObject(forKey: key("healthImportedAt", user))
        UserDefaults.standard.removeObject(forKey: key("badgesSeen", user))
        Task { [deps, toasts, recordingDirectory] in
            for task in ending { await task.value }
            do {
                try LiveRecorder.discardRecording(of: user, in: recordingDirectory)
            } catch {
                await toasts.post(PowderMeetError(error))
            }
            await deps.outbox.discard(user: user)
        }
    }

    // MARK: Intents

    func refresh() {
        guard user != nil else { return }
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self, library] in
            do {
                let history = try await library.history()
                guard let self, !Task.isCancelled else { return }
                self.history = history
                self.hasLoaded = true
                self.failure = nil
                self.isLoading = false
                self.onHistoryLoaded?(history)
                self.startRematch()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failure = PowderMeetError(error)
                self.isLoading = false
            }
        }
    }

    /// After the first history load of a sign-in, in the background: runs
    /// stored by an older matcher are matched again with the maps on this
    /// phone (`ActivityLibrary.rematchOlderRuns`). It waits for an import to
    /// finish, and stops for a delete, which a re-sent run would undo. A pass
    /// cut short carries on at the next sign-in or launch.
    private func startRematch() {
        guard !rematchStarted, !isImporting, !isResetting, deleting.isEmpty else { return }
        rematchStarted = true
        rematchTask = Task(priority: .utility) { [weak self, library] in
            let updated = await library.rematchOlderRuns()
            guard let self, !Task.isCancelled else { return }
            self.rematchTask = nil
            if updated > 0 { self.refresh() }
        }
    }

    /// A pass stopped here starts again at the next history load.
    private func stopRematch() {
        guard let rematchTask else { return }
        rematchTask.cancel()
        self.rematchTask = nil
        rematchStarted = false
    }

    /// Imports files the user picked or opened in PowderMeet. Files that
    /// arrive before sign-in wait for it; files added during an import run
    /// right after the current batch, under the same count and one toast.
    func enqueue(_ urls: [URL]) {
        waiting.append(contentsOf: urls)
        if case .working(let done, let total) = importPhase {
            importPhase = .working(done: done, total: total + urls.count)
        }
        startWaiting()
    }

    /// Files wait while Apple Health is read too: its import takes the same
    /// progress and task, and picks the files up when it finishes.
    private func startWaiting() {
        guard user != nil, !isImporting, !isReadingHealth, !waiting.isEmpty else { return }
        let urls = waiting
        waiting = []
        importFiles(urls)
    }

    private func importFiles(_ urls: [URL]) {
        guard let user, !urls.isEmpty else { return }
        let sources = urls.map { url in
            ActivityLibrary.Source(name: url.lastPathComponent) {
                // A picked or shared file is outside the sandbox until claimed.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }
        }
        importPhase = .working(done: runDone, total: runDone + sources.count + waiting.count)
        stopRematch()
        importTask = Task { [weak self, library] in
            let reports = await library.importFiles(sources, user: user) { [weak self] done in
                await self?.noteFileProgress(done, batch: sources.count)
            }
            guard let self else { return }
            self.finish(reports, cancelled: Task.isCancelled)
        }
    }

    /// What a batch ends in: a toast with the count, and the report sheet when
    /// a file could not be imported.
    private func finish(_ batch: [ActivityLibrary.FileReport], cancelled: Bool) {
        if !cancelled, !waiting.isEmpty, user != nil {
            runDone += batch.count
            runReports += batch
            let urls = waiting
            waiting = []
            importFiles(urls)
            return
        }
        let reports = runReports + batch
        runDone = 0
        runReports = []
        importPhase = .finished(reports)
        var added = 0, failed = 0
        for report in reports {
            switch report.outcome {
            case .imported(let imported): added += imported.runsAdded + imported.runsQueued
            case .failed: failed += 1
            }
        }
        var message = cancelled ? "Import cancelled" : "Runs imported"
        message += " · \(added) \(added == 1 ? "run" : "runs") imported"
        if failed > 0 { message += " · \(failed) \(failed == 1 ? "file" : "files") not imported" }
        Task { [toasts] in await toasts.post(message: message) }
        if failed > 0, !cancelled { showsReport = true }
        if added > 0 { Task { [notifier] in await notifier.runsImported(added) } }
        refresh()
        startWaiting()
    }

    // MARK: Live recording

    /// Turns live recording on or off for this account on this phone. Off ends
    /// the run in progress and stores it.
    func setRecording(_ on: Bool) {
        guard let user, on != isRecordingOn else { return }
        isRecordingOn = on
        UserDefaults.standard.set(on, forKey: key("liveRecording", user))
        if on {
            startRecorder(user)
        } else if let recorder {
            let tasks = recorderTasks
            recorderTasks = []
            self.recorder = nil
            recording = nil
            Task { [weak self] in
                await recorder.stop()
                for task in tasks { task.cancel() }
                self?.refresh()
            }
        }
    }

    private func startRecorder(_ user: UUID) {
        stopRecorderTasks()
        let recorder = LiveRecorder(dependencies: deps, directory: recordingDirectory, user: user)
        self.recorder = recorder
        recording = LiveRecorder.Status()
        recorderTasks.append(Task { await recorder.run() })
        recorderTasks.append(Task { [weak self] in
            for await status in await recorder.statuses() {
                guard let self, self.recorder === recorder else { return }
                self.recording = status
            }
        })
        recorderTasks.append(Task { [weak self, notifier] in
            for await status in await recorder.savedRuns() {
                guard let self, self.recorder === recorder else { return }
                self.refresh()
                await notifier.scheduleDaySummary(
                    runs: status.runsToday, verticalM: status.verticalTodayM,
                    resortName: status.resortName, day: status.day
                )
            }
        })
    }

    private func stopRecorderTasks() {
        for task in recorderTasks { task.cancel() }
        recorderTasks = []
        recorder = nil
    }

    // MARK: Badges

    /// The badges this phone has announced for the account (`BadgeMoments`),
    /// or nil when it has never recorded any.
    var seenBadges: Set<String>? {
        guard let user else { return nil }
        return UserDefaults.standard.stringArray(forKey: key("badgesSeen", user)).map(Set.init)
    }

    func rememberSeenBadges(_ seen: Set<String>) {
        guard let user else { return }
        UserDefaults.standard.set(seen.sorted(), forKey: key("badgesSeen", user))
    }

    // MARK: Apple Health

    /// Asks for Health access the first time, then imports the ski and
    /// snowboard workouts since the last read (all of them the first time),
    /// through the same queue and report as files.
    func importFromHealth() {
        guard let user, !isReadingHealth, !isImporting else { return }
        isReadingHealth = true
        // A day of overlap: a workout synced late is not missed, and the
        // server keeps one row per run whatever is sent twice.
        let since = healthImportedAt.map { $0.addingTimeInterval(-86_400) }
        Task { [weak self, health, library, toasts] in
            let startedAt = Date()
            do {
                try await health.requestAccess()
                let read = try await health.recordings(since: since)
                let recordings = read.recordings
                guard let self, self.user == user else { return }
                self.isReadingHealth = false
                if read.unreadRoutes > 0 {
                    let count = read.unreadRoutes
                    await toasts.post(message: count == 1
                        ? "One workout's route couldn't be read from Apple Health. It will be tried again next time."
                        : "\(count) workouts' routes couldn't be read from Apple Health. They will be tried again next time.")
                }
                guard !recordings.isEmpty else {
                    // Files opened while Health was read go now.
                    self.startWaiting()
                    if read.unreadRoutes > 0 { return }
                    await toasts.post(message: since == nil
                        ? "No ski or snowboard workouts with a route were found in Apple Health. If you didn't allow access, turn it on in Settings → Health → Data Access & Devices."
                        : "No new ski or snowboard workouts in Apple Health.")
                    // No watermark: a refused read looks empty, and once access
                    // is allowed the next read must start from the beginning.
                    return
                }
                self.importPhase = .working(done: 0, total: recordings.count)
                self.importTask = Task { [weak self] in
                    let reports = await library.importRecordings(recordings, user: user) { [weak self] done in
                        await self?.noteProgress(done, of: recordings.count)
                    }
                    guard let self else { return }
                    // Moving the watermark past an unread workout would skip it for good.
                    if !Task.isCancelled, read.unreadRoutes == 0 { self.noteHealthRead(startedAt, user: user) }
                    self.finish(reports, cancelled: Task.isCancelled)
                }
            } catch {
                guard let self, self.user == user else { return }
                self.isReadingHealth = false
                self.startWaiting()
                await toasts.post(PowderMeetError(error))
            }
        }
    }

    private func noteHealthRead(_ at: Date, user: UUID) {
        healthImportedAt = at
        UserDefaults.standard.set(at, forKey: key("healthImportedAt", user))
    }

    // MARK: Run detail

    func loadDetail(_ runID: UUID) {
        if case .loaded = details[runID] { return }
        if details[runID] == .loading { return }
        details[runID] = .loading
        Task { [weak self, library] in
            do {
                let detail = try await library.detail(of: runID)
                self?.details[runID] = detail.map(DetailState.loaded) ?? .missing
            } catch {
                let error = PowderMeetError(error)
                self?.details[runID] = .failed(error)
            }
        }
    }

    // MARK: Backup

    /// Makes the `.powdermeet` backup (`ActivityLibrary.exportBackup`): every
    /// stored descent and the runs still queued here, written to a temporary
    /// file named for the day, which the share sheet then offers. Failures
    /// arrive as a toast.
    func exportBackup() {
        guard let user else { return }
        if case .exporting = backup { return }
        backup = .exporting(0)
        backupTask = Task { [weak self, library, toasts] in
            do {
                let data = try await library.exportBackup(user: user) { [weak self] count in
                    await self?.noteBackupProgress(count)
                }
                let url = try await Task.detached(priority: .userInitiated) {
                    try ActivityModel.writeBackup(data)
                }.value
                guard let self, !Task.isCancelled else {
                    // Signed out while it was written: the copy of the runs goes.
                    do {
                        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    } catch {
                        self?.deps.log.notice(.activity, "backup: temporary file not removed: \(error)")
                    }
                    return
                }
                self.backup = .ready(url)
            } catch let error as PowderMeetError {
                self?.backup = .idle
                await toasts.post(error)
            } catch {
                // Writing the temporary file failed.
                self?.backup = .idle
                await toasts.post(PowderMeetError.data(.backupFailed))
            }
        }
    }

    private func noteBackupProgress(_ count: Int) {
        if case .exporting = backup { backup = .exporting(count) }
    }

    /// The share sheet closed: the temporary copy goes.
    func finishBackup() {
        if case .ready(let url) = backup {
            do {
                try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            } catch {
                deps.log.notice(.activity, "backup: temporary file not removed: \(error)")
            }
        }
        backup = .idle
    }

    /// `<tmp>/Backup/<uuid>/powdermeet-2026-11-20.powdermeet`: its own folder,
    /// so the shared file keeps the plain name and is removed with it.
    private nonisolated static func writeBackup(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Backup", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ActivityBackup.fileName(on: Date()))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Stops after the file being read; runs already saved stay.
    func cancelImport() {
        waiting = []
        importTask?.cancel()
    }

    /// Deletes every descent. Pace falls back to the preset as the history empties.
    func resetAll() {
        guard !isResetting else { return }
        stopRematch()
        isResetting = true
        let ids = history.allRunIDs
        resetProgress = (0, ids.count)
        Task { [weak self, library, toasts] in
            do {
                try await library.delete(ids) { [weak self] done in
                    await self?.noteResetProgress(done, of: ids.count)
                }
                await toasts.post(message: "Activity data reset · \(ids.count) runs removed")
            } catch {
                await toasts.post(PowderMeetError(error))
            }
            self?.isResetting = false
            self?.resetProgress = nil
            self?.refresh()
        }
    }

    private func noteResetProgress(_ done: Int, of total: Int) {
        guard isResetting else { return }
        resetProgress = (done, total)
    }

    private func noteProgress(_ done: Int, of total: Int) {
        guard isImporting else { return }
        importPhase = .working(done: done, total: total)
    }

    /// One count across this import's batches, files still waiting included.
    private func noteFileProgress(_ batchDone: Int, batch: Int) {
        guard isImporting else { return }
        importPhase = .working(done: runDone + batchDone, total: runDone + batch + waiting.count)
    }


    func delete(_ run: ActivityHistory.Run) {
        delete([run.id], marking: run.id.uuidString)
    }

    func delete(_ day: ActivityHistory.Day) {
        delete(day.runs.map(\.id), marking: day.id)
    }

    private func delete(_ ids: [UUID], marking key: String) {
        guard !deleting.contains(key) else { return }
        stopRematch()
        deleting.insert(key)
        Task { [weak self, library, toasts] in
            do {
                try await library.delete(ids)
            } catch {
                await toasts.post(PowderMeetError(error))
            }
            self?.deleting.remove(key)
            // Reload either way: a failure may have removed some of a day.
            self?.refresh()
        }
    }
}
