import DescentKit
import Foundation
import MountainCore
import PowderMeetAPI

/// The `.powdermeet` backup (`specs/08-ACTIVITY.md` section 2.3).
///
/// What it holds: every descent the user has, as stored (source, times,
/// content hash, resort, device, `stats` and the track bytes), plus the runs
/// still waiting in this phone's outbox. The descents are the only thing a
/// user makes that is not derived: matches are re-run against the current map
/// on import, the pace model is recomputed from the descents, and the profile,
/// friends and meets live in the account. The backup is for leaving an
/// account (deleting it deletes the descents) and for runs recorded offline
/// that never reached the server; a new phone signed in to the same account
/// already has everything else.
///
/// The file is JSON: `{"powdermeet_backup": 1, "created_at", "app_build",
/// "descents": [...]}`. `powdermeet_backup` is the format version and the
/// marker that tells it from an older PowderMeet backup format, which
/// `decode` also reads (`export_schema_version` 1...5; its runs carry no GPS).
public enum ActivityBackup {
    public static let fileExtension = "powdermeet"
    public static let version = 1
    /// Prefix of the content hash given to a run from the older backup format,
    /// which has no track to hash: SHA-256 of this and the run's own
    /// `dedup_hash`. It keys descents already stored, so it must never change.
    static let legacyHashNamespace = "powdermeet-v1|"

    /// One descent in the file, as `descent_upsert` stores it.
    public struct Entry: Hashable, Sendable, Codable {
        public var contentHash: String
        public var source: DescentSource
        public var startedAt: Date
        public var endedAt: Date
        public var resortID: String?
        public var device: String?
        public var stats: DescentStatsRow?
        /// `DescentTrackCodec` bytes; a track with no points for a run from the
        /// older backup format.
        public var track: Data

        public init(
            contentHash: String, source: DescentSource, startedAt: Date, endedAt: Date,
            resortID: String? = nil, device: String? = nil, stats: DescentStatsRow? = nil, track: Data
        ) {
            self.contentHash = contentHash
            self.source = source
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.resortID = resortID
            self.device = device
            self.stats = stats
            self.track = track
        }

        init(_ record: DescentRecord) {
            self.init(
                contentHash: record.summary.contentHash, source: record.summary.source,
                startedAt: record.summary.startedAt, endedAt: record.summary.endedAt,
                resortID: record.summary.resortID, device: record.summary.device,
                stats: record.summary.stats, track: record.track
            )
        }

        init(_ upload: DescentUpload) {
            self.init(
                contentHash: upload.contentHash, source: upload.source, startedAt: upload.startedAt,
                endedAt: upload.endedAt, resortID: upload.resortID, device: upload.device,
                stats: upload.stats, track: upload.track
            )
        }

        private enum CodingKeys: String, CodingKey {
            case source, device, stats, track
            case contentHash = "content_hash"
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case resortID = "resort_id"
        }
    }

    /// What a backup file held.
    public struct Contents: Sendable, Hashable {
        public enum Origin: Sendable, Hashable {
            case powderMeet2(version: Int)
            /// An older PowderMeet backup and its `export_schema_version`.
            case powderMeet1(schemaVersion: Int)
        }

        public var origin: Origin
        public var createdAt: Date?
        public var entries: [Entry]
        /// Entries that could not be read (damaged, or an older-format run
        /// with no usable time) and were left out.
        public var skipped: Int
    }

    public enum DecodeError: Error, Sendable, Hashable {
        /// Not JSON, or JSON that is neither backup format.
        case notABackup
        /// A newer PowderMeet wrote it.
        case newerVersion(Int)
    }

    // MARK: Detection

