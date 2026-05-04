//
//  ResortCatalog.swift
//  PowderMeet
//

import Foundation
import CoreLocation

enum PassProduct: String, Codable, CaseIterable, Hashable {
    case epic
    case ikon

    var displayName: String {
        switch self {
        case .epic: return "Epic"
        case .ikon: return "Ikon"
        }
    }
}

nonisolated struct ResortEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let bounds: BoundingBox
    let region: String
    let country: String
    let passProducts: Set<PassProduct>
    let aliases: [String]

    // Map presentation hints — curated per resort for "face the mountain" camera
    let preferredBearing: CLLocationDirection?
    let preferredPitch: Double?
    let preferredZoom: Double?

    /// Per-resort override of the catalog-wide pinned snapshot date. When
    /// set, the snapshot-resort Edge Function is asked for that exact
    /// `osm-{date}.json` / `elev-{date}.json` blob — immutable from then
    /// on, so every device sees identical OSM data and trail/lift counts
    /// stop drifting between cold launches. When nil, the global default
    /// (`ResortEntry.defaultPinnedSnapshotDate`) is used. Use the override
    /// to bump a single resort without touching everyone else (e.g. when
    /// a mountain genuinely added a new lift).
    let pinnedSnapshotDate: String?

    /// Catalog-wide pin. Every resort uses this date unless it sets its
    /// own `pinnedSnapshotDate`. Bumping this re-pins all 159 resorts in
    /// one move; the Edge Function rebuilds each from Overpass on first
    /// request after bump, then serves the immutable blob forever.
    static let defaultPinnedSnapshotDate = "2026-04-28"

    /// The pin actually used at request time — per-resort override first,
    /// catalog default second. Always non-nil (we always pin).
    var effectivePinnedSnapshotDate: String {
        pinnedSnapshotDate ?? Self.defaultPinnedSnapshotDate
    }

    init(
        id: String,
        name: String,
        bounds: BoundingBox,
        region: String,
        country: String,
        passProducts: Set<PassProduct> = [],
        aliases: [String] = [],
        preferredBearing: CLLocationDirection? = nil,
        preferredPitch: Double? = nil,
        preferredZoom: Double? = nil,
        pinnedSnapshotDate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.region = region
        self.country = country
        self.passProducts = passProducts
        self.aliases = aliases
        self.preferredBearing = preferredBearing
        self.preferredPitch = preferredPitch
        self.preferredZoom = preferredZoom
        self.pinnedSnapshotDate = pinnedSnapshotDate
    }

    /// Center coordinate for map camera positioning.
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (bounds.minLat + bounds.maxLat) / 2,
            longitude: (bounds.minLon + bounds.maxLon) / 2
        )
    }

    /// Default map zoom level based on bounding box span.
    var defaultZoom: Double {
        let span = max(bounds.maxLat - bounds.minLat, bounds.maxLon - bounds.minLon)
        if span > 0.12 { return 11.5 }
        if span > 0.08 { return 12.5 }
        if span > 0.05 { return 13.0 }
        return 13.5
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ResortEntry, rhs: ResortEntry) -> Bool { lhs.id == rhs.id }

    var searchableText: String {
        ([name, region, country] + aliases).joined(separator: " ").lowercased()
    }

    var passLabel: String {
        if passProducts == [.epic, .ikon] { return "Epic + Ikon" }
        if passProducts == [.epic] { return "Epic" }
        if passProducts == [.ikon] { return "Ikon" }
        return "Independent"
    }

    /// Resorts whose OSM bbox returned 0 piste:type=downhill ways AND
    /// 0 aerialway ways on the 2026-04-30 audit (queried via Overpass
    /// directly with the exact bbox the snapshot Edge Function uses).
    /// These mountains genuinely have no piste/aerialway tagging in
    /// OSM today — the cold load would build an empty graph. Hidden
    /// behind a "COMING SOON" section in the picker; tapping shows a
    /// banner instead of attempting to load.
    static let comingSoonIds: Set<String> = [
        "crotched", "mount-sunapee", "laurel-mountain", "jack-frost",
        "big-boulder", "hidden-valley-mo", "snow-creek", "paoli-peaks",
        "nakiska", "rusutsu", "myoko-suginohara", "nekoma",
        "jiminy-peak", "wild-mountain", "le-massif", "appi", "mt-t",
        "coronet-peak"
    ]

    var isComingSoon: Bool {
        Self.comingSoonIds.contains(id)
    }
}

