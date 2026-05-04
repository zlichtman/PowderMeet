-- Peak instantaneous speed per imported run.
--
-- Before this migration, `imported_runs.speed_ms` held each run's MOVING
-- AVERAGE (totalDistance / totalMovingTime, pauses excluded), and
-- `profile_stats.top_speed_ms` was `max(speed_ms)`. That meant the value
-- shown on the profile as "TOP SPEED" was the fastest single-run AVERAGE,
-- which for any real skier comes in below their actual peak — a 6-file
-- import showed an external app's average of 15.8 mph but a "top speed" of
-- only 12 mph.
--
-- New column `peak_speed_ms` stores a 3-sample-smoothed, GPS-noise-capped
-- peak per run (computed client-side in TrailMatcher.peakSpeed). The
-- aggregator now maxes that. Old rows have NULL → coalesce to speed_ms so
-- they degrade to the previous behavior instead of zeroing out.

alter table public.imported_runs
  add column if not exists peak_speed_ms double precision;

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
    last_import_at    = excluded.last_import_at,
    updated_at        = now();
end;
$function$;
