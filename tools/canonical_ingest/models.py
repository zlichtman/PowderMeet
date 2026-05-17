"""Shared dataclasses for the canonical_ingest pipeline.

Mirrors the Postgres schema in
`supabase/migrations/20260509_canonical_manifests.sql`.

Wire format intent:
  - Coordinates are (lon, lat) tuples to match GeoJSON / PostGIS.
  - Geometry LineStrings are list[(lon, lat)] without z.
  - osm_way_ids are strings to match GraphBuilder's edge-id format
    ("t123456" → "123456" after stripEdgeIdToOSMId in CuratedResortData.swift).
  - difficulty values use the Swift `RunDifficulty` raw values
    (green / blue / black / doubleBlack / terrainPark).
  - lift_type values use the Swift `LiftType` raw values
    (chairlift / gondola / funicular / tBar / etc).
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, List, Tuple, Literal, Dict


Coord = Tuple[float, float]   # (lon, lat)
LineString = List[Coord]


@dataclass(frozen=True)
class CanonicalTrail:
    name: str
    difficulty: Optional[str] = None
    is_groomed: Optional[bool] = None
    has_moguls: bool = False
    is_gladed: bool = False
    length_m: Optional[float] = None
    vert_m: Optional[float] = None
    osm_way_ids: Tuple[str, ...] = ()
    canonical_geometry: Optional[LineString] = None


@dataclass(frozen=True)
class CanonicalLift:
    name: str
    lift_type: Optional[str] = None
    capacity: Optional[int] = None
    ride_time_s: Optional[float] = None
    vertical_rise_m: Optional[float] = None
    weekday_wait_min: Optional[float] = None
    weekend_wait_min: Optional[float] = None
    base_coord: Optional[Coord] = None
    top_coord: Optional[Coord] = None
    osm_way_ids: Tuple[str, ...] = ()
    canonical_geometry: Optional[LineString] = None


@dataclass(frozen=True)
class CanonicalManifest:
    resort_id: str
    expected_trail_count: int
    expected_lift_count: int
    trails: Tuple[CanonicalTrail, ...] = ()
    lifts: Tuple[CanonicalLift, ...] = ()
    validator_notes: Optional[str] = None


@dataclass(frozen=True)
class SourceItem:
    """A single trail or lift entry as observed from one source.

    `kind` identifies the type; `confidence` is the source's own
    confidence in this item being a real / official element (Skimap
    has high confidence for tagged-and-named ways; Overpass alone has
    lower confidence for nameless ways).
    """
    kind: Literal["trail", "lift"]
    name: str
    confidence: float = 1.0
    geometry: Optional[LineString] = None
    osm_way_ids: Tuple[str, ...] = ()
    extra: Dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class SourceResult:
    """The full result of one source fetcher per resort."""
    source: str                      # "skimap" / "openskimap" / "overpass" / "official"
    resort_id: str
    items: Tuple[SourceItem, ...] = ()
    fetched_at: Optional[str] = None  # ISO-8601


@dataclass
class DraftManifest:
    """Mutable working copy produced by reconcile.py.

    Each row tracks which sources agreed on the name and the operator's
    decision (accept / reject / rename). `apply.py` reads the
    final-state DraftManifest and writes confirmed rows into Postgres.
    """
    resort_id: str
    expected_trail_count: int
    expected_lift_count: int
    trail_rows: List["DraftRow"] = field(default_factory=list)
    lift_rows: List["DraftRow"] = field(default_factory=list)
    validator_notes: Optional[str] = None


@dataclass
class DraftRow:
    name: str
    kind: Literal["trail", "lift"]
    sources_seen: Tuple[str, ...] = ()
    confidence: float = 0.0
    accepted: bool = False
    geometry: Optional[LineString] = None
    osm_way_ids: Tuple[str, ...] = ()
    notes: Optional[str] = None
