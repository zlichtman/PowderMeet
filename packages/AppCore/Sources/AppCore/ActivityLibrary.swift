import DescentKit
import Foundation
import MountainCore
import PMLogging
import PowderMeetAPI

/// Activity import and run history (`specs/08-ACTIVITY.md`): reads export files
/// with `DescentKit`, places each run on its resort's bundle, and stores the
/// descents through `descent_upsert`. It holds no state; the history is whatever
/// the backend returns. Every method runs off the main actor.
public struct ActivityLibrary: Sendable {
    /// One file to import. `load` is called off the main actor, once.
    public struct Source: Sendable {
        public var name: String
        public var load: @Sendable () throws -> Data

        public init(name: String, load: @escaping @Sendable () throws -> Data) {
            self.name = name
            self.load = load
        }
    }

    /// What happened to one file, in words the import screen shows as they are.
    public struct FileReport: Sendable, Hashable, Identifiable {
        public struct Imported: Sendable, Hashable {
            public var resortName: String?
            /// `yyyy-MM-dd` of the first run, at the resort.
            public var day: String
            public var dayCount: Int
            /// "Slopes", "Garmin", or nil when the file does not say.
            public var sourceApp: String?
            public var runsFound: Int
            public var runsAdded: Int
            public var runsAlreadyHad: Int
            /// Saved on the phone, to upload when there is a signal.
            public var runsQueued: Int
            /// Runs placed on a trail of the resort's map (not just near one).
            public var runsNamed: Int
            public var verticalM: Double
            /// Warnings from the file and from the import, most important first.
            public var notes: [String]
        }

        public enum Outcome: Sendable, Hashable {
            case imported(Imported)
            case failed(String)
        }

        public var id = UUID()
        public var fileName: String
        public var outcome: Outcome
    }

    public static let historyLimit = 5_000
    /// Stored runs read before saving live ones. A live run is the newest the
    /// skier has, and history comes newest first, so this covers its day twice
    /// over (two apps' worth of a long day) without reading the whole history
    /// on every lift ride.
    static let liveHistoryLimit = 200

    /// Logs are public and end up in shared bug reports, and a file's name can
    /// carry a person or a place ("Zach Whistler 2026-02-01.slopes"): only its
    /// kind is logged.
    static func logged(_ fileName: String) -> String {
        let kind = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return kind.isEmpty ? "a file" : "a .\(kind) file"
    }
    /// Larger than any ski day export; a bigger file is something else.
    public static let maximumFileBytes = 150 * 1_024 * 1_024

    private let deps: Dependencies
    var dependencies: Dependencies { deps }

    public init(dependencies: Dependencies) {
        deps = dependencies
    }

    // MARK: History

    public func history() async throws(PowderMeetError) -> ActivityHistory {
        do {
            return ActivityHistory(try await deps.backend.descents(limit: Self.historyLimit))
        } catch {
            deps.log.error(.activity, "history load failed: \(error)")
            throw PowderMeetError(error)
        }
    }

    /// Deletes in flight at once. One `descent_delete` per run, one after
    /// another, took 82 s for a 672-run reset on a phone.
    static let deleteConcurrency = 8

