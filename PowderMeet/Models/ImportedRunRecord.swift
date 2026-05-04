//
//  ImportedRunRecord.swift
//  PowderMeet
//
//  Decodable mirror of one row in the `imported_runs` Postgres table.
//  Used by the imported-runs viewer (`ImportedRunsView`) so the user
//  can audit what activities have been uploaded and delete selectively.
//
//  This is read-only on the client; activity-import writes use the
//  `ImportedRunRow` Encodable struct in `ActivityImporter.swift` (which
//  intentionally omits `id`, `created_at` — server-managed columns).
//

import Foundation

struct ImportedRunRecord: Codable, Identifiable {
    let id: UUID
    let profileId: UUID
    let resortId: String?
    /// Nil when the run couldn't be matched to a graph edge (resort
    /// outside catalog, no graph available, or the line missed the
    /// matcher's threshold). The viewer falls back to "Imported Run"
    /// for these.
    let edgeId: String?
    /// Nil for the same reason as edgeId — difficulty came from the
    /// matched edge.
    let difficulty: String?
    let speedMs: Double
    let peakSpeedMs: Double?
    let durationS: Double
    let verticalM: Double
    let distanceM: Double
    let maxGradeDeg: Double
    let runAt: Date
    let createdAt: Date
    /// Provenance: which app exported this row ('slopes', 'gpx', 'tcx',
    /// 'fit'). Nil for legacy rows imported before the source column was
    /// added. The viewer renders a small badge.
    let source: String?
    /// Trail name resolved at import-time. Persisted so the viewer can
    /// render trail labels regardless of whether the run's resort graph
    /// is currently loaded. Nil for legacy rows or when the run didn't
    /// match an edge.
    let trailName: String?
    /// Composite uniqueness key — recompiled and re-sent on backup
    /// restore so duplicate runs don't double-import. Always present
    /// for rows written by the unified importer.
    let dedupHash: String?
    /// SHA256 of the source file's bytes. Used by the importer's
    /// whole-file fast-skip path; round-tripped so a restored backup
    /// behaves the same as the original on subsequent re-uploads.
    let sourceFileHash: String?

    /// Display-friendly difficulty (capital first letter — matches what
    /// `RunDifficulty.displayName` produces for the same raw value).
    /// "—" when difficulty is unknown.
    var difficultyDisplay: String {
        guard let difficulty, let raw = difficulty.first else { return "—" }
        return raw.uppercased() + difficulty.dropFirst()
    }

    /// Uppercased label for the source badge ("SLOPES", "GPX", …).
    /// Empty string when source is nil so the badge can be hidden.
    var sourceBadge: String {
        source?.uppercased() ?? ""
    }

    /// Speed in km/h (rounded to 1 decimal). Stats inside the app
    /// generally show m/s; the runs list shows km/h because it reads
    /// more naturally for a "this run was fast" UI.
    var speedKmh: Double {
        (speedMs * 3.6 * 10).rounded() / 10
    }

    /// Duration formatted as `m:ss` for short runs and `h:mm:ss` once
    /// it crosses an hour. Lift rides are typically 4–8 minutes; runs
    /// are typically 1–5 minutes; bowls / top-to-bottom can exceed an
    /// hour on rare logged sessions.
    var durationDisplay: String {
        let total = Int(durationS.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case resortId = "resort_id"
        case edgeId = "edge_id"
        case difficulty
        case speedMs = "speed_ms"
        case peakSpeedMs = "peak_speed_ms"
        case durationS = "duration_s"
        case verticalM = "vertical_m"
        case distanceM = "distance_m"
        case maxGradeDeg = "max_grade_deg"
        case runAt = "run_at"
        case createdAt = "created_at"
        case source
        case trailName = "trail_name"
        case dedupHash = "dedup_hash"
        case sourceFileHash = "source_file_hash"
    }
}

// MARK: - Date grouping

extension Array where Element == ImportedRunRecord {
    /// Groups by `run_at` calendar day in the user's local time zone.
    /// Returned as ordered (date, runs) pairs newest-first so the view
    /// can render directly without a second sort.
    func groupedByDay(calendar: Calendar = .current) -> [(date: Date, runs: [ImportedRunRecord])] {
        var groups: [Date: [ImportedRunRecord]] = [:]
        for run in self {
            let day = calendar.startOfDay(for: run.runAt)
            groups[day, default: []].append(run)
        }
        return groups
            .map { (date: $0.key, runs: $0.value.sorted { $0.runAt > $1.runAt }) }
            .sorted { $0.date > $1.date }
    }
}
