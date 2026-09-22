// Shared types: rows fetched from canonical_trail / canonical_lift via
// the canonical_*_with_geom RPCs (see migration 20260509). These shapes
// are the wire format build-resort-graph hands to applyCuratedOverlay.

export interface CanonicalTrail {
  id: string;
  name: string;
  difficulty: string | null;        // green / blue / black / doubleBlack / terrainPark
  is_groomed: boolean | null;       // tri-state
  has_moguls: boolean;
  is_gladed: boolean;
  length_m: number | null;
  vert_m: number | null;
  osm_way_ids: string[];
  canonical_geometry: string | null;  // GeoJSON LineString text
}

export interface CanonicalLift {
  id: string;
  name: string;
  lift_type: string | null;
  capacity: number | null;
  ride_time_s: number | null;
  vertical_rise_m: number | null;
  weekday_wait_min: number | null;
  weekend_wait_min: number | null;
  base_coord: string | null;        // GeoJSON Point text
  top_coord: string | null;
  osm_way_ids: string[];
  canonical_geometry: string | null;
}

export interface GeometryOverride {
  target_kind: "trail" | "lift";
  target_name: string;
  geometry: string;                 // GeoJSON LineString text
  manifest_version_introduced: number;
}
