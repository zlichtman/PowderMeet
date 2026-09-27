//
//  ActivityImportTypes.swift
//  PowderMeet
//
//  Import error / source / result value types. Split out of
//  ActivityImporter.swift (behavior-preserving code motion).
//

import Foundation

// MARK: - Errors

enum ImportError: LocalizedError {
    case noTracks
    case unsupportedFormat
    /// Slopes-specific failure surfaced from `SlopesParser`.
    case slopesParseFailed(SlopesParserError)
    case parseEmpty                       // file parsed but yielded no segments
    case fileReadFailed(underlying: Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .noTracks:                 return "No GPS tracks found in the file."
        case .unsupportedFormat:        return "Unsupported file format. Use GPX, TCX, FIT, or Slopes files."
        case .slopesParseFailed(let i): return i.errorDescription
        case .parseEmpty:               return "Could not extract any runs from this file."
        case .fileReadFailed(let u):    return "Could not read file: \(u.localizedDescription)"
        case .notAuthenticated:         return "Sign in before importing ski activity."
        }
    }
}

// MARK: - File-format detection

nonisolated enum ActivityFileFormat {
    case gpx, tcx, fit, slopes
    /// PowderMeet backup envelope (JSON with profile + stats + runs).
    /// Handled separately from activity formats — it doesn't go through
    /// per-file parse → match → persist; it goes straight to
    /// the unified replace-mode backup restore path.
    case powdermeetBackup

    static func detect(url: URL, data: Data) -> ActivityFileFormat? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "gpx": return .gpx
        case "tcx": return .tcx
        case "fit": return .fit
        case "slopes": return .slopes
        case "powdermeet": return .powdermeetBackup
        default: break
        }
        // Fall back to magic bytes / content sniffing.
        if data.count >= 14 {
            let sig = String(data: data[8..<12], encoding: .ascii)
            if sig == ".FIT" { return .fit }
        }
        if data.count > 16 {
            let header = String(data: data.prefix(15), encoding: .utf8)
            if header == "SQLite format 3" { return .slopes }
        }
        // ZIP magic — Slopes' modern export, but could also be a third-party
        // GPX-in-ZIP. We treat ZIP as .slopes here; SlopesParser falls back
        // gracefully to "no tracks" if it isn't actually a Slopes archive.
        if data.count >= 4, data[0] == 0x50, data[1] == 0x4B {
            return .slopes
        }
        // GPX / TCX live in the first 4KB by spec — small sniff is fine.
        if let head = String(data: data.prefix(4096), encoding: .utf8)?.lowercased() {
            if containsXMLTag("gpx", in: head) { return .gpx }
            if containsXMLTag("trainingcenterdatabase", in: head) { return .tcx }
        }
        // PowderMeet backup sniff — much wider window because v3
        // backups embed a base64 avatar that can run hundreds of KB.
        // New exports place the schema marker first (struct member
        // order, no .sortedKeys), so it lands in the first ~80 bytes.
        // Legacy sorted-keys v3 exports could push the marker past
        // megabytes of avatar payload. 2 MB cap covers any realistic
        // avatar without slurping the whole file.
        let sniffLimit = min(data.count, 2_097_152)
        if let body = String(data: data.prefix(sniffLimit), encoding: .utf8)?.lowercased(),
           body.contains("\"export_schema_version\"")
            || body.contains("\"exported_at\"")
            || body.contains("\"exportschemaversion\"")
            || body.contains("\"exportedat\"") {
            return .powdermeetBackup
        }
        return nil
    }

    /// Content sniffing must ignore vendor namespace prefixes. Extensions are
    /// normally present, but document providers can hand the picker temporary
    /// URLs such as `Inbox/item` with no useful suffix.
    private static func containsXMLTag(_ localName: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: localName)
        let pattern = "<(?:[a-z0-9_.-]+:)?\(escaped)(?:\\s|>)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Batch result types

