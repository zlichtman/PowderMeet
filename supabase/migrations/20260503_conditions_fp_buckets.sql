-- Phase 2.1 — bucketed conditions in profile_edge_speeds.
--
-- `profile_edge_speeds` already had `conditions_fp text` as part of
-- its primary key (default 'default'), but the recompute RPC
-- collapsed every observation into the 'default' bucket — the column
-- existed only as a forward-compatibility stub. This migration:
--
--   1. Adds `conditions_fp text not null default 'default'` to
--      `imported_runs` so future inserts can carry the bucket per row.
--      Defaulting to 'default' keeps the existing rows valid; the
--      importer overrides only when authoritative weather state is
--      available at insert time.
--
--   2. Updates `recompute_profile_edge_speeds(uid)` to aggregate by
--      `(resort_id, edge_id, conditions_fp)` so each bucket gets its
--      own rolling-average row. Old rows with default fp continue to
--      land in the 'default' bucket — no data is lost.
--
-- Solver selection (`UserProfile.traverseTime` choosing the matching
-- bucket given current conditions) is a separate PR — this just
-- unblocks the data collection so future PRs have material.

alter table public.imported_runs
  add column if not exists conditions_fp text not null default 'default';

create index if not exists imported_runs_profile_conditions_fp_idx
  on public.imported_runs (profile_id, conditions_fp);

create or replace function public.recompute_profile_edge_speeds(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  delete from public.profile_edge_speeds where profile_id = uid;
  insert into public.profile_edge_speeds (
    profile_id, resort_id, edge_id, conditions_fp,
    observation_count,
    rolling_speed_ms, rolling_peak_ms, rolling_duration_s,
    last_observed_at
  )
  select
    uid,
    coalesce(resort_id, 'unknown'),
    edge_id,
    coalesce(conditions_fp, 'default'),
    count(*)::int,
    avg(speed_ms),
    max(coalesce(peak_speed_ms, speed_ms)),
    avg(duration_s),
    max(run_at)
  from public.imported_runs
  where profile_id = uid
    and edge_id is not null
  group by resort_id, edge_id, conditions_fp;
end;
$function$;