    /// Deletes descents, `deleteConcurrency` at a time; after the first
    /// failure no more are started, and that failure is thrown. `progress` is
    /// told how many are gone so far.
    public func delete(
        _ ids: [UUID], progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws(PowderMeetError) {
        let backend = deps.backend
        let failure: PowderMeetError? = await withTaskGroup(of: PowderMeetError?.self) { group in
            var next = 0
            var done = 0
            func start(_ id: UUID) {
                group.addTask {
                    do {
                        try await backend.descentDelete(descentID: id)
                        return nil
                    } catch {
                        return PowderMeetError(error)
                    }
                }
            }
            while next < min(ids.count, Self.deleteConcurrency) {
                start(ids[next])
                next += 1
            }
            while let outcome = await group.next() {
                if let outcome {
                    group.cancelAll()
                    return outcome
                }
                done += 1
                await progress(done)
                if next < ids.count {
                    start(ids[next])
                    next += 1
                }
            }
            return nil
        }
        if let failure {
            deps.log.error(.activity, "descent delete failed: \(failure)")
            throw failure
        }
    }

    // MARK: Import

    /// Files read, parsed and matched at once. That work is CPU-bound, one
    /// core per file, and the iPhones we support have two performance cores
    /// beside their efficiency cores, so a fourth file gains little. Memory sets
    /// the ceiling: a ski day is about 1 MB of file and a few MB parsed, but a
    /// file may be up to `maximumFileBytes` and is held inflated while it is
    /// parsed, a few hundred MB at worst, and iOS stops a foreground app on a
    /// 4 GB iPhone at roughly 2 GB; three of those is as many as can be risked.
    /// A parsed file waiting for its turn to save keeps only its runs, and at
    /// most `2 × importConcurrency` files are between opening and saving, so
    /// slow uploads cannot pile days up.
    static let importConcurrency = 3

    /// Imports the files: up to `importConcurrency` are read, parsed and
    /// matched at once, and each is then checked for duplicates and saved in
    /// the order given, because two files can hold the same day. Never throws:
    /// each file ends in a report, in the order of `sources`. `progress` is told
    /// how many files are finished. On cancellation the reports stop at the
    /// last file saved.
    public func importFiles(
        _ sources: [Source], user: UUID, progress: @Sendable (Int) async -> Void = { _ in }
    ) async -> [FileReport] {
        await importFiles(sources, user: user, concurrency: Self.importConcurrency, progress: progress)
    }

    func importFiles(
        _ sources: [Source], user: UUID, concurrency: Int, progress: @Sendable (Int) async -> Void
    ) async -> [FileReport] {
        var context = await Context(deps: deps)
        let resorts = context.resorts
        let bundles = context.bundles
        var reports: [FileReport] = []
        await withTaskGroup(of: (Int, PreparedFile?).self) { group in
            var next = 0
            var running = 0
            var ready: [Int: PreparedFile] = [:]
            // A long file at the head of the batch does not hold the others
            // back: later files are prepared while it is, and wait their turn.
            func startWhatFits() {
                let width = max(1, concurrency)
                while next < sources.count, running < width, next - reports.count < 2 * width {
                    let index = next
                    let source = sources[index]
                    group.addTask { (index, await prepare(source, resorts: resorts, bundles: bundles)) }
                    next += 1
                    running += 1
                }
            }
            startWhatFits()
            while reports.count < sources.count {
                guard let file = ready.removeValue(forKey: reports.count) else {
                    // A nil file was abandoned because the import was cancelled.
                    guard let (index, file) = await group.next(), let file else { break }
                    running -= 1
                    ready[index] = file
                    startWhatFits()
                    continue
                }
                if Task.isCancelled { break }
                let source = sources[reports.count]
                let outcome = await commit(file, name: source.name, user: user, context: &context)
                reports.append(FileReport(fileName: source.name, outcome: outcome))
                await progress(reports.count)
                if Task.isCancelled { break }
                startWhatFits()
            }
            group.cancelAll()
        }
        return reports
    }

    /// A recording that is not a file: an Apple Health workout's route.
    public struct Recording: Sendable {
        /// What the report calls it ("Apple Watch · 12 Jan").
        public var name: String
        public var activity: ParsedActivity

        public init(name: String, activity: ParsedActivity) {
            self.name = name
            self.activity = activity
        }

        /// An Apple Health workout's route (source `healthkit`). `sourceApp` is
        /// the app that wrote the workout ("Slopes", "Workout").
        public init(healthWorkoutNamed name: String, sourceApp: String?, route: [Fix]) {
            let points = route.map {
                TrackPoint(
                    lat: $0.coordinate.lat, lon: $0.coordinate.lon, elevationM: $0.altitudeM,
                    timestamp: $0.capturedAt, speedMS: $0.speedMS
                )
            }
            self.init(name: name, activity: ParsedActivity(
                source: .healthkit,
                segments: [ParsedSegment(
                    number: 1, startTime: points.first?.timestamp, endTime: points.last?.timestamp,
                    durationS: nil, points: points
                )],
                sourceApp: sourceApp
            ))
        }
    }

    /// Imports recordings through the same checks, segmenter, matching and
    /// upload as files. Never throws: each recording ends in a report.
    public func importRecordings(
        _ recordings: [Recording], user: UUID, progress: @Sendable (Int) async -> Void = { _ in }
    ) async -> [FileReport] {
        var context = await Context(deps: deps)
        var reports: [FileReport] = []
        for (index, recording) in recordings.enumerated() {
            let outcome: FileReport.Outcome
            do {
                let activity = try ActivityImporter.importRecording(recording.activity)
                outcome = await store(activity, name: recording.name, user: user, context: &context)
            } catch {
                deps.log.notice(.activity, "import: \(Self.logged(recording.name)) rejected: \(error)")
                outcome = .failed(Self.message(for: error))
            }
            reports.append(FileReport(fileName: recording.name, outcome: outcome))
            await progress(index + 1)
            if Task.isCancelled { break }
        }
        return reports
    }

    /// Stores runs the live recorder closed (source `live`). `resorts` is the
    /// catalog the recorder already holds, so a run costs no catalog read. The
    /// newest stored runs are read and compared, as for a file: a day already
    /// imported from another app was cut into runs differently, so the
    /// server's stricter overlap rule would let many of them in twice.
    public func storeLive(
        _ descents: [Descent], resorts: [PublishedResort], user: UUID
    ) async -> FileReport.Outcome {
        var context = Context(resorts: resorts, deps: deps)
        await context.readHistory(deps: deps, limit: Self.liveHistoryLimit)
        let activity = ImportedActivity(format: nil, sourceApp: "PowderMeet", descents: descents)
        return await store(activity, name: "live recording", user: user, context: &context)
    }

    /// What one batch shares: the skier's stored descents (for duplicates), the
    /// catalog and the bundles already opened.
    struct Context {
        var existing: [Descent]
        var hashes: Set<String>
        var resorts: [PublishedResort]
        let bundles: ImportBundleCache

        init(resorts: [PublishedResort], deps: Dependencies) {
            existing = []
            hashes = []
            self.resorts = resorts
            bundles = ImportBundleCache(deps: deps)
        }

        init(deps: Dependencies) async {
            bundles = ImportBundleCache(deps: deps)
            existing = []
            hashes = []
            resorts = []
            await readHistory(deps: deps, limit: ActivityLibrary.historyLimit)
            do {
                resorts = try await deps.backend.publishedResorts()
            } catch {
                deps.log.error(.activity, "import: catalog unavailable, runs will be unnamed: \(error)")
                resorts = []
            }
        }

        /// The newest `limit` stored descents, newest first, for duplicates.
        mutating func readHistory(deps: Dependencies, limit: Int) async {
            do {
                let rows = try await deps.backend.descents(limit: limit)
                // Only the time span is known for a stored descent; with no
                // points `DescentDeduplicator` decides on shared time alone.
                existing = rows.map {
                    Descent(source: .gpx, startedAt: $0.startedAt, endedAt: $0.endedAt, points: [])
                }
                hashes = Set(rows.map(\.contentHash))
            } catch {
                // The server still refuses a repeat, so the import can go on.
                deps.log.error(.activity, "import: history unavailable for duplicate check: \(error)")
            }
        }
    }

    /// A file read, parsed and matched, before it is checked against the
    /// history and saved. None of it depends on the files before it.
    enum PreparedFile: Sendable {
        case failed(String)
        /// Restored in its turn: a backup checks for duplicates before it
        /// matches, so it has nothing to do ahead of time.
        case backup(Data)
        case activity(ImportedActivity, [PreparedRun])
    }

    /// One descent placed on its resort and matched.
    struct PreparedRun: Sendable {
        var hash: String
        var resort: PublishedResort?
        var day: String
        var resortName: String?
        var stats: DescentStatsRow
        var match: DescentUpload.Match?
        /// The resort has a map, whether or not the run was placed on it.
        var mapped: Bool
        var track: Result<Data, DescentTrackCodec.CodecError>
    }

    /// Nil when the import was cancelled first.
    private func prepare(
        _ source: Source, resorts: [PublishedResort], bundles: ImportBundleCache
    ) async -> PreparedFile? {
        if Task.isCancelled { return nil }
        let data: Data
        do {
            data = try source.load()
        } catch {
            deps.log.error(.activity, "import: could not read \(Self.logged(source.name)): \(error)")
            return .failed("The file couldn't be opened. If it's in iCloud, download it first.")
        }
        if ActivityBackup.isBackup(fileName: source.name, data: data) {
            return .backup(data)
        }
        guard data.count <= Self.maximumFileBytes else {
            return .failed("The file is too large to be one day of skiing.")
        }

        var activity: ImportedActivity
        do {
            activity = try ActivityImporter.importActivity(fileName: source.name, data: data)
        } catch {
            deps.log.notice(.activity, "import: \(Self.logged(source.name)) rejected: \(error)")
            return .failed(Self.message(for: error))
        }
        activity = Self.readingUnzonedTimes(activity, resorts: resorts)
        guard let runs = await prepareRuns(activity, resorts: resorts, bundles: bundles, cancellable: true)
        else { return nil }
        return .activity(activity, runs)
    }

    /// Nil when `cancellable` and the import was cancelled first. Recordings
    /// are not: the live recorder stores its last runs as it is switched off.
    private func prepareRuns(
        _ activity: ImportedActivity, resorts: [PublishedResort], bundles: ImportBundleCache,
        cancellable: Bool
    ) async -> [PreparedRun]? {
        var runs: [PreparedRun] = []
        for descent in activity.descents {
            if cancellable, Task.isCancelled { return nil }
            let resort = Self.resort(for: descent, in: resorts)
            let zone = resort.flatMap { TimeZone(identifier: $0.timezone) }
                ?? ActivityDay.approximateZone(lon: descent.points.first?.lon ?? 0)
            let day = ActivityDay.string(descent.startedAt, in: zone)
            // Slopes and Ski Tracks name the resort; a GPX "name" is a track title.
            let fileResort = activity.format == .slopes || activity.format == .skiz
                ? activity.resortName?.replacingOccurrences(of: ",", with: ", ") : nil
            let resortName = resort?.name ?? fileResort

            var stats = Self.measured(descent)
            stats.resortName = resortName
            stats.localDay = day
            stats.sourceApp = activity.sourceApp

            var match: DescentUpload.Match?
            var mapped = false
            if let resort, let bundle = await bundles.bundle(for: resort) {
                match = Self.place(descent, in: bundle, stats: &stats)
                mapped = true
            }
            runs.append(PreparedRun(
                hash: DescentHasher.contentHash(descent), resort: resort, day: day,
                resortName: resortName, stats: stats, match: match, mapped: mapped,
                track: Result { () throws(DescentTrackCodec.CodecError) in try DescentTrackCodec.encode(descent) }
            ))
        }
        return runs
    }

    private func commit(
        _ file: PreparedFile, name sourceName: String, user: UUID, context: inout Context
    ) async -> FileReport.Outcome {
        switch file {
        case .failed(let message):
            .failed(message)
        case .backup(let data):
            await importBackup(data, name: sourceName, user: user, context: &context)
        case .activity(let activity, let runs):
            await save(activity, runs: runs, name: sourceName, user: user, context: &context)
        }
    }

    /// Places, matches and uploads the descents of one recording.
    private func store(
        _ activity: ImportedActivity, name sourceName: String, user: UUID, context: inout Context
    ) async -> FileReport.Outcome {
        let runs = await prepareRuns(
            activity, resorts: context.resorts, bundles: context.bundles, cancellable: false
        ) ?? []
        return await save(activity, runs: runs, name: sourceName, user: user, context: &context)
    }

    /// Checks the prepared runs against the history and uploads the new ones.
    /// Runs in file order, one file at a time: a run saved here is a repeat
    /// for the next file.
    private func save(
        _ activity: ImportedActivity, runs: [PreparedRun], name sourceName: String, user: UUID,
        context: inout Context
    ) async -> FileReport.Outcome {
        var imported = FileReport.Imported(
            resortName: nil, day: "", dayCount: ActivityImporter.dayCount(activity.descents),
            sourceApp: activity.sourceApp, runsFound: activity.descents.count, runsAdded: 0,
            runsAlreadyHad: 0, runsQueued: 0, runsNamed: 0, verticalM: 0,
            notes: activity.warnings.map(Self.note(for:))
        )
        var resortVotes: [String: Int] = [:]
        var unmappedRuns = 0
        let repeats = DescentDeduplicator.duplicates(of: activity.descents, in: context.existing)

        for (index, (descent, run)) in zip(activity.descents, runs).enumerated() {
            if imported.day.isEmpty { imported.day = run.day }
            if let resortName = run.resortName { resortVotes[resortName, default: 0] += 1 }
            imported.verticalM += run.stats.verticalM ?? 0
            if !run.mapped { unmappedRuns += 1 }
            if run.stats.matched == true { imported.runsNamed += 1 }

            // A repeat by time is another recording of a run already stored;
            // the same bytes go to the server again so their stats refresh.
            if repeats[index] != nil, !context.hashes.contains(run.hash) {
                imported.runsAlreadyHad += 1
                continue
            }

            let upload: DescentUpload
            switch run.track {
            case .success(let track):
                upload = DescentUpload(
                    source: DescentSource(rawValue: descent.source.rawValue) ?? .gpx,
                    startedAt: descent.startedAt, endedAt: descent.endedAt, contentHash: run.hash,
                    track: track, resortID: run.resort?.id,
                    device: activity.sourceApp.map { String($0.prefix(80)) },
                    appBuild: deps.appBuild, match: run.match, stats: run.stats
                )
            case .failure(let error):
                deps.log.error(.activity, "import: could not encode a run of \(Self.logged(sourceName)): \(error)")
                return .failed("A run in this file couldn't be prepared for saving.")
            }

            do {
                let result = try await deps.backend.descentUpsert(upload)
                if result.created { imported.runsAdded += 1 } else { imported.runsAlreadyHad += 1 }
            } catch let error as BackendError where error.isTransient {
                await deps.outbox.enqueue(key: "descent:\(run.hash)", user: user, .descent(upload))
                imported.runsQueued += 1
            } catch {
                deps.log.error(.activity, "import: descent_upsert failed for \(Self.logged(sourceName)): \(error)")
                let saved = imported.runsAdded
                return .failed(
                    "The runs were read, but saving them failed: \(PowderMeetError(error).userMessage)"
                        + (saved == 1 ? " 1 run was saved before that." : "")
                        + (saved > 1 ? " \(saved) runs were saved before that." : "")
                )
            }
            context.existing.append(descent)
            context.hashes.insert(run.hash)
        }

        imported.resortName = resortVotes.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        if imported.runsQueued > 0 {
            imported.notes.insert(
                "No signal: \(imported.runsQueued) runs are saved on this phone and upload when you're back online.",
                at: 0
            )
        }
        if unmappedRuns == activity.descents.count {
            imported.notes.append("This resort isn't mapped in PowderMeet yet, so runs have no trail names and don't adjust your pace.")
        } else if case let unplaced = activity.descents.count - unmappedRuns - imported.runsNamed, unplaced > 0 {
            imported.notes.append(
                "\(unplaced) of \(activity.descents.count) runs couldn't be placed on one trail; "
                    + "they show the nearest trail's name and don't adjust your pace."
            )
        }
        deps.log.info(
            .activity,
            "import: \(Self.logged(sourceName)): \(imported.runsFound) runs, \(imported.runsAdded) added, "
                + "\(imported.runsAlreadyHad) already stored, \(imported.runsQueued) queued"
        )
        return .imported(imported)
    }

    // MARK: Re-matching

    /// Brings stored runs up to the current matcher (`specs/08-ACTIVITY.md`
    /// section 3): a run whose `stats` carry an older or no `matcher_version`,
    /// at a resort whose map is on this phone, is matched again from its
    /// stored track and sent back with its own content hash and track bytes,
    /// so the server updates that row and never adds one. Runs go one at a
    /// time, and each one sent carries the new version, so a pass that stops
    /// (cancelled, no signal, the app quit) resumes on the next. Nothing goes
    /// to the outbox: the next pass is the retry. Returns how many runs were
    /// updated.
    public func rematchOlderRuns() async -> Int {
        let rows: [DescentSummary]
        do {
            rows = try await deps.backend.descents(limit: Self.historyLimit)
        } catch {
            deps.log.notice(.activity, "re-match: history unavailable: \(error)")
            return 0
        }
        let stale = Dictionary(grouping: rows.filter {
            $0.resortID != nil && ($0.stats?.matcherVersion ?? 0) < MatcherVersion
        }) { $0.resortID ?? "" }
        var updated = 0
        // One resort's map in memory at a time.
        for (resortID, runs) in stale.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled else { break }
            guard let bundle = deps.bundles.activeBundleID(resortID: resortID).flatMap({ deps.bundles.bundle($0) })
            else { continue }
            for run in runs {
                guard !Task.isCancelled else { break }
                switch await rematch(run, in: bundle) {
                case .updated: updated += 1
                case .skipped: continue
                case .stop: return updated
                }
            }
        }
        if updated > 0 { deps.log.info(.activity, "re-match: \(updated) runs brought up to matcher \(MatcherVersion)") }
        return updated
    }

