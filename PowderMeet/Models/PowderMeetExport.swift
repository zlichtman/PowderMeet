//
//  PowderMeetExport.swift
//  PowderMeet
//
//  Backup envelope written by EXPORT and consumed by the unified
//  ActivityImporter (alongside .gpx/.tcx/.fit/.slopes activity files).
//
//  Schema versions:
//    v1: profile + stats
//    v2: profile + stats + runs
//    v3: profile + stats + runs + avatar bytes (current)
//
//  Older shapes are still decodable — every added field is optional,
//  and a bare UserProfile JSON with no wrapper is accepted by the
//  importer too.
//

import Foundation

struct PowderMeetExport: Codable {
    // Schema markers go FIRST so the import-side content sniff in
    // ActivityImporter.detect() catches them in the first few hundred
    // bytes — before the (potentially huge) base64 avatar payload.
    // Without this, a backup with an embedded avatar bigger than the
    // sniff window was being rejected as "Unsupported format" because
    // the markers fell outside the scanned region.
    /// Schema marker so future imports can branch on capabilities.
    let exportSchemaVersion: Int
    let exportedAt: Date
    let profile: UserProfile
    let stats: ProfileStats?
    /// Per-run history. Optional for back-compat with v1 exports that
    /// only carried `profile + stats`. When present, import re-upserts
    /// these and recomputes stats from ground truth (server-side).
    let runs: [ImportedRunBackup]?
    /// Base64-encoded avatar image bytes (v3+). Embedded so the
    /// backup is fully self-contained: a user importing into a fresh
    /// account doesn't lose their photo if the original storage
    /// object got purged. Optional — older exports skip it. Always
    /// last so it doesn't push detection markers out of the sniff
    /// window.
    let avatarImageBase64: String?

    static let currentSchemaVersion = 3

    enum CodingKeys: String, CodingKey {
        case exportSchemaVersion = "export_schema_version"
        case exportedAt = "exported_at"
        case profile
        case stats
        case runs
        case avatarImageBase64 = "avatar_image_base64"
    }
}

/// Codable mirror of `imported_runs` columns that should round-trip in
/// a backup. `id` / `profile_id` / `created_at` are intentionally absent
/// — the server stamps `id` and `created_at`, and `profile_id` is set
/// to the importing user (so a backup from device A imports cleanly
/// into device B's account).
struct ImportedRunBackup: Codable {
    let resortId: String?
    let edgeId: String?
    let difficulty: String?
    let speedMs: Double
    let peakSpeedMs: Double?
    let durationS: Double
    let verticalM: Double
    let distanceM: Double
    let maxGradeDeg: Double
    let runAt: Date
    let dedupHash: String
    let source: String?
    let sourceFileHash: String?
    let trailName: String?

    enum CodingKeys: String, CodingKey {
        case resortId       = "resort_id"
        case edgeId         = "edge_id"
        case difficulty
        case speedMs        = "speed_ms"
        case peakSpeedMs    = "peak_speed_ms"
        case durationS      = "duration_s"
        case verticalM      = "vertical_m"
        case distanceM      = "distance_m"
        case maxGradeDeg    = "max_grade_deg"
        case runAt          = "run_at"
        case dedupHash      = "dedup_hash"
        case source
        case sourceFileHash = "source_file_hash"
        case trailName      = "trail_name"
    }

    init(from record: ImportedRunRecord) {
        resortId = record.resortId
        edgeId = record.edgeId
        difficulty = record.difficulty
        speedMs = record.speedMs
        peakSpeedMs = record.peakSpeedMs
        durationS = record.durationS
        verticalM = record.verticalM
        distanceM = record.distanceM
        maxGradeDeg = record.maxGradeDeg
        runAt = record.runAt
        if let hash = record.dedupHash, !hash.isEmpty {
            dedupHash = hash
        } else {
            // Synthesize a fallback when the source row predates
            // dedup_hash so we can still restore historical data —
            // same 15s-bucket shape as ActivityImporter (Phase 2.2).
            let startBucket = Int(record.runAt.timeIntervalSince1970 / 15)
            let src = record.source ?? "legacy"
            let resort = record.resortId ?? "unknown"
            let edge = record.edgeId ?? "unmatched"
            dedupHash = "\(src)|\(startBucket)|\(resort)|\(edge)"
        }
        source = record.source
        sourceFileHash = record.sourceFileHash
        trailName = record.trailName
    }
}
