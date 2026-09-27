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
$function$;;
