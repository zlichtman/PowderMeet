-- Imported-runs production hardening: nullable enrichment fields + provenance.
--
-- The product contract is "X runs in your Slopes/Strava/Garmin file → X runs
-- on your profile." Before this migration:
--
--   1. `imported_runs.edge_id` was NOT NULL — the importer dropped any run
--      that didn't snap to a graph edge. Files at resorts outside the
--      catalog imported zero rows. Files at supported resorts whose lines
--      missed our bearing/distance threshold lost ~5% of runs silently.
--
--   2. `imported_runs.difficulty` was NOT NULL — same problem, since
--      difficulty came from the matched edge.
--
--   3. There was no provenance column. Multi-source imports (the same day
--      logged in Slopes AND Strava) couldn't be distinguished or filtered.
--      Re-uploading the same file required hashing every existing row's
--      edge+timestamp tuple to detect duplicates.
--
-- This migration:
--
--   * Drops NOT NULL on edge_id and difficulty so unmatched / no-graph
--     runs can persist with the source-measured stats only.
--   * Adds `source` ('slopes' | 'gpx' | 'tcx' | 'fit') so the viewer can
--     show provenance and the importer can keep cross-source duplicates
--     when the user uploads the same activity from two apps.
--   * Adds `source_file_hash` (sha256 of the original file bytes) so the
--     importer can fast-skip whole-file re-uploads without parsing.
--   * Adds an index on (profile_id, dedup_hash) for the per-batch dedup
--     lookup the importer does for every row before upserting.
--
-- recompute_profile_stats(uid) aggregates by profile_id over count, sum
-- (vertical_m, distance_m, duration_s), max (peak_speed_ms, max_grade_deg).
-- It never references edge_id or difficulty, so no RPC change is required.

alter table public.imported_runs
  alter column edge_id    drop not null,
  alter column difficulty drop not null,
  add column if not exists source           text,
  add column if not exists source_file_hash text;

create index if not exists imported_runs_profile_dedup_idx
  on public.imported_runs (profile_id, dedup_hash);

create index if not exists imported_runs_profile_source_hash_idx
  on public.imported_runs (profile_id, source_file_hash)
  where source_file_hash is not null;

-- Dedup hash convention going forward (set by ActivityImporter):
--   matched run    → "<source>|<minute_floor(start_time)>|<resort_id>|<edge_id>"
--   unmatched run  → "<source>|<minute_floor(start_time)>|<resort_id>|unmatched"
--
-- Minute-floor (not second) absorbs millisecond-granularity drift between
-- two re-exports of the same activity. Including <source> means the same
-- activity uploaded from two apps (e.g. Slopes + Strava) keeps both rows
-- — by user request, false-positive dedup that collapses distinct
-- activities is worse than two rows the user can manually delete.