    /// True for a file to restore rather than parse as GPS: the extension, or
    /// either format's marker near the start.
    public static func isBackup(fileName: String, data: Data) -> Bool {
        if URL(fileURLWithPath: fileName).pathExtension.lowercased() == fileExtension { return true }
        guard data.first(where: { !$0.isWhitespace }) == UInt8(ascii: "{") else { return false }
        // The older format usually writes its markers first, but sorted-keys
        // files put them after a base64 photo, so the window is a wide 2 MB.
        guard let head = String(data: data.prefix(2_097_152), encoding: .utf8)?.lowercased() else { return false }
        return ["\"powdermeet_backup\"", "\"export_schema_version\"", "\"exportschemaversion\""]
            .contains { head.contains($0) }
    }

    // MARK: Encoding

    /// The marker is written first, so a file that lost its extension is
    /// still recognised from its first bytes.
    public static func encode(_ entries: [Entry], createdAt: Date, appBuild: String) throws -> Data {
        let encoder = WireCoding.encoder()
        var data = Data("{\"powdermeet_backup\":\(version),\"created_at\":".utf8)
        data.append(try encoder.encode(createdAt))
        data.append(Data(",\"app_build\":".utf8))
        data.append(try encoder.encode(appBuild))
        data.append(Data(",\"descents\":".utf8))
        data.append(try encoder.encode(entries))
        data.append(Data("}".utf8))
        return data
    }

    /// The file name the share sheet offers: the date only, nothing about the user.
    public static func fileName(on date: Date) -> String {
        "powdermeet-\(ActivityDay.string(date, in: TimeZone(secondsFromGMT: 0) ?? .gmt)).\(fileExtension)"
    }

    private struct Envelope: Decodable {
        var powdermeetBackup: Int
        var createdAt: Date?
        var appBuild: String?
        var descents: [Lossy<Entry>]

        private enum CodingKeys: String, CodingKey {
            case descents
            case powdermeetBackup = "powdermeet_backup"
            case createdAt = "created_at"
            case appBuild = "app_build"
        }
    }

    /// One element of an array that may not decode; it decodes as nil
    /// instead of failing the whole file.
    struct Lossy<Value: Codable>: Codable {
        var value: Value?

        init(value: Value?) { self.value = value }

