"""canonical_ingest — multi-source resort manifest ingestion.

Pulls trail / lift counts and names from independent sources
(Skimap.org, OpenSkiMap, Overpass, official resort feeds), reconciles
them into a single canonical manifest per resort, and applies the
result to Postgres tables `resort_canonical_manifest`,
`canonical_trail`, and `canonical_lift`.

The reconciliation rule that matters most: a count disagreement
between sources never auto-resolves. The operator confirms against the
resort's official site (or another trusted source), or the conflict
surfaces for review. Silent wrong counts are exactly what this pipeline
exists to eliminate.

Tiers:
  sources/   — per-source fetchers. Pure read; no DB writes.
  reconcile  — name normalization + cross-source matching.
  geometry_tool — interactive override authoring (Phase 11).
  apply      — push confirmed manifest into Postgres via Supabase.
  cli        — `python -m canonical_ingest <subcommand> <resort_id>`.
"""

__version__ = "0.1.0"