    private enum RematchOutcome {
        case updated, skipped
        /// No signal, or the server is struggling: the next pass carries on.
        case stop
    }

    private func rematch(_ run: DescentSummary, in bundle: ResortBundle) async -> RematchOutcome {
        let detail: DescentDetail?
        do {
            detail = try await deps.backend.descentDetail(descentID: run.descentID)
        } catch let error as BackendError where error.isTransient {
            return .stop
        } catch {
            deps.log.error(.activity, "re-match: run unreadable: \(error)")
            return .skipped
        }
        // Deleted since the history was read: sending it would bring it back.
        guard let detail, let track = detail.track else { return .skipped }
        let points: [TrackPoint]
        do {
            points = try DescentTrackCodec.decode(track)
        } catch {
            deps.log.error(.activity, "re-match: track unreadable: \(error)")
            return .skipped
        }

        var stats = run.stats ?? DescentStatsRow()
        var match: DescentUpload.Match?
        if points.count >= 2 {
            // What the old match said goes; the figures measured from the
            // file stay, since the stored track has lost the segmenter's.
            stats.trailName = nil
            stats.difficulty = nil
            stats.matched = nil
            stats.pace = nil
            let descent = Descent(
                source: ActivitySource(rawValue: run.source.rawValue) ?? .gpx,
                startedAt: run.startedAt, endedAt: run.endedAt, points: points
            )
            match = Self.place(descent, in: bundle, stats: &stats)
        } else {
            // A run restored from an old backup has no points to match; the
            // version only stops it being read again.
            stats.matcherVersion = MatcherVersion
        }

        guard !Task.isCancelled else { return .stop }
        let upload = DescentUpload(
            source: run.source, startedAt: run.startedAt, endedAt: run.endedAt,
            contentHash: run.contentHash, track: track, resortID: run.resortID, device: run.device,
            appBuild: deps.appBuild, match: match, stats: stats
        )
        do {
            let result = try await deps.backend.descentUpsert(upload)
            guard result.created else { return .updated }
            // The run was deleted after it was read: it stays deleted.
            deps.log.notice(.activity, "re-match: a run deleted meanwhile is removed again")
            try await deps.backend.descentDelete(descentID: result.descentID)
            return .skipped
        } catch let error as BackendError where error.isTransient {
            return .stop
        } catch {
            deps.log.error(.activity, "re-match: descent_upsert failed: \(error)")
            return .skipped
        }
    }