        init(from decoder: Decoder) throws {
            // A damaged element is left out and counted as skipped.
            do {
                value = try Value(from: decoder)
            } catch {
                value = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws(DecodeError) -> Contents {
        struct Marker: Decodable {
            var powdermeetBackup: Int?
            var exportSchemaVersion: Int?
            private enum CodingKeys: String, CodingKey {
                case powdermeetBackup = "powdermeet_backup"
                case exportSchemaVersion = "export_schema_version"
            }
        }
        let marker: Marker
        do {
            marker = try JSONDecoder().decode(Marker.self, from: data)
        } catch {
            throw .notABackup
        }
        if let version = marker.powdermeetBackup {
            guard version <= Self.version else { throw .newerVersion(version) }
            do {
                let envelope = try WireCoding.decoder().decode(Envelope.self, from: data)
                let entries = envelope.descents.compactMap(\.value).filter(isStorable)
                return Contents(
                    origin: .powderMeet2(version: version), createdAt: envelope.createdAt,
                    entries: entries, skipped: envelope.descents.count - entries.count
                )
            } catch {
                throw .notABackup
            }
        }
        return try decodeLegacy(data, schemaVersion: marker.exportSchemaVersion)
    }

    /// What `descent_upsert` would refuse, so one damaged entry is skipped
    /// rather than failing the file.
    static func isStorable(_ entry: Entry) -> Bool {
        let hash = entry.contentHash.utf8
        return hash.count == 64 && hash.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && entry.endedAt > entry.startedAt && (1...2_097_152).contains(entry.track.count)
    }

    // MARK: Older backup format

    /// One `imported_runs` row of an older PowderMeet backup (`runs`, schema 2
    /// and later). Only what a descent can hold is read; the file's edge ids
    /// name a graph that no longer exists.
    private struct LegacyRun: Decodable {
        var runAt: Date
        var durationS: Double?
        var dedupHash: String?
        var source: String?
        var resortID: String?
        var trailName: String?
        var difficulty: String?
        var speedMS: Double?
        var peakSpeedMS: Double?
        var verticalM: Double?
        var distanceM: Double?

        private enum CodingKeys: String, CodingKey {
            case source, difficulty
            case runAt = "run_at"
            case durationS = "duration_s"
            case dedupHash = "dedup_hash"
            case resortID = "resort_id"
            case trailName = "trail_name"
            case speedMS = "speed_ms"
            case peakSpeedMS = "peak_speed_ms"
            case verticalM = "vertical_m"
            case distanceM = "distance_m"
        }
    }

    private struct LegacyExport: Decodable {
        var exportedAt: Date?
        var runs: [Lossy<LegacyRunBox>]?

        private enum CodingKeys: String, CodingKey {
            case runs
            case exportedAt = "exported_at"
        }
    }

    /// `Lossy` needs `Codable`; an older-format run is only ever read.
    private struct LegacyRunBox: Codable {
        var run: LegacyRun
        init(from decoder: Decoder) throws { run = try LegacyRun(from: decoder) }
        func encode(to encoder: Encoder) throws {}
    }

    /// An older-format file: the wrapper (schema 1...5) or a bare profile,
    /// which the format also allows and which holds no runs. The profile,
    /// stats and photo are not restored: the account has its own.
    private static func decodeLegacy(_ data: Data, schemaVersion: Int?) throws(DecodeError) -> Contents {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = WireCoding.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        // The older format writes non-finite numbers as these strings.
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan"
        )
        let export: LegacyExport
        do {
            export = try decoder.decode(LegacyExport.self, from: data)
        } catch {
            throw .notABackup
        }
        if let schemaVersion, schemaVersion > 5 { throw .newerVersion(schemaVersion) }
        guard schemaVersion != nil || export.exportedAt != nil || export.runs != nil else { throw .notABackup }
        let runs = export.runs ?? []
        var seen: Set<String> = []
        var entries: [Entry] = []
        for box in runs {
            guard let run = box.value?.run, let entry = entry(for: run), seen.insert(entry.contentHash).inserted
            else { continue }
            entries.append(entry)
        }
        return Contents(
            origin: .powderMeet1(schemaVersion: schemaVersion ?? 1), createdAt: export.exportedAt,
            entries: entries, skipped: runs.count - entries.count
        )
    }

    /// An older-format run as a descent with no points: its start, its length,
    /// its figures and its trail name. It is not matched and carries no pace,
    /// so it never teaches calibration: its trail was matched on a different
    /// map, which cannot be checked against the current one.
    private static func entry(for run: LegacyRun) -> Entry? {
        func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        guard let duration = positive(run.durationS), run.runAt.timeIntervalSince1970.isFinite else { return nil }
        let key = run.dedupHash.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(run.source ?? "legacy")|\(Int(run.runAt.timeIntervalSince1970 / 15))|\(run.resortID ?? "unknown")"
        let track: Data
        do {
            track = try DescentTrackCodec.encodeEmpty(startingAt: run.runAt)
        } catch {
            return nil
        }
        let stats = DescentStatsRow(
            verticalM: positive(run.verticalM), distanceM: positive(run.distanceM),
            topSpeedMS: positive(run.peakSpeedMS), avgSpeedMS: positive(run.speedMS),
            trailName: run.trailName.flatMap { $0.isEmpty ? nil : $0 },
            difficulty: legacyDifficulty(run.difficulty)?.rawValue
        )
        return Entry(
            contentHash: SHA256.hex(Data((legacyHashNamespace + key).utf8)),
            source: legacySource(run.source), startedAt: run.runAt,
            endedAt: run.runAt.addingTimeInterval(duration), resortID: run.resortID,
            device: "Older PowderMeet backup", stats: stats, track: track
        )
    }

    /// The file's sources that `DescentSource` names; the rest (Strava, a
    /// restored backup) are stored as `gpx`, as Ski Tracks is.
    private static func legacySource(_ raw: String?) -> DescentSource {
        DescentSource(rawValue: raw?.lowercased() ?? "") ?? .gpx
    }

    private static func legacyDifficulty(_ raw: String?) -> Difficulty? {
        guard let raw else { return nil }
        let letters = String(raw.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) })
        return switch letters {
        case "green": .green
        case "blue": .blue
        case "black": .black
        case "doubleblack": .doubleBlack
        case "park", "terrainpark": .park
        default: nil
        }
    }
}

