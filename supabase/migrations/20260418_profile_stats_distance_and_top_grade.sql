-- Distance + top-grade columns on imported_runs, mirrored into profile_stats.
-- Already applied to the remote DB via Supabase MCP on 2026-04-18 — this file
-- exists so `supabase db pull`/`db push` stays coherent with server state.
--
-- distance_m    — horizontal length of the matched edge, meters.
-- max_grade_deg — peak slope angle along the edge, degrees. Matches units of
--                 MountainGraph.EdgeAttributes.maxGradient (capped at 60°).

alter table public.imported_runs
  add column if not exists distance_m    double precision not null default 0,
  add column if not exists max_grade_deg double precision not null default 0;

alter table public.profile_stats
  add column if not exists total_distance_m double precision not null default 0,
  add column if not exists top_grade_deg    double precision not null default 0;

-- Extend the aggregator. Additive: preserves every prior field and writes the
-- two new ones on insert + on-conflict update.
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
    coalesce(max(speed_ms), 0),
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