    // MARK: Resort and trail

    /// The published resort a descent is at: its bounding box holds the middle
    /// of the track, and it is the nearest such resort.
    static func resort(for descent: Descent, in resorts: [PublishedResort]) -> PublishedResort? {
        guard !descent.points.isEmpty else { return nil }
        let middle = descent.points[descent.points.count / 2].coordinate
        return resorts
            .filter { $0.bbox?.contains(middle) == true }
            .min { a, b in
                let da = a.center.map { Geo.haversineM($0, middle) } ?? .infinity
                let db = b.center.map { Geo.haversineM($0, middle) } ?? .infinity
                return (da, a.id) < (db, b.id)
            }
    }

    /// Times written with no zone are the clock at the resort: they are read
    /// in its zone once the track places it. With no published resort around
    /// the track they stay UTC, and the file's report says so.
    static func readingUnzonedTimes(_ activity: ImportedActivity, resorts: [PublishedResort]) -> ImportedActivity {
        guard activity.warnings.contains(.timeZoneAssumedUTC),
              let resort = activity.descents.lazy.compactMap({ resort(for: $0, in: resorts) }).first,
              let zone = TimeZone(identifier: resort.timezone)
        else { return activity }
        return activity.readingUnzonedTimes(in: zone)
    }

    /// Matches the descent to the bundle. A match names the run, gives its
    /// difficulty and the pace evidence; without one the nearest trail is
    /// offered as a name only.
    static func place(
        _ descent: Descent, in bundle: ResortBundle, stats: inout DescentStatsRow
    ) -> DescentUpload.Match? {
        var edges: [EdgeID: Edge] = [:]
        for edge in bundle.graph.edges { edges[edge.id] = edge }
        func label(_ edge: Edge) -> (name: String?, difficulty: Difficulty?) {
            let group = edge.group.flatMap { bundle.group($0) }
            return (edge.name ?? group?.name, edge.difficulty ?? group?.difficulty)
        }

        stats.matcherVersion = MatcherVersion
        let match = TrailMatcher.match(descent: descent, in: bundle)
        guard match.isMatched else {
            if let near = TrailMatcher(graph: bundle.graph).approximateEdge(for: descent.points) {
                let (name, difficulty) = label(near)
                stats.trailName = name
                stats.difficulty = difficulty?.rawValue
                stats.matched = false
            }
            return nil
        }

        if let primary = match.primaryEdgeID.flatMap({ edges[$0.stored] }) {
            let (name, difficulty) = label(primary)
            stats.trailName = name
            stats.difficulty = difficulty?.rawValue
            stats.matched = true
        }
        var pace: [String: DescentStatsRow.Pace] = [:]
        for observation in match.matched where observation.hasPace {
            guard let edge = edges[observation.edgeID.stored], let difficulty = label(edge).difficulty,
                  difficulty != .unknown else { continue }
            var total = pace[difficulty.rawValue] ?? .init(movingS: 0, lengthM: 0)
            total.movingS += observation.movingS
            total.lengthM += observation.lengthM
            pace[difficulty.rawValue] = total
        }
        if !pace.isEmpty { stats.pace = pace }

        return DescentUpload.Match(
            bundleID: bundle.id.rawValue, matcherVersion: match.matcherVersion,
            matched: match.matched.map { observation in
                let difficulty = edges[observation.edgeID.stored].flatMap { label($0).difficulty }
                return DescentUpload.MatchedEdge(
                    edgeID: observation.edgeID.stored.rawValue, enterAt: observation.enterAt,
                    exitAt: observation.exitAt, movingS: observation.movingS, lengthM: observation.lengthM,
                    difficulty: difficulty == .unknown ? nil : difficulty?.rawValue
                )
            },
            coverage: match.coverage, confidence: match.confidence
        )
    }

