-- Lifetime "average speed" — aligned with the way Slopes shows it on
-- their lifetime tile.
--
-- We previously displayed `total_distance_m / total_duration_s`, which is
-- mathematically a duration-weighted lifetime average. Slopes' on-app
-- lifetime "Avg Speed" is instead the mean of per-run averages
-- (Slopes' Metadata.xml stamps each `<Action type="Run">` with an
-- `averageSpeed` attribute and the lifetime tile averages those values
-- equally). The two formulas can disagree by 1–3 mph for skiers whose
-- run lengths vary day to day.
--
-- New `profile_stats.avg_speed_ms` column holds the same mean-of-means
-- so the UI reads one value and matches Slopes 1:1.

alter table public.profile_stats
  add column if not exists avg_speed_ms double precision;

create or replace function public.recompute_profile_stats(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profile_stats as ps (
    profile_id, days_skied, runs_count, vertical_m,
    top_speed_ms, total_duration_s, total_distance_m, top_grade_deg,
    avg_speed_ms,
    last_import_at, updated_at
  )
  select
    uid,
    coalesce(count(distinct date_trunc('day', run_at)), 0)::int,
    coalesce(count(*), 0)::int,
    coalesce(sum(vertical_m), 0),
    coalesce(max(coalesce(peak_speed_ms, speed_ms)), 0),
    coalesce(sum(duration_s), 0),
    coalesce(sum(distance_m), 0),
    coalesce(max(max_grade_deg), 0),
    -- Mean-of-per-run-averages, only over rows that actually have a
    -- recorded speed. NULLIF guards against an all-zero edge case
    -- (legacy rows pre-import-pipeline, never expected in practice).
    coalesce(avg(nullif(speed_ms, 0)), 0),
    max(run_at),
    now()
  from public.imported_runs
  where profile_id = uid
  on conflict (profile_id) do update set
    days_skied        = excluded.days_skied,
    runs_count        = excluded.runs_count,
    vertical_m        = excluded.vertical_m,
    top_speed_ms      = excluded.top_speed_ms,
    total_duration_s  = excluded.total_duration_s,
    total_distance_m  = excluded.total_distance_m,
    top_grade_deg     = excluded.top_grade_deg,
    avg_speed_ms      = excluded.avg_speed_ms,
    last_import_at    = excluded.last_import_at,
    updated_at        = now();
end;
$function$;
