"""Shared dataclasses for reconciliation.

Way ids are strings, difficulty and lift type use the bundle's enum values
(specs/02-DOMAIN.md section 2).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Literal, Optional, Tuple


@dataclass(frozen=True)
class SourceItem:
    """A single trail or lift as observed by one source."""

    kind: Literal["trail", "lift"]
    name: str
    confidence: float = 1.0
    osm_way_ids: Tuple[str, ...] = ()
    extra: Dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class SourceResult:
    """Everything one source says about one resort.

    `candidate` sources expose routable source geometry; `inventory` sources are
    operator-published identity lists.
    """

    source: str  # "official" | "openskimap" | "osm"
    resort_id: str
    role: Literal["candidate", "inventory"] = "candidate"
    items: Tuple[SourceItem, ...] = ()
    fetched_at: Optional[str] = None


@dataclass
class Identity:
    """One reconciled trail or lift: every source row that shares its exact
    normalized name, with what the sources agreed and disagreed on."""

    name: str
    kind: Literal["trail", "lift"]
    sources_seen: Tuple[str, ...] = ()
    confidence: float = 0.0
    difficulty: Optional[str] = None
    is_groomed: Optional[bool] = None
    lift_type: Optional[str] = None
    capacity: Optional[int] = None
    ride_time_s: Optional[float] = None
    osm_way_ids: Tuple[str, ...] = ()
    source_name_variants: Tuple[str, ...] = ()
    source_names: Dict[str, Tuple[str, ...]] = field(default_factory=dict)
    source_segment_counts: Dict[str, int] = field(default_factory=dict)
    source_attribute_observations: Dict[str, Dict[str, Tuple[str, ...]]] = field(default_factory=dict)
    identity_decision_ids: Tuple[str, ...] = ()
    unresolved_conflicts: Tuple[str, ...] = ()
