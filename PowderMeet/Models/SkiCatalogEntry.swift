//
//  SkiCatalogEntry.swift
//  PowderMeet
//
//  Row from `public.skis_catalog`. Surfaced via the SKIS picker in
//  the Activity calibration menu and resolved by id from
//  `profiles.preferred_ski_id`.
//

import Foundation

nonisolated struct SkiCatalogEntry: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let brand: String
    let model: String
    let category: String?
    let waistWidthMm: Int?
    /// Optional asset key matching an image set bundled in
    /// `SkisTopsheets.xcassets`. When non-nil, `HorizontalSkiView`
    /// renders the licensed topsheet image as the body; nil renders
    /// a neutral dark gradient on the silhouette (no brand-imitation
    /// patterns).
    let topsheetAssetKey: String?

    /// "Atomic Bent 110" — what the picker row, the calibration preview
    /// ski, and the on-mountain blob all display.
    var displayName: String { "\(brand) \(model)" }

    enum CodingKeys: String, CodingKey {
        case id
        case brand
        case model
        case category
        case waistWidthMm = "waist_width_mm"
        case topsheetAssetKey = "topsheet_asset_key"
    }
}

/// Conservative solver-facing snapshot derived from a selected catalog row.
/// Equipment changes ETA only; it never participates in open/closed, ability,
/// glade, or lift-hours eligibility gates.
nonisolated struct SkiPerformanceProfile: Sendable, Hashable {
    let skiID: UUID
    let waistWidthMm: Int?
    let category: String?

    init(entry: SkiCatalogEntry) {
        skiID = entry.id
        waistWidthMm = entry.waistWidthMm
        category = entry.category?.lowercased()
    }

    /// Small explainable speed adjustment, intentionally clamped to ±4%.
    /// Wider skis gain modest flotation on fresh, ungroomed snow; narrower
    /// skis gain modest edge-to-edge efficiency on groomed/firm snow. Catalog
    /// category adds a small discipline-specific signal without pretending
    /// waist width alone describes construction, tune, rocker, or skier fit.
    func speedMultiplier(for edge: GraphEdge, freshSnowCm: Double) -> Double {
        guard edge.kind == .run, let waistWidthMm else { return 1 }
        let widthSignal = max(-1, min(1, (Double(waistWidthMm) - 90) / 30))
        let category = category ?? ""
        let firm: Double
        if edge.attributes.difficulty == .terrainPark {
            // Park construction/shape is useful on features, while very wide
            // or very narrow platforms are a little less neutral. This is an
            // ETA nuance, never permission to enter marked park terrain.
            let parkBonus = category.contains("park") ? 0.02 : 0
            let widthDistanceFromParkCenter = min(
                1,
                abs(Double(waistWidthMm) - 95) / 30
            )
            firm = 1 + parkBonus - widthDistanceFromParkCenter * 0.01
        } else {
            let raceBonus = category.contains("race") ? 0.01 : 0
            firm = 1 - widthSignal * 0.015 + raceBonus
        }

        // Preserve the small firm/mixed/powder anchors, but interpolate
        // between them. A forecast crossing 3 or 8 cm must not abruptly make
        // a skier starting later finish earlier on the same trail.
        guard edge.attributes.isGroomed != true else {
            return max(0.96, min(1.04, firm))
        }
        let snow = freshSnowCm.isFinite ? max(0, freshSnowCm) : 0
        let mixed = edge.attributes.difficulty == .terrainPark
            ? firm : 1 + widthSignal * 0.01
        let categoryBonus = category.contains("powder")
            || category.contains("freeride") ? 0.01 : 0
        let powder = 1 + widthSignal * 0.03 + categoryBonus
        let raw = snow <= 3
            ? firm + (mixed - firm) * (snow / 3)
            : mixed + (powder - mixed) * min(1, (snow - 3) / 5)
        return max(0.96, min(1.04, raw))
    }

    var fingerprint: String {
        "\(skiID.uuidString):\(waistWidthMm.map(String.init) ?? "-"):\(category ?? "-")"
    }

    /// Matches the Postgres `uuid::text` representation used by the learned
    /// speed aggregator. Lowercasing avoids client/server UUID formatting
    /// differences from splitting one physical ski into two cohorts.
    var observationEquipmentKey: String {
        PerEdgeSpeed.normalizedEquipmentKey(for: skiID)
    }
}