/// Result of a multi-file import. Each file produces a FileOutcome so
/// the UI can show ✅ / ⚠️ duplicate / ❌ error per row without the
/// caller having to interpret a single thrown error.
///
/// `recomputeSucceeded` reflects the post-import RPC pair (stats +
/// per-edge speeds). When it's `false` the import rows DID land in
/// `imported_runs`, but the solver's per-edge memory wasn't refreshed
/// — surface to the banner so the user knows to retry rather than
/// thinking the calibration silently took.
nonisolated struct BatchImportResult {
    let perFile: [FileOutcome]
    let recomputeSucceeded: Bool

    var totalRunsImported: Int {
        perFile.reduce(0) { acc, outcome in
            switch outcome.status {
            case .imported(let n): return acc + n
            case .duplicate, .failed, .empty: return acc
            }
        }
    }
}

/// Per-file telemetry captured by the importer so we can explain
/// "upload feels slow" with objective stage timings.
nonisolated struct FileImportTiming: Sendable {
    let totalMs: Int
    let readMs: Int?
    let detectMs: Int?
    let parseMs: Int?
    let processMs: Int?
}

/// How each run resolved during matching. Strict feeds algorithmic
/// calibration; relaxed/nearest are display-only naming fallbacks.
nonisolated struct MatchQualityStats: Sendable {
    let strictCount: Int
    let relaxedCount: Int
    let nearestCount: Int
    let unmatchedCount: Int

    static let empty = MatchQualityStats(
        strictCount: 0,
        relaxedCount: 0,
        nearestCount: 0,
        unmatchedCount: 0
    )
}

/// Stable, per-run resort assignment. A single activity container can span
/// mountains (multi-day exports, merged workouts, or provider archives), so
/// resort identity must not be inferred once from the file's first GPS fix.
nonisolated struct ActivityResortGroup: Sendable {
    let resortId: String
    let catalogEntry: ResortEntry?
    let segments: [ParsedRunSegment]
}

nonisolated enum ActivityResortResolver {
    static func identifyResort(
        named reportedName: String?,
        catalog: [ResortEntry] = ResortEntry.catalog
    ) -> ResortEntry? {
        guard let reportedName else { return nil }
        let normalized = normalizedName(reportedName)
        guard !normalized.isEmpty else { return nil }
        return catalog.sorted { $0.id < $1.id }.first { entry in
            ([entry.id, entry.name] + entry.aliases).contains {
                normalizedName($0) == normalized
            }
        }
    }

    static func identifyResort(
        for points: [GPXTrackPoint],
        catalog: [ResortEntry] = ResortEntry.catalog
    ) -> ResortEntry? {
        let validPoints = points.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        }
        guard !validPoints.isEmpty else { return nil }

        let scored = catalog.compactMap { entry -> (
            entry: ResortEntry,
            votes: Int,
            meanCenterDistanceSquared: Double,
            area: Double
        )? in
            let contained = validPoints.filter {
                entry.bounds.minLat <= $0.latitude
                    && $0.latitude <= entry.bounds.maxLat
                    && entry.bounds.minLon <= $0.longitude
                    && $0.longitude <= entry.bounds.maxLon
            }
            guard !contained.isEmpty else { return nil }
            let centerLat = (entry.bounds.minLat + entry.bounds.maxLat) / 2
            let centerLon = (entry.bounds.minLon + entry.bounds.maxLon) / 2
            let meanDistance = contained.reduce(0.0) { partial, point in
                let dLat = point.latitude - centerLat
                let dLon = (point.longitude - centerLon)
                    * cos(centerLat * .pi / 180)
                return partial + dLat * dLat + dLon * dLon
            } / Double(contained.count)
            let area = (entry.bounds.maxLat - entry.bounds.minLat)
                * (entry.bounds.maxLon - entry.bounds.minLon)
            return (entry, contained.count, meanDistance, area)
        }

        return scored.sorted { lhs, rhs in
            if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
            if lhs.meanCenterDistanceSquared != rhs.meanCenterDistanceSquared {
                return lhs.meanCenterDistanceSquared < rhs.meanCenterDistanceSquared
            }
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return lhs.entry.id < rhs.entry.id
        }.first?.entry
    }

    static func group(
        _ segments: [ParsedRunSegment],
        fallbackResortId: String,
        fallbackCatalogEntry: ResortEntry? = nil,
        catalog: [ResortEntry] = ResortEntry.catalog
    ) -> [ActivityResortGroup] {
        var grouped: [String: (entry: ResortEntry?, segments: [ParsedRunSegment])] = [:]
        for segment in segments {
            let entry = identifyResort(for: segment.points, catalog: catalog)
                ?? fallbackCatalogEntry
            let resortId = entry?.id ?? fallbackResortId
            if grouped[resortId] == nil {
                grouped[resortId] = (entry, [])
            }
            grouped[resortId]?.segments.append(segment)
        }
        return grouped.keys.sorted().compactMap { resortId in
            guard let value = grouped[resortId] else { return nil }
            return ActivityResortGroup(
                resortId: resortId,
                catalogEntry: value.entry,
                segments: value.segments
            )
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "" }
            .joined()
            .lowercased()
    }
}

