//
//  SupabaseManager+SnapshotPins.swift
//  PowderMeet
//
//  Extension of SupabaseManager — server-canonical resort snapshot-pin load + resolution.
//  Split out of SupabaseManager.swift (behavior-preserving code motion). Methods
//  inherit @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension SupabaseManager {
    // MARK: - Resort Snapshot Pins

    /// Decoder shape for `resort_snapshot_pins` rows.
    private struct ResortSnapshotPinRow: Decodable {
        let resortId: String
        let snapshotDate: String
        enum CodingKeys: String, CodingKey {
            case resortId = "resort_id"
            case snapshotDate = "snapshot_date"
        }
    }

    /// Refresh server-canonical pinned snapshot dates. Run at cold
    /// launch (from `initialize()`) and re-run on foreground via
    /// `verifySessionStillValid` so a snapshot bump propagates without
    /// requiring an app restart. Failures keep the previous in-memory
    /// dict — graceful degradation when offline (cache hydrated from
    /// UserDefaults still applies).
    func loadResortSnapshotPins() async {
        do {
            let rows: [ResortSnapshotPinRow] = try await client.from("resort_snapshot_pins")
                .select("resort_id,snapshot_date")
                .execute()
                .value
            var dict: [String: String] = [:]
            for row in rows {
                dict[row.resortId] = row.snapshotDate
            }
            resortSnapshotPins = dict
            // Persist to UserDefaults so the next cold launch already
            // has them before the network round-trip completes.
            if let encoded = try? JSONEncoder().encode(dict) {
                UserDefaults.standard.set(encoded, forKey: Self.resortSnapshotPinsCacheKey)
            }
        } catch {
            AppLog.supabase.error("loadResortSnapshotPins failed: \(error.localizedDescription)")
        }
    }

    /// Resolve the pinned snapshot date that should be used for a
    /// resort load. Order:
    ///   1. Per-resort server pin (`resortSnapshotPins[entry.id]`)
    ///   2. Catalog-wide server pin (`resortSnapshotPins["__catalog__"]`)
    ///   3. Per-resort baked override (`entry.pinnedSnapshotDate`)
    ///   4. Catalog-wide baked default (`ResortEntry.defaultPinnedSnapshotDate`)
    ///
    /// Always non-nil — the baked default is guaranteed.
    func resolvedPinnedSnapshotDate(for entry: ResortEntry) -> String {
        if let serverPin = resortSnapshotPins[entry.id] { return serverPin }
        if let catalogPin = resortSnapshotPins["__catalog__"] { return catalogPin }
        return entry.effectivePinnedSnapshotDate
    }
}