private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}

// MARK: Export and import

extension ActivityLibrary {
    /// Rows read per call while exporting.
    static let backupPageSize = 200

    /// The user's backup as file bytes: every stored descent with its track,
    /// then the runs still queued on this phone. `progress` is told how many
    /// descents have been read.
    public func exportBackup(
        user: UUID, progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws(PowderMeetError) -> Data {
        var entries: [ActivityBackup.Entry] = []
        var hashes: Set<String> = []
        var offset = 0
        // Every stored descent, not the newest `historyLimit`: the file is what
        // remains of an account about to be deleted. A short page is the end.
        while true {
            let page: [DescentRecord]
            do {
                page = try await dependencies.backend.descentRecords(offset: offset, limit: Self.backupPageSize)
            } catch {
                dependencies.log.error(.activity, "backup: descents unavailable: \(error)")
                throw PowderMeetError(error)
            }
            for record in page where hashes.insert(record.summary.contentHash).inserted {
                entries.append(ActivityBackup.Entry(record))
            }
            offset += page.count
            await progress(entries.count)
            if page.count < Self.backupPageSize { break }
            if Task.isCancelled { throw .data(.backupFailed) }
        }
        for item in await dependencies.outbox.pending where item.user == user {
            if case .descent(let upload) = item.payload, hashes.insert(upload.contentHash).inserted {
                entries.append(ActivityBackup.Entry(upload))
            }
        }
        do {
            let data = try ActivityBackup.encode(entries, createdAt: Date(), appBuild: dependencies.appBuild)
            dependencies.log.info(.activity, "backup: \(entries.count) descents, \(data.count) bytes")
            return data
        } catch {
            dependencies.log.error(.activity, "backup: encoding failed: \(error)")
            throw .data(.backupFailed)
        }
    }

    /// Restores a backup file into the signed-in account; `importFiles` sends
    /// backups here. Nothing is replaced or deleted: a descent the account
    /// already has (by content hash, or by time as `DescentDeduplicator`
    /// judges it) is skipped, so importing the same file twice adds nothing.
    /// Each run is matched again against its resort's current map when its
    /// track has points.
    func importBackup(
        _ data: Data, name sourceName: String, user: UUID, context: inout Context
    ) async -> FileReport.Outcome {
        let deps = dependencies
        let contents: ActivityBackup.Contents
        do {
            contents = try ActivityBackup.decode(data)
        } catch .newerVersion {
            return .failed("This backup is from a newer PowderMeet. Update the app, then import it again.")
        } catch {
            deps.log.notice(.activity, "backup: \(Self.logged(sourceName)) unreadable")
            return .failed("This isn't a PowderMeet backup PowderMeet can read.")
        }
        var imported = FileReport.Imported(
            resortName: nil, day: "", dayCount: 0, sourceApp: "PowderMeet",
            runsFound: contents.entries.count, runsAdded: 0, runsAlreadyHad: 0, runsQueued: 0,
            runsNamed: 0, verticalM: 0, notes: []
        )
        if case .powderMeet1 = contents.origin {
            imported.notes.append("Runs from an older PowderMeet backup have no GPS track, so they show their figures but no map.")
        }
        var refused = contents.skipped
        var days: Set<String> = []
        var resortVotes: [String: Int] = [:]

        for entry in contents.entries.sorted(by: { $0.startedAt < $1.startedAt }) {
            let points: [TrackPoint]
            do {
                points = try DescentTrackCodec.decode(entry.track)
            } catch {
                refused += 1
                continue
            }
            let descent = Descent(
                source: ActivitySource(rawValue: entry.source.rawValue) ?? .gpx,
                startedAt: entry.startedAt, endedAt: entry.endedAt, points: points
            )
            let resort = entry.resortID.flatMap { id in context.resorts.first { $0.id == id } }
                ?? Self.resort(for: descent, in: context.resorts)
            var stats = entry.stats ?? DescentStatsRow()
            if stats.resortName == nil { stats.resortName = resort?.name }
            if stats.localDay == nil {
                let zone = resort.flatMap { TimeZone(identifier: $0.timezone) }
                    ?? points.first.map { ActivityDay.approximateZone(lon: $0.lon) }
                    ?? TimeZone(secondsFromGMT: 0) ?? .gmt
                stats.localDay = ActivityDay.string(entry.startedAt, in: zone)
            }
            if let day = stats.localDay { days.insert("\(stats.resortName ?? "")|\(day)") }
            if imported.day.isEmpty, let day = stats.localDay { imported.day = day }
            if let name = stats.resortName { resortVotes[name, default: 0] += 1 }
            imported.verticalM += stats.verticalM ?? 0

            if context.hashes.contains(entry.contentHash)
                || (DescentDeduplicator.duplicates(of: [descent], in: context.existing).first ?? nil) != nil {
                imported.runsAlreadyHad += 1
                continue
            }

            var match: DescentUpload.Match?
            if points.count >= 2, let resort, let bundle = await context.bundles.bundle(for: resort) {
                match = Self.place(descent, in: bundle, stats: &stats)
            }
            if stats.matched == true { imported.runsNamed += 1 }

            let upload = DescentUpload(
                source: entry.source, startedAt: entry.startedAt, endedAt: entry.endedAt,
                contentHash: entry.contentHash, track: entry.track, resortID: resort?.id ?? entry.resortID,
                device: entry.device, appBuild: deps.appBuild, match: match, stats: stats
            )
            do {
                let result = try await deps.backend.descentUpsert(upload)
                if result.created { imported.runsAdded += 1 } else { imported.runsAlreadyHad += 1 }
            } catch let error as BackendError where error.isTransient {
                await deps.outbox.enqueue(key: "descent:\(entry.contentHash)", user: user, .descent(upload))
                imported.runsQueued += 1
            } catch BackendError.invalid {
                deps.log.notice(.activity, "backup: a descent of \(Self.logged(sourceName)) was refused")
                refused += 1
                continue
            } catch {
                deps.log.error(.activity, "backup: descent_upsert failed for \(Self.logged(sourceName)): \(error)")
                let saved = imported.runsAdded
                return .failed(
                    "The backup was read, but restoring it failed: \(PowderMeetError(error).userMessage)"
                        + (saved > 0 ? " \(saved) runs were restored before that." : "")
                )
            }
            context.existing.append(descent)
            context.hashes.insert(entry.contentHash)
        }

        imported.dayCount = days.count
        imported.resortName = resortVotes.count == 1 ? resortVotes.keys.first : nil
        if imported.runsQueued > 0 {
            imported.notes.insert(
                "No signal: \(imported.runsQueued) runs are saved on this phone and upload when you're back online.",
                at: 0
            )
        }
        if refused > 0 {
            imported.notes.append("\(refused) runs in the backup were damaged and were left out.")
        }
        if contents.entries.isEmpty, refused == 0 {
            imported.notes.append("The backup holds no runs.")
        }
        deps.log.info(
            .activity,
            "backup: \(sourceName): \(imported.runsFound) runs, \(imported.runsAdded) added, "
                + "\(imported.runsAlreadyHad) already stored, \(imported.runsQueued) queued, \(refused) refused"
        )
        return .imported(imported)
    }
}