nonisolated struct FileOutcome {
    let url: URL
    let status: Status

    enum Status {
        case imported(runs: Int)
        case duplicate                    // every per-run identity already exists
        case empty                        // parsed cleanly but no runs
        case failed(error: Error)
    }
}

/// Internal: per-file work product that also carries the data needed
/// for post-join profile merging. Audit Phase 2.3 — `mergeSpeedsForFile`
/// / `mergeConditionsForFile` ran inside the parallel `processFile`,
/// so two files reading `currentUserProfile` at the same await point
/// produced last-writer-wins on the bucketed-speed columns. By
/// collecting matched runs across the parallel join and producing one global
/// merge, every file and resort contributes deterministically.
nonisolated struct ProcessedResortGroup: @unchecked Sendable {
    let resortId: String
    let matchedRuns: [MatchedRun]
    let graph: MountainGraph?
}

nonisolated struct ProcessedFile: @unchecked Sendable {
    let outcome: FileOutcome
    /// Empty when the file failed / was empty / was a duplicate. Non-
    /// empty when persistence succeeded; aggregator unions these and
    /// runs the per-difficulty median merge once.
    let resortGroups: [ProcessedResortGroup]
    var matchedRuns: [MatchedRun] { resortGroups.flatMap(\.matchedRuns) }
    /// Compatibility accessors for genuinely single-resort files. A file can
    /// now contain runs at more than one mountain, so callers that need the
    /// complete result must use `resortGroups`.
    var resortId: String? { resortGroups.count == 1 ? resortGroups[0].resortId : nil }
    var graph: MountainGraph? { resortGroups.count == 1 ? resortGroups[0].graph : nil }
    /// Optional stage timings for this file. Present for file-path imports;
    /// absent for short-circuit wrappers where timing isn't meaningful.
    let timing: FileImportTiming?
    /// Matching breakdown for imported runs.
    let matchQuality: MatchQualityStats?

    /// Wrap a fail / duplicate / empty `FileOutcome` with no matched
    /// runs. Convenience for the early-return sites in processFile.
    init(_ outcome: FileOutcome) {
        self.outcome = outcome
        self.resortGroups = []
        self.timing = nil
        self.matchQuality = nil
    }

    init(
        outcome: FileOutcome,
        matchedRuns: [MatchedRun],
        resortId: String?,
        graph: MountainGraph?,
        timing: FileImportTiming? = nil,
        matchQuality: MatchQualityStats? = nil
    ) {
        self.outcome = outcome
        if let resortId {
            self.resortGroups = [ProcessedResortGroup(
                resortId: resortId,
                matchedRuns: matchedRuns,
                graph: graph
            )]
        } else {
            self.resortGroups = []
        }
        self.timing = timing
        self.matchQuality = matchQuality
    }

    init(
        outcome: FileOutcome,
        resortGroups: [ProcessedResortGroup],
        timing: FileImportTiming? = nil,
        matchQuality: MatchQualityStats? = nil
    ) {
        self.outcome = outcome
        self.resortGroups = resortGroups
        self.timing = timing
        self.matchQuality = matchQuality
    }
}
