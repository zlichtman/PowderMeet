-- Persist the resolved trail name on each imported_runs row.
--
-- The viewer used to re-resolve trail names live from the currently-loaded
-- graph (via edge_id). That falls apart any time the resort isn't loaded
-- right now: open the imported-runs list while a different resort is
-- selected, or before any resort has loaded on cold launch, and you saw
-- difficulty pills only.
--
-- Storing the name as resolved at import-time means historical rows keep
-- their human-readable label regardless of current map state.

alter table public.imported_runs
  add column if not exists trail_name text;