    /// What the track itself says, with the segmenter's figures preferred.
    static func measured(_ descent: Descent) -> DescentStatsRow {
        func positive(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        let points = descent.points
        var distance = positive(descent.stats.distanceM)
        if distance == nil {
            distance = positive(Geo.lengthM(points.map(\.coordinate)))
        }
        var vertical = positive(descent.stats.verticalM)
        if vertical == nil, let top = points.first?.elevationM, let bottom = points.last?.elevationM {
            vertical = positive(top - bottom)
        }
        return DescentStatsRow(
            verticalM: vertical.map { ($0 * 10).rounded() / 10 },
            distanceM: distance.map { ($0 * 10).rounded() / 10 },
            topSpeedMS: (positive(descent.stats.topSpeedMS) ?? positive(GPXSpeedStats.peakSpeed(points)))
                .map { ($0 * 100).rounded() / 100 },
            avgSpeedMS: (positive(descent.stats.avgSpeedMS) ?? positive(GPXSpeedStats.movingAverageSpeed(points)))
                .map { ($0 * 100).rounded() / 100 }
        )
    }

    // MARK: Wording

    static func message(for error: ActivityImportError) -> String {
        switch error {
        case .unrecognizedFormat:
            "This isn't a file PowderMeet can read. Export GPX, FIT or TCX, or share the day from Slopes (.slopes) or Ski Tracks (.skiz)."
        case .unreadable(.unknownArchive):
            "This zip isn't a Slopes or Ski Tracks export."
        case .unreadable(.sqliteNotFoundInArchive), .unreadable(.noLocationTable), .unreadable(.emptyLocationTable):
            "This Slopes export has no recording inside."
        case .unreadable(.archive(.encrypted)):
            "This archive is password-protected, so it can't be read."
        case .unreadable:
            "The file is damaged or incomplete, so it couldn't be read. Export it again and retry."
        case .noTrack:
            "The file has no GPS track, only a summary, so there are no runs to find."
        case .noTimestamps:
            "The track has no times. It looks like a planned route, not a recording."
        case .noElevation:
            "The track has no altitude, so runs can't be told apart from lift rides."
        case .noDescents(.flatTrack):
            "No ski runs were found: the recording never goes downhill."
        case .noDescents(.onlyVehicleOrLift):
            "No ski runs were found: the downhill parts look like driving or riding a lift."
        case .noDescents(.tooSmallOrSlow):
            "No ski runs were found: the downhill parts are too short or too slow to be skiing."
        }
    }

    static func note(for warning: ImportWarning) -> String {
        func runs(_ count: Int) -> String { count == 1 ? "1 run" : "\(count) runs" }
        return switch warning {
        case .elevationInterpolated(let share):
            "Altitude was missing for \(Int((share * 100).rounded())) % of the track and was filled in."
        case .elevationMissing:
            "The file has no altitude, so its own run list was used as it is."
        case .timeZoneAssumedUTC:
            "Times in the file have no time zone and were read as UTC, so they may be hours off."
        case .multipleDays(let days):
            "The file covers \(days) days."
        case .untimedPointsDropped(let count):
            "\(count) points without a time were left out."
        case .pointsDiscarded(let count):
            "\(count) bad GPS points were left out."
        case .listedRunsDropped(let count):
            "\(runs(count)) in the app's list turned out to be a drive or a lift ride and \(count == 1 ? "was" : "were") left out."
        case .listedRunsSplit(let count):
            "\(runs(count)) in the app's list held more than one lap and \(count == 1 ? "was" : "were") split."
        case .unlistedRunsAdded(let count):
            "\(runs(count)) the app had missed \(count == 1 ? "was" : "were") added."
        case .vehicleTravelIgnored:
            "Driving in the recording was left out."
        case .liftDescentsIgnored(let count):
            "\(count == 1 ? "1 lift ride" : "\(count) lift rides") downhill \(count == 1 ? "was" : "were") left out."
        }
    }
}
