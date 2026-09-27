-- Owner-scoped activity data.
--
-- imported_runs carried `imported_runs_select_public` (USING true for every
-- role, including anon): anyone holding the public anon key could read every
-- user's ski runs. The app only ever reads its own rows and its comments
-- already assumed owner-only RLS; this makes the database agree.
--
-- recompute_profile_stats(uuid) and recompute_profile_edge_speeds(uuid) are
-- SECURITY DEFINER and were executable by anon with no caller check, so any
-- client could make the server delete and rebuild another user's derived
-- rows. Each now requires the caller to be that user. service_role and
-- direct database sessions (operators, pg_cron) are unaffected. Apart from
-- the guard, both bodies are unchanged from 20260430004931 and
-- 20260810000500.

begin;

drop policy if exists imported_runs_select_public on public.imported_runs;
drop policy if exists imported_runs_select_own on public.imported_runs;
create policy imported_runs_select_own
  on public.imported_runs
  for select
  to authenticated
  using ((select auth.uid()) = profile_id);

create or replace function public.assert_activity_owner(uid uuid)
returns void
language plpgsql
stable
set search_path to 'public'
as $function$
begin
  -- PostgREST always sets a JWT role (anon / authenticated / service_role);
  -- a session without one is a direct database connection.
  if auth.role() is null or auth.role() = 'service_role' then
    return;
  end if;
  if auth.uid() is null or auth.uid() <> uid then
    raise exception 'permission denied: activity data belongs to another user'
      using errcode = '42501';
  end if;
end;
$function$;

revoke all on function public.assert_activity_owner(uuid) from public, anon, authenticated;

create or replace function public.recompute_profile_stats(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.assert_activity_owner(uid);

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

create or replace function public.recompute_profile_edge_speeds(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  tau_days constant double precision := 60.0 / ln(2.0);
begin
  perform public.assert_activity_owner(uid);

  delete from public.profile_edge_speeds where profile_id = uid;

  insert into public.profile_edge_speeds (
    profile_id, resort_id, edge_id, conditions_fp, dataset_version,
    equipment_key,
    observation_count,
    rolling_speed_ms, rolling_peak_ms, rolling_duration_s,
    rolling_speed_variance_ms2,
    last_observed_at
  )
  with eligible as (
    select
      r.*,
      r.dataset_version as observation_dataset_version,
      coalesce(r.equipment_id_at_activity::text, 'neutral') as observation_equipment_key
    from public.imported_runs r
    where r.profile_id = uid
      and r.match_confidence >= 0.75
      and nullif(btrim(r.dataset_version), '') is not null
      and cardinality(r.matched_segment_ids) > 0
      and not exists (
        select 1
        from unnest(r.matched_segment_ids) as segment_id
        where nullif(btrim(segment_id), '') is null
      )
  ),
  latest_dataset as (
    select distinct on (coalesce(resort_id, 'unknown'))
      coalesce(resort_id, 'unknown') as resort_id,
      observation_dataset_version
    from eligible
    order by
      coalesce(resort_id, 'unknown'),
      created_at desc,
      observation_dataset_version asc
  ),
  precise as (
    select
      coalesce(e.resort_id, 'unknown') as resort_id,
      observation.edge_id,
      observation.conditions_fp,
      e.observation_dataset_version as dataset_version,
      e.observation_equipment_key as equipment_key,
      observation.speed_ms,
      observation.peak_speed_ms,
      observation.duration_s,
      e.run_at
    from eligible e
    join latest_dataset latest
      on latest.resort_id = coalesce(e.resort_id, 'unknown')
     and latest.observation_dataset_version = e.observation_dataset_version
    cross join lateral (
      select
        btrim(item->>'edge_id') as edge_id,
        btrim(item->>'conditions_fp') as conditions_fp,
        (item->>'speed_ms')::double precision as speed_ms,
        (item->>'peak_speed_ms')::double precision as peak_speed_ms,
        (item->>'duration_s')::double precision as duration_s
      from jsonb_array_elements(e.edge_observations) as item

      union all

      -- Backward compatibility is truthful only for a one-edge run. An old
      -- multi-edge row without exact timing remains visible but cannot train.
      select
        e.matched_segment_ids[1],
        coalesce(nullif(btrim(e.conditions_fp), ''), 'default'),
        e.speed_ms,
        case
          when e.peak_speed_ms >= e.speed_ms and e.peak_speed_ms <= 45
            then e.peak_speed_ms
          else e.speed_ms
        end,
        e.duration_s
      where jsonb_array_length(e.edge_observations) = 0
        and cardinality(e.matched_segment_ids) = 1
        and e.speed_ms > 0
        and e.speed_ms <= 30
        and e.duration_s > 0
        and e.duration_s <= 86400
    ) as observation
    where observation.edge_id = any(e.matched_segment_ids)
  ),
  weighted as (
    select
      precise.*,
      exp(
        -greatest(0, extract(epoch from (now() - precise.run_at)) / 86400.0)
        / tau_days
      ) as w
    from precise
  ),
  agg as (
    select
      resort_id, edge_id, conditions_fp, dataset_version, equipment_key,
      count(*)::int as obs_count,
      sum(speed_ms * w) / nullif(sum(w), 0) as weighted_mean_speed,
      sum(power(speed_ms, 2) * w) / nullif(sum(w), 0) as weighted_mean_sq_speed,
      max(peak_speed_ms) as peak_speed,
      sum(duration_s * w) / nullif(sum(w), 0) as weighted_mean_duration,
      max(run_at) as last_seen
    from weighted
    group by
      resort_id, edge_id, conditions_fp, dataset_version, equipment_key
  )
  select
    uid,
    resort_id, edge_id, conditions_fp, dataset_version, equipment_key,
    obs_count,
    coalesce(weighted_mean_speed, 0),
    peak_speed,
    coalesce(weighted_mean_duration, 0),
    greatest(
      0,
      coalesce(weighted_mean_sq_speed, 0)
        - power(coalesce(weighted_mean_speed, 0), 2)
    ),
    last_seen
  from agg;
end;
$function$;

revoke all on function public.recompute_profile_stats(uuid) from public, anon;
revoke all on function public.recompute_profile_edge_speeds(uuid) from public, anon;
grant execute on function public.recompute_profile_stats(uuid) to authenticated, service_role;
grant execute on function public.recompute_profile_edge_speeds(uuid) to authenticated, service_role;

commit;