nonisolated extension ResortEntry {
    private static func box(
        _ centerLat: Double,
        _ centerLon: Double,
        latSpan: Double = 0.05,
        lonSpan: Double = 0.07
    ) -> BoundingBox {
        BoundingBox(
            minLat: centerLat - latSpan / 2,
            maxLat: centerLat + latSpan / 2,
            minLon: centerLon - lonSpan / 2,
            maxLon: centerLon + lonSpan / 2
        )
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║  FULL CATALOG — 159 resorts (74 Epic · 85 Ikon)            ║
    // ║  Source: epicorikon.com 2025-26 season                      ║
    // ╚══════════════════════════════════════════════════════════════╝

    static let catalog: [ResortEntry] = epicResorts + ikonResorts

    // MARK: ─────────────────── EPIC (74) ───────────────────

    private static let epicResorts: [ResortEntry] = [

        // ── USA — Colorado ──
        ResortEntry(id: "vail", name: "Vail", bounds: box(39.62, -106.37, latSpan: 0.09, lonSpan: 0.12), region: "CO", country: "USA", passProducts: [.epic], preferredBearing: 0, preferredPitch: 62, preferredZoom: 12.5),
        ResortEntry(id: "beaver-creek", name: "Beaver Creek", bounds: box(39.60, -106.52, latSpan: 0.06, lonSpan: 0.09), region: "CO", country: "USA", passProducts: [.epic], preferredBearing: 350, preferredPitch: 62, preferredZoom: 13.0),
        ResortEntry(id: "breckenridge", name: "Breckenridge", bounds: box(39.48, -106.07, latSpan: 0.08, lonSpan: 0.10), region: "CO", country: "USA", passProducts: [.epic], preferredBearing: 5, preferredPitch: 62, preferredZoom: 12.8),
        ResortEntry(id: "keystone", name: "Keystone", bounds: box(39.58, -105.94, latSpan: 0.07, lonSpan: 0.08), region: "CO", country: "USA", passProducts: [.epic], preferredBearing: 0, preferredPitch: 62, preferredZoom: 13.0),
        ResortEntry(id: "crested-butte", name: "Crested Butte", bounds: box(38.87, -106.96, latSpan: 0.06, lonSpan: 0.07), region: "CO", country: "USA", passProducts: [.epic], preferredBearing: 355, preferredPitch: 62, preferredZoom: 13.0),
        ResortEntry(id: "telluride", name: "Telluride", bounds: box(37.94, -107.81, latSpan: 0.06, lonSpan: 0.08), region: "CO", country: "USA", passProducts: [.epic], preferredBearing: 345, preferredPitch: 62, preferredZoom: 13.0),

        // ── USA — Utah ──
        ResortEntry(id: "park-city", name: "Park City", bounds: box(40.65, -111.51, latSpan: 0.10, lonSpan: 0.13), region: "UT", country: "USA", passProducts: [.epic], preferredBearing: 5, preferredPitch: 62, preferredZoom: 12.0),

        // ── USA — California / Nevada ──
        ResortEntry(id: "heavenly", name: "Heavenly", bounds: box(38.93, -119.92, latSpan: 0.08, lonSpan: 0.09), region: "CA", country: "USA", passProducts: [.epic], preferredBearing: 0, preferredPitch: 62, preferredZoom: 12.8),
        ResortEntry(id: "kirkwood", name: "Kirkwood", bounds: box(38.68, -120.07, latSpan: 0.06, lonSpan: 0.07), region: "CA", country: "USA", passProducts: [.epic]),

        // ── USA — Washington ──
        ResortEntry(id: "stevens-pass", name: "Stevens Pass", bounds: box(47.75, -121.09, latSpan: 0.05, lonSpan: 0.06), region: "WA", country: "USA", passProducts: [.epic]),

        // ── USA — Oregon ──
        ResortEntry(id: "mt-bachelor", name: "Mt. Bachelor", bounds: box(43.98, -121.69, latSpan: 0.08, lonSpan: 0.10), region: "OR", country: "USA", passProducts: [.epic], aliases: ["Mount Bachelor"]),

        // ── USA — Vermont ──
        ResortEntry(id: "stowe", name: "Stowe", bounds: box(44.53, -72.78, latSpan: 0.06, lonSpan: 0.06), region: "VT", country: "USA", passProducts: [.epic], preferredBearing: 350, preferredPitch: 62, preferredZoom: 13.2),
        ResortEntry(id: "okemo", name: "Okemo", bounds: box(43.40, -72.72, latSpan: 0.05, lonSpan: 0.06), region: "VT", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "mount-snow", name: "Mount Snow", bounds: box(42.96, -72.90, latSpan: 0.05, lonSpan: 0.05), region: "VT", country: "USA", passProducts: [.epic]),

        // ── USA — New Hampshire ──
        ResortEntry(id: "attitash", name: "Attitash Mountain", bounds: box(44.08, -71.23, latSpan: 0.05, lonSpan: 0.05), region: "NH", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "wildcat", name: "Wildcat Mountain", bounds: box(44.26, -71.20, latSpan: 0.04, lonSpan: 0.05), region: "NH", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "crotched", name: "Crotched Mountain", bounds: box(43.06, -71.87, latSpan: 0.04, lonSpan: 0.05), region: "NH", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "mount-sunapee", name: "Mount Sunapee", bounds: box(43.38, -72.06, latSpan: 0.05, lonSpan: 0.05), region: "NH", country: "USA", passProducts: [.epic]),

        // ── USA — New York ──
        ResortEntry(id: "hunter", name: "Hunter Mountain", bounds: box(42.20, -74.21, latSpan: 0.05, lonSpan: 0.06), region: "NY", country: "USA", passProducts: [.epic]),

        // ── USA — Pennsylvania ──
        ResortEntry(id: "seven-springs", name: "Seven Springs", bounds: box(40.02, -79.30, latSpan: 0.05, lonSpan: 0.06), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "laurel-mountain", name: "Laurel Mountain", bounds: box(40.00, -79.22, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "liberty", name: "Liberty Mountain Resort", bounds: box(39.76, -77.38, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "hidden-valley-pa", name: "Hidden Valley (Pennsylvania)", bounds: box(40.08, -79.25, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "jack-frost", name: "Jack Frost", bounds: box(41.08, -75.68, latSpan: 0.04, lonSpan: 0.04), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "big-boulder", name: "Big Boulder", bounds: box(41.05, -75.64, latSpan: 0.04, lonSpan: 0.04), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "roundtop", name: "Roundtop Mountain Resort", bounds: box(40.11, -76.93, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "whitetail", name: "Whitetail Resort", bounds: box(39.74, -77.93, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.epic]),

        // ── USA — Midwest ──
        ResortEntry(id: "afton-alps", name: "Afton Alps", bounds: box(44.86, -92.79, latSpan: 0.04, lonSpan: 0.05), region: "MN", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "mt-brighton", name: "Mt Brighton", bounds: box(42.53, -83.81, latSpan: 0.04, lonSpan: 0.05), region: "MI", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "wilmot", name: "Wilmot", bounds: box(42.51, -88.18, latSpan: 0.04, lonSpan: 0.05), region: "WI", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "alpine-valley-ohio", name: "Alpine Valley", bounds: box(41.54, -81.29, latSpan: 0.04, lonSpan: 0.05), region: "OH", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "boston-mills-brandywine", name: "Boston Mills & Brandywine", bounds: box(41.28, -81.56, latSpan: 0.05, lonSpan: 0.06), region: "OH", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "mad-river-mountain", name: "Mad River Mountain", bounds: box(40.31, -83.68, latSpan: 0.04, lonSpan: 0.05), region: "OH", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "hidden-valley-mo", name: "Hidden Valley (Missouri)", bounds: box(38.49, -90.69, latSpan: 0.03, lonSpan: 0.04), region: "MO", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "snow-creek", name: "Snow Creek", bounds: box(39.40, -94.86, latSpan: 0.04, lonSpan: 0.05), region: "MO", country: "USA", passProducts: [.epic]),
        ResortEntry(id: "paoli-peaks", name: "Paoli Peaks", bounds: box(38.56, -86.47, latSpan: 0.03, lonSpan: 0.04), region: "IN", country: "USA", passProducts: [.epic]),

        // ── Canada ──
        ResortEntry(id: "whistler", name: "Whistler Blackcomb", bounds: box(50.09, -122.95, latSpan: 0.12, lonSpan: 0.14), region: "BC", country: "Canada", passProducts: [.epic], preferredBearing: 0, preferredPitch: 62, preferredZoom: 12.8),
        ResortEntry(id: "fernie", name: "Fernie Alpine Resort", bounds: box(49.50, -115.09, latSpan: 0.06, lonSpan: 0.07), region: "BC", country: "Canada", passProducts: [.epic]),
        ResortEntry(id: "kicking-horse", name: "Kicking Horse", bounds: box(51.30, -117.05, latSpan: 0.07, lonSpan: 0.08), region: "BC", country: "Canada", passProducts: [.epic]),
        ResortEntry(id: "kimberley", name: "Kimberley Alpine Resort", bounds: box(49.68, -116.00, latSpan: 0.05, lonSpan: 0.06), region: "BC", country: "Canada", passProducts: [.epic]),
        ResortEntry(id: "grouse-mountain", name: "Grouse Mountain", bounds: box(49.37, -123.08, latSpan: 0.04, lonSpan: 0.05), region: "BC", country: "Canada", passProducts: [.epic]),
        ResortEntry(id: "nakiska", name: "Nakiska", bounds: box(50.95, -115.08, latSpan: 0.05, lonSpan: 0.06), region: "AB", country: "Canada", passProducts: [.epic]),
        ResortEntry(id: "norquay", name: "Norquay", bounds: box(51.22, -115.60, latSpan: 0.04, lonSpan: 0.05), region: "AB", country: "Canada", passProducts: [.epic]),
        ResortEntry(id: "stoneham", name: "Stoneham Mountain Resort", bounds: box(47.03, -71.39, latSpan: 0.05, lonSpan: 0.06), region: "QC", country: "Canada", passProducts: [.epic]),

        // ── Japan (Epic) ──
        ResortEntry(id: "hakuba-goryu", name: "Hakuba Goryu", bounds: box(36.70, 137.85, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.epic]),
        ResortEntry(id: "hakuba-happo-one", name: "Hakuba Happo-One", bounds: box(36.70, 137.83, latSpan: 0.05, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.epic]),
        ResortEntry(id: "hakuba-iwatake", name: "Hakuba Iwatake", bounds: box(36.72, 137.84, latSpan: 0.03, lonSpan: 0.04), region: "JP", country: "Japan", passProducts: [.epic]),
        ResortEntry(id: "hakuba-norikura", name: "Hakuba Norikura Onsen", bounds: box(36.73, 137.83, latSpan: 0.03, lonSpan: 0.04), region: "JP", country: "Japan", passProducts: [.epic]),
        ResortEntry(id: "hakuba-sanosaka", name: "Hakuba Sanosaka Snow Resort", bounds: box(36.69, 137.84, latSpan: 0.03, lonSpan: 0.04), region: "JP", country: "Japan", passProducts: [.epic]),
        ResortEntry(id: "hakuba47", name: "Hakuba47 Winter Sports Park", bounds: box(36.71, 137.84, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.epic]),
        ResortEntry(id: "jiigatake", name: "Jiigatake", bounds: box(36.71, 137.86, latSpan: 0.03, lonSpan: 0.04), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["Jigatake Snow Resort"]),
        ResortEntry(id: "kashimayari", name: "Kashimayari", bounds: box(36.71, 137.87, latSpan: 0.03, lonSpan: 0.04), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["Kashimayari Snow Resort"]),
        ResortEntry(id: "tsugaike", name: "Tsugaike Kogen", bounds: box(36.78, 137.88, latSpan: 0.04, lonSpan: 0.04), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["Tsugaike Mountain Resort"]),
        ResortEntry(id: "rusutsu", name: "Rusutsu", bounds: box(42.76, 140.56, latSpan: 0.06, lonSpan: 0.07), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["Rusutsu Resort"]),
        ResortEntry(id: "furano", name: "Furano", bounds: box(43.34, 142.37, latSpan: 0.05, lonSpan: 0.06), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["Furano Ski Resort"]),
        ResortEntry(id: "myoko-suginohara", name: "Myoko Suginohara", bounds: box(36.87, 138.86, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["Myoko Suginohara Ski Resort"]),
        ResortEntry(id: "nekoma", name: "Nekoma Mountain", bounds: box(37.72, 139.96, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.epic], aliases: ["NEKOMA"]),

        // ── Australia (Epic) ──
        ResortEntry(id: "perisher", name: "Perisher", bounds: box(-36.40, 148.41, latSpan: 0.07, lonSpan: 0.08), region: "AU", country: "Australia", passProducts: [.epic]),
        ResortEntry(id: "falls-creek", name: "Falls Creek", bounds: box(-36.87, 147.28, latSpan: 0.05, lonSpan: 0.06), region: "AU", country: "Australia", passProducts: [.epic]),
        ResortEntry(id: "hotham", name: "Hotham", bounds: box(-36.98, 147.17, latSpan: 0.05, lonSpan: 0.06), region: "AU", country: "Australia", passProducts: [.epic]),
        ResortEntry(id: "mt-buller", name: "Mt Buller", bounds: box(-37.15, 146.44, latSpan: 0.05, lonSpan: 0.06), region: "AU", country: "Australia", passProducts: [.epic]),

        // ── South Korea (Epic) ──
        ResortEntry(id: "mona-yongpyong", name: "Mona Yongpyong", bounds: box(37.64, 128.68, latSpan: 0.04, lonSpan: 0.05), region: "KR", country: "South Korea", passProducts: [.epic]),

        // ── Europe — Switzerland (Epic) ──
        ResortEntry(id: "andermatt", name: "Andermatt-Sedrun-Disentis", bounds: box(46.63, 8.59, latSpan: 0.08, lonSpan: 0.15), region: "CH", country: "Switzerland", passProducts: [.epic]),
        ResortEntry(id: "crans-montana", name: "Crans-Montana", bounds: box(46.31, 7.48, latSpan: 0.06, lonSpan: 0.08), region: "CH", country: "Switzerland", passProducts: [.epic]),

        // ── Europe — Austria (Epic) ──
        ResortEntry(id: "arlberg", name: "Arlberg", bounds: box(47.13, 10.26, latSpan: 0.08, lonSpan: 0.15), region: "AT", country: "Austria", passProducts: [.epic], aliases: ["Ski Arlberg", "St. Anton"]),
        ResortEntry(id: "skicircus-saalbach", name: "Skicircus Saalbach", bounds: box(47.39, 12.64, latSpan: 0.08, lonSpan: 0.12), region: "AT", country: "Austria", passProducts: [.epic], aliases: ["Saalbach Hinterglemm"]),
        ResortEntry(id: "kitzsteinhorn", name: "Kitzsteinhorn", bounds: box(47.19, 12.68, latSpan: 0.05, lonSpan: 0.06), region: "AT", country: "Austria", passProducts: [.epic], aliases: ["Zell am See-Kaprun"]),
        ResortEntry(id: "hintertuxer", name: "Hintertuxer Gletscher", bounds: box(47.05, 11.67, latSpan: 0.05, lonSpan: 0.07), region: "AT", country: "Austria", passProducts: [.epic], aliases: ["Hintertux Glacier"]),
        ResortEntry(id: "mayrhofen", name: "Mayrhofen", bounds: box(47.14, 11.87, latSpan: 0.06, lonSpan: 0.08), region: "AT", country: "Austria", passProducts: [.epic]),
        ResortEntry(id: "silvretta-montafon", name: "Silvretta Montafon", bounds: box(46.98, 9.98, latSpan: 0.06, lonSpan: 0.08), region: "AT", country: "Austria", passProducts: [.epic]),
        ResortEntry(id: "soelden", name: "Sölden", bounds: box(46.97, 10.99, latSpan: 0.07, lonSpan: 0.08), region: "AT", country: "Austria", passProducts: [.epic]),

        // ── Europe — France (Epic) ──
        ResortEntry(id: "les-3-vallees", name: "Les 3 Vallées", bounds: box(45.33, 6.58, latSpan: 0.12, lonSpan: 0.16), region: "FR", country: "France", passProducts: [.epic], aliases: ["Courchevel", "Méribel", "Val Thorens"]),

        // ── Europe — Italy (Epic) ──
        ResortEntry(id: "skirama-dolomiti", name: "Skirama Dolomiti", bounds: box(46.23, 10.87, latSpan: 0.10, lonSpan: 0.14), region: "IT", country: "Italy", passProducts: [.epic], aliases: ["Madonna di Campiglio"]),
        ResortEntry(id: "monterosa", name: "Monterosa Ski", bounds: box(45.87, 7.85, latSpan: 0.06, lonSpan: 0.08), region: "IT", country: "Italy", passProducts: [.epic]),
    ]

    // MARK: ─────────────────── IKON (85) ───────────────────

    private static let ikonResorts: [ResortEntry] = [

        // ── USA — Colorado ──
        ResortEntry(id: "aspen-mountain", name: "Aspen Mountain", bounds: box(39.18, -106.82, latSpan: 0.05, lonSpan: 0.05), region: "CO", country: "USA", passProducts: [.ikon], preferredBearing: 5, preferredPitch: 62, preferredZoom: 13.5),
        ResortEntry(id: "aspen-highlands", name: "Aspen Highlands", bounds: box(39.18, -106.86, latSpan: 0.05, lonSpan: 0.05), region: "CO", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "buttermilk", name: "Buttermilk", bounds: box(39.20, -106.86, latSpan: 0.05, lonSpan: 0.05), region: "CO", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "snowmass", name: "Snowmass", bounds: box(39.21, -106.95, latSpan: 0.07, lonSpan: 0.08), region: "CO", country: "USA", passProducts: [.ikon], preferredBearing: 355, preferredPitch: 62, preferredZoom: 13.0),
        ResortEntry(id: "steamboat", name: "Steamboat", bounds: box(40.46, -106.80, latSpan: 0.08, lonSpan: 0.10), region: "CO", country: "USA", passProducts: [.ikon], preferredBearing: 350, preferredPitch: 62, preferredZoom: 12.5),
        ResortEntry(id: "winter-park", name: "Winter Park", bounds: box(39.88, -105.77, latSpan: 0.07, lonSpan: 0.08), region: "CO", country: "USA", passProducts: [.ikon], preferredBearing: 0, preferredPitch: 62, preferredZoom: 12.8),
        ResortEntry(id: "copper-mountain", name: "Copper Mountain", bounds: box(39.50, -106.15, latSpan: 0.06, lonSpan: 0.07), region: "CO", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "arapahoe-basin", name: "Arapahoe Basin", bounds: box(39.64, -105.87, latSpan: 0.04, lonSpan: 0.04), region: "CO", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "eldora", name: "Eldora Mountain", bounds: box(39.94, -105.58, latSpan: 0.04, lonSpan: 0.05), region: "CO", country: "USA", passProducts: [.ikon]),

        // ── USA — Utah ──
        ResortEntry(id: "deer-valley", name: "Deer Valley", bounds: box(40.62, -111.48, latSpan: 0.07, lonSpan: 0.08), region: "UT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "solitude", name: "Solitude", bounds: box(40.62, -111.59, latSpan: 0.05, lonSpan: 0.06), region: "UT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "alta", name: "Alta", bounds: box(40.59, -111.64, latSpan: 0.04, lonSpan: 0.05), region: "UT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "snowbird", name: "Snowbird", bounds: box(40.58, -111.66, latSpan: 0.05, lonSpan: 0.06), region: "UT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "brighton", name: "Brighton", bounds: box(40.60, -111.58, latSpan: 0.04, lonSpan: 0.05), region: "UT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "snowbasin", name: "Snowbasin", bounds: box(41.21, -111.86, latSpan: 0.06, lonSpan: 0.07), region: "UT", country: "USA", passProducts: [.ikon]),

        // ── USA — California ──
        ResortEntry(id: "northstar", name: "Northstar", bounds: box(39.28, -120.12, latSpan: 0.06, lonSpan: 0.07), region: "CA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "palisades-tahoe", name: "Palisades Tahoe", bounds: box(39.20, -120.24, latSpan: 0.08, lonSpan: 0.10), region: "CA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "sierra-at-tahoe", name: "Sierra-at-Tahoe", bounds: box(38.80, -120.08, latSpan: 0.05, lonSpan: 0.06), region: "CA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "mammoth", name: "Mammoth Mountain", bounds: box(37.64, -119.03, latSpan: 0.08, lonSpan: 0.09), region: "CA", country: "USA", passProducts: [.ikon], preferredBearing: 0, preferredPitch: 62, preferredZoom: 12.8),
        ResortEntry(id: "june-mountain", name: "June Mountain", bounds: box(37.77, -119.08, latSpan: 0.05, lonSpan: 0.06), region: "CA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "big-bear", name: "Big Bear Mountain Resort", bounds: box(34.24, -116.87, latSpan: 0.05, lonSpan: 0.07), region: "CA", country: "USA", passProducts: [.ikon], aliases: ["Bear Mountain", "Snow Summit"]),
        ResortEntry(id: "snow-valley", name: "Snow Valley", bounds: box(34.22, -117.04, latSpan: 0.04, lonSpan: 0.05), region: "CA", country: "USA", passProducts: [.ikon]),

        // ── USA — Idaho ──
        ResortEntry(id: "sun-valley", name: "Sun Valley", bounds: box(43.68, -114.34, latSpan: 0.06, lonSpan: 0.07), region: "ID", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "schweitzer", name: "Schweitzer", bounds: box(48.37, -116.62, latSpan: 0.06, lonSpan: 0.07), region: "ID", country: "USA", passProducts: [.ikon]),

        // ── USA — Montana ──
        ResortEntry(id: "big-sky", name: "Big Sky", bounds: box(45.28, -111.39, latSpan: 0.10, lonSpan: 0.12), region: "MT", country: "USA", passProducts: [.ikon], preferredBearing: 0, preferredPitch: 62, preferredZoom: 12.0),

        // ── USA — Wyoming ──
        ResortEntry(id: "jackson-hole", name: "Jackson Hole", bounds: box(43.59, -110.83, latSpan: 0.07, lonSpan: 0.08), region: "WY", country: "USA", passProducts: [.ikon], preferredBearing: 355, preferredPitch: 62, preferredZoom: 13.0),

        // ── USA — Washington ──
        ResortEntry(id: "crystal-mountain", name: "Crystal Mountain", bounds: box(46.93, -121.48, latSpan: 0.06, lonSpan: 0.07), region: "WA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "summit-at-snoqualmie", name: "The Summit at Snoqualmie", bounds: box(47.42, -121.41, latSpan: 0.06, lonSpan: 0.08), region: "WA", country: "USA", passProducts: [.ikon]),

        // ── USA — Alaska ──
        ResortEntry(id: "alyeska", name: "Alyeska", bounds: box(60.97, -149.10, latSpan: 0.06, lonSpan: 0.07), region: "AK", country: "USA", passProducts: [.ikon], aliases: ["Alyeska Resort"]),

        // ── USA — New Mexico ──
        ResortEntry(id: "taos", name: "Taos", bounds: box(36.59, -105.45, latSpan: 0.06, lonSpan: 0.07), region: "NM", country: "USA", passProducts: [.ikon], aliases: ["Taos Ski Valley"]),

        // ── USA — Vermont ──
        ResortEntry(id: "killington", name: "Killington", bounds: box(43.63, -72.80, latSpan: 0.08, lonSpan: 0.10), region: "VT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "pico", name: "Pico", bounds: box(43.66, -72.84, latSpan: 0.04, lonSpan: 0.05), region: "VT", country: "USA", passProducts: [.ikon], aliases: ["Pico Mountain"]),
        ResortEntry(id: "stratton", name: "Stratton", bounds: box(43.11, -72.91, latSpan: 0.05, lonSpan: 0.06), region: "VT", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "sugarbush", name: "Sugarbush", bounds: box(44.14, -72.89, latSpan: 0.06, lonSpan: 0.07), region: "VT", country: "USA", passProducts: [.ikon]),

        // ── USA — New Hampshire ──
        ResortEntry(id: "loon", name: "Loon Mountain", bounds: box(44.04, -71.62, latSpan: 0.05, lonSpan: 0.06), region: "NH", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "cranmore", name: "Cranmore", bounds: box(44.07, -71.09, latSpan: 0.04, lonSpan: 0.05), region: "NH", country: "USA", passProducts: [.ikon], aliases: ["Cranmore Mountain Resort"]),

        // ── USA — Maine ──
        ResortEntry(id: "sugarloaf", name: "Sugarloaf", bounds: box(45.03, -70.31, latSpan: 0.07, lonSpan: 0.08), region: "ME", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "sunday-river", name: "Sunday River", bounds: box(44.47, -70.86, latSpan: 0.07, lonSpan: 0.08), region: "ME", country: "USA", passProducts: [.ikon]),

        // ── USA — Massachusetts ──
        ResortEntry(id: "jiminy-peak", name: "Jiminy Peak", bounds: box(42.51, -73.28, latSpan: 0.04, lonSpan: 0.05), region: "MA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "butternut", name: "Butternut", bounds: box(42.18, -73.31, latSpan: 0.04, lonSpan: 0.05), region: "MA", country: "USA", passProducts: [.ikon], aliases: ["Ski Butternut"]),

        // ── USA — Michigan ──
        ResortEntry(id: "boyne-mountain", name: "Boyne Mountain", bounds: box(45.16, -84.92, latSpan: 0.04, lonSpan: 0.05), region: "MI", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "the-highlands", name: "The Highlands", bounds: box(45.47, -84.91, latSpan: 0.05, lonSpan: 0.06), region: "MI", country: "USA", passProducts: [.ikon], aliases: ["Boyne Highlands"]),

        // ── USA — Minnesota ──
        ResortEntry(id: "buck-hill", name: "Buck Hill", bounds: box(44.72, -93.28, latSpan: 0.03, lonSpan: 0.04), region: "MN", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "wild-mountain", name: "Wild Mountain", bounds: box(45.45, -92.72, latSpan: 0.03, lonSpan: 0.04), region: "MN", country: "USA", passProducts: [.ikon]),

        // ── USA — Pennsylvania ──
        ResortEntry(id: "camelback", name: "Camelback Resort", bounds: box(41.05, -75.35, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.ikon]),
        ResortEntry(id: "blue-mountain-pa", name: "Blue Mountain Resort", bounds: box(40.81, -75.52, latSpan: 0.04, lonSpan: 0.05), region: "PA", country: "USA", passProducts: [.ikon]),

        // ── USA — West Virginia ──
        ResortEntry(id: "snowshoe", name: "Snowshoe", bounds: box(38.41, -79.99, latSpan: 0.06, lonSpan: 0.07), region: "WV", country: "USA", passProducts: [.ikon]),

        // ── Canada — Alberta ──
        ResortEntry(id: "banff-sunshine", name: "Banff Sunshine", bounds: box(51.11, -115.76, latSpan: 0.07, lonSpan: 0.08), region: "AB", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "lake-louise", name: "Lake Louise", bounds: box(51.44, -116.16, latSpan: 0.07, lonSpan: 0.08), region: "AB", country: "Canada", passProducts: [.ikon]),

        // ── Canada — British Columbia ──
        ResortEntry(id: "revelstoke", name: "Revelstoke", bounds: box(50.96, -118.16, latSpan: 0.08, lonSpan: 0.09), region: "BC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "red-mountain", name: "RED Mountain", bounds: box(49.10, -117.84, latSpan: 0.06, lonSpan: 0.07), region: "BC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "cypress", name: "Cypress Mountain", bounds: box(49.40, -123.20, latSpan: 0.05, lonSpan: 0.06), region: "BC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "panorama", name: "Panorama", bounds: box(50.46, -116.24, latSpan: 0.05, lonSpan: 0.06), region: "BC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "sun-peaks", name: "Sun Peaks Resort", bounds: box(50.88, -119.89, latSpan: 0.06, lonSpan: 0.07), region: "BC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "silverstar", name: "SilverStar Mountain Resort", bounds: box(50.38, -119.06, latSpan: 0.06, lonSpan: 0.07), region: "BC", country: "Canada", passProducts: [.ikon]),

        // ── Canada — Ontario ──
        ResortEntry(id: "blue-mountain-on", name: "Blue Mountain", bounds: box(44.50, -80.31, latSpan: 0.05, lonSpan: 0.05), region: "ON", country: "Canada", passProducts: [.ikon]),

        // ── Canada — Quebec ──
        ResortEntry(id: "tremblant", name: "Tremblant", bounds: box(46.21, -74.59, latSpan: 0.06, lonSpan: 0.06), region: "QC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "le-massif", name: "Le Massif de Charlevoix", bounds: box(47.28, -70.54, latSpan: 0.06, lonSpan: 0.06), region: "QC", country: "Canada", passProducts: [.ikon]),
        ResortEntry(id: "mont-sainte-anne", name: "Mont-Sainte Anne", bounds: box(47.07, -70.90, latSpan: 0.06, lonSpan: 0.06), region: "QC", country: "Canada", passProducts: [.ikon]),

        // ── Japan (Ikon) ──
        ResortEntry(id: "niseko", name: "Niseko United", bounds: box(42.86, 140.69, latSpan: 0.07, lonSpan: 0.08), region: "JP", country: "Japan", passProducts: [.ikon]),
        ResortEntry(id: "hakuba-cortina", name: "Hakuba Cortina", bounds: box(36.79, 137.87, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.ikon]),
        ResortEntry(id: "lotte-arai", name: "Lotte Arai Resort", bounds: box(36.93, 138.18, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.ikon]),
        ResortEntry(id: "appi", name: "APPI Resort", bounds: box(39.93, 141.00, latSpan: 0.05, lonSpan: 0.06), region: "JP", country: "Japan", passProducts: [.ikon]),
        ResortEntry(id: "shiga-kogen", name: "Shiga Kogen", bounds: box(36.79, 138.52, latSpan: 0.06, lonSpan: 0.07), region: "JP", country: "Japan", passProducts: [.ikon]),
        ResortEntry(id: "mt-t", name: "Mt. T", bounds: box(36.68, 139.55, latSpan: 0.04, lonSpan: 0.05), region: "JP", country: "Japan", passProducts: [.ikon]),
        ResortEntry(id: "zao-onsen", name: "Zao Onsen", bounds: box(38.17, 140.40, latSpan: 0.05, lonSpan: 0.06), region: "JP", country: "Japan", passProducts: [.ikon]),

        // ── Australia (Ikon) ──
        ResortEntry(id: "thredbo", name: "Thredbo", bounds: box(-36.50, 148.30, latSpan: 0.05, lonSpan: 0.06), region: "AU", country: "Australia", passProducts: [.ikon]),

        // ── New Zealand (Ikon) ──
        ResortEntry(id: "coronet-peak", name: "Coronet Peak", bounds: box(-45.03, 168.73, latSpan: 0.05, lonSpan: 0.06), region: "NZ", country: "New Zealand", passProducts: [.ikon]),
        ResortEntry(id: "the-remarkables", name: "The Remarkables", bounds: box(-45.04, 168.81, latSpan: 0.05, lonSpan: 0.06), region: "NZ", country: "New Zealand", passProducts: [.ikon]),
        ResortEntry(id: "mt-hutt", name: "Mt Hutt", bounds: box(-43.48, 171.54, latSpan: 0.05, lonSpan: 0.06), region: "NZ", country: "New Zealand", passProducts: [.ikon]),

        // ── South Korea (Ikon) ──
        ResortEntry(id: "yunding", name: "Yunding Snow Park", bounds: box(40.97, 115.45, latSpan: 0.04, lonSpan: 0.05), region: "CN", country: "China", passProducts: [.ikon]),

        // ── Chile (Ikon) ──
        ResortEntry(id: "valle-nevado", name: "Valle Nevado", bounds: box(-33.36, -70.26, latSpan: 0.06, lonSpan: 0.07), region: "CL", country: "Chile", passProducts: [.ikon]),

        // ── Europe — Switzerland (Ikon) ──
        ResortEntry(id: "verbier", name: "Verbier 4 Vallées", bounds: box(46.10, 7.23, latSpan: 0.08, lonSpan: 0.12), region: "CH", country: "Switzerland", passProducts: [.ikon]),
        ResortEntry(id: "st-moritz", name: "St. Moritz", bounds: box(46.50, 9.84, latSpan: 0.06, lonSpan: 0.08), region: "CH", country: "Switzerland", passProducts: [.ikon]),
        ResortEntry(id: "zermatt", name: "Zermatt", bounds: box(46.02, 7.75, latSpan: 0.06, lonSpan: 0.08), region: "CH", country: "Switzerland", passProducts: [.ikon]),

        // ── Europe — Austria (Ikon) ──
        ResortEntry(id: "ischgl", name: "Ischgl", bounds: box(47.00, 10.29, latSpan: 0.06, lonSpan: 0.08), region: "AT", country: "Austria", passProducts: [.ikon], aliases: ["Silvretta Arena"]),
        ResortEntry(id: "kitzbuehel", name: "Kitzbühel", bounds: box(47.45, 12.39, latSpan: 0.06, lonSpan: 0.08), region: "AT", country: "Austria", passProducts: [.ikon]),

        // ── Europe — France (Ikon) ──
        ResortEntry(id: "chamonix", name: "Chamonix Mont-Blanc", bounds: box(45.92, 6.87, latSpan: 0.08, lonSpan: 0.10), region: "FR", country: "France", passProducts: [.ikon]),
        ResortEntry(id: "megeve", name: "Megève", bounds: box(45.86, 6.62, latSpan: 0.06, lonSpan: 0.08), region: "FR", country: "France", passProducts: [.ikon]),

        // ── Europe — Italy (Ikon) ──
        ResortEntry(id: "dolomiti-superski", name: "Dolomiti Superski", bounds: box(46.52, 11.77, latSpan: 0.12, lonSpan: 0.16), region: "IT", country: "Italy", passProducts: [.ikon]),
        ResortEntry(id: "cervino", name: "Cervino Ski Paradise", bounds: box(45.93, 7.63, latSpan: 0.06, lonSpan: 0.08), region: "IT", country: "Italy", passProducts: [.ikon], aliases: ["Breuil-Cervinia"]),
        ResortEntry(id: "courmayeur", name: "Courmayeur Mont Blanc", bounds: box(45.79, 6.95, latSpan: 0.06, lonSpan: 0.07), region: "IT", country: "Italy", passProducts: [.ikon]),
        ResortEntry(id: "la-thuile", name: "La Thuile - Espace San Bernardo", bounds: box(45.72, 6.95, latSpan: 0.05, lonSpan: 0.07), region: "IT", country: "Italy", passProducts: [.ikon]),
        ResortEntry(id: "pila", name: "Pila", bounds: box(45.72, 7.32, latSpan: 0.04, lonSpan: 0.05), region: "IT", country: "Italy", passProducts: [.ikon]),

        // ── Europe — Andorra (Ikon) ──
        ResortEntry(id: "grandvalira", name: "Grandvalira", bounds: box(42.55, 1.68, latSpan: 0.06, lonSpan: 0.10), region: "AD", country: "Andorra", passProducts: [.ikon]),
    ]

    // MARK: ─────────────────── Helpers ───────────────────

    static let regionOrder: [String] = [
        // North America
        "AK", "AB", "BC", "CA", "CO", "ID", "IN", "MA", "ME", "MI", "MN", "MO", "MT",
        "NH", "NM", "NY", "OH", "ON", "OR", "PA", "QC", "UT", "VT", "WA", "WI", "WV", "WY",
        // International
        "JP", "AU", "NZ", "KR", "CN", "CL",
        "AT", "CH", "FR", "IT", "AD",
    ]

    static var byRegion: [(region: String, resorts: [ResortEntry])] {
        let grouped = Dictionary(grouping: catalog, by: \.region)
        return regionOrder.compactMap { region in
            guard let resorts = grouped[region] else { return nil }
            return (region: region, resorts: resorts.sorted { $0.name < $1.name })
        }
    }

    static var epicOnly: [ResortEntry] {
        catalog.filter { $0.passProducts.contains(.epic) }
    }

    static var ikonOnly: [ResortEntry] {
        catalog.filter { $0.passProducts.contains(.ikon) }
    }

    static func search(_ query: String, pass: PassProduct? = nil) -> [ResortEntry] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.filter { entry in
            let passMatch = pass.map { entry.passProducts.contains($0) } ?? true
            let textMatch = normalized.isEmpty || entry.searchableText.contains(normalized)
            return passMatch && textMatch
        }
        .sorted { $0.name < $1.name }
    }
}

// MARK: - Map Status

/// Describes how complete the OSM trail/lift data is for a given resort.
enum MapStatus {
    case full        // Comprehensive map — nearly all trails + lifts mapped
    case partial     // Major runs present; some gaps or unnamed trails
    case comingSoon  // Little or no trail data in OSM — map roadmap item
}

extension ResortEntry {

    // ── Classification sets ──────────────────────────────────────────────
    // Logic: full → partial → comingSoon (default).
    // Anything NOT explicitly listed as full or partial falls through to
    // comingSoon, so new catalog entries are always safe/conservative.

    /// Resorts with comprehensive, verified OSM trail coverage.
    private static let fullMapIds: Set<String> = [
        // North America — flagship mountains
        "whistler", "vail", "breckenridge", "park-city", "keystone",
        "beaver-creek", "jackson-hole", "mammoth", "big-sky", "sun-valley",
        "stowe", "killington", "stratton", "sugarbush",
        "aspen-mountain", "aspen-highlands", "snowmass", "buttermilk",
        "steamboat", "winter-park", "copper-mountain", "arapahoe-basin",
        "telluride", "crested-butte",
        "snowbird", "alta", "deer-valley", "solitude", "brighton", "snowbasin",
        "northstar", "palisades-tahoe", "heavenly", "sierra-at-tahoe", "kirkwood",
        "crystal-mountain", "alyeska",
        "taos", "sugarloaf", "sunday-river",
        // Canada
        "banff-sunshine", "lake-louise", "revelstoke", "red-mountain",
        "panorama", "sun-peaks", "silverstar", "tremblant", "fernie",
        "kicking-horse", "kimberley",
        // Japan
        "niseko", "hakuba-happo-one", "furano", "rusutsu",
        // Europe — Alps
        "chamonix", "les-3-vallees", "verbier", "zermatt", "st-moritz",
        "ischgl", "kitzbuehel", "arlberg", "skicircus-saalbach",
        "kitzsteinhorn", "mayrhofen", "soelden", "hintertuxer", "silvretta-montafon",
        "andermatt", "crans-montana",
        "dolomiti-superski", "skirama-dolomiti", "cervino", "courmayeur", "la-thuile",
        "monterosa", "pila",
        "grandvalira", "megeve",
        // Southern Hemisphere
        "perisher", "falls-creek", "hotham",
        "coronet-peak", "the-remarkables", "mt-hutt",
    ]

    /// Resorts with some OSM trail data — major runs visible but gaps exist.
    private static let partialMapIds: Set<String> = [
        // USA — moderate OSM coverage
        "schweitzer", "mt-bachelor", "stevens-pass", "summit-at-snoqualmie",
        "loon", "cranmore", "okemo", "mount-snow", "attitash", "wildcat",
        "mount-sunapee", "hunter",
        "pico", "jiminy-peak", "butternut",
        "boyne-mountain", "the-highlands",
        "snowshoe",
        "camelback", "blue-mountain-pa",
        "june-mountain", "big-bear", "snow-valley",
        "eldora",
        // Canada — partial
        "cypress", "blue-mountain-on", "le-massif", "mont-sainte-anne",
        // Japan — major Hakuba resorts have some coverage
        "hakuba-goryu", "hakuba-iwatake", "hakuba47",
        "shiga-kogen",
        // Southern Hemisphere — partial
        "mt-buller", "thredbo",
        "valle-nevado",
    ]

    /// Map coverage classification for this resort.
    /// Default is .comingSoon — resorts must be explicitly opted up to partial or full.
    var mapStatus: MapStatus {
        if Self.fullMapIds.contains(id)    { return .full }
        if Self.partialMapIds.contains(id) { return .partial }
        return .comingSoon
    }
}
