//
//  SkiCatalogEntry.swift
//  PowderMeet
//
//  Row from `public.skis_catalog`. Surfaced via the SKIS picker in
//  the Activity calibration menu and resolved by id from
//  `profiles.preferred_ski_id`.
//

import Foundation

struct SkiCatalogEntry: Codable, Identifiable, Sendable, Hashable {
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
