-- Learn personalized pace from the exact graph edge timed by GPS, never by
-- copying one physical run's average onto every edge in its matched sequence.
-- The physical run remains one imported_runs row for history/stats/dedup.

create or replace function public.valid_edge_pace_observations(payload jsonb)
returns boolean
language plpgsql
immutable
strict
set search_path to 'public'
as $function$
declare
  observation jsonb;
  observation_edge_id text;
  observation_conditions_fp text;
  observation_speed double precision;
  observation_peak double precision;
  observation_duration double precision;
  observation_distance double precision;
  seen_edge_ids text[] := array[]::text[];
begin
  if jsonb_typeof(payload) <> 'array'
     or jsonb_array_length(payload) > 10000 then
    return false;
  end if;

  for observation in
    select value from jsonb_array_elements(payload)
  loop
    if jsonb_typeof(observation) <> 'object'
       or not observation ?& array[
         'edge_id',
         'conditions_fp',
         'speed_ms',
         'peak_speed_ms',
         'duration_s',
         'distance_m'
       ]
       or jsonb_typeof(observation->'edge_id') <> 'string'
       or jsonb_typeof(observation->'conditions_fp') <> 'string'
       or jsonb_typeof(observation->'speed_ms') <> 'number'
       or jsonb_typeof(observation->'peak_speed_ms') <> 'number'
       or jsonb_typeof(observation->'duration_s') <> 'number'
       or jsonb_typeof(observation->'distance_m') <> 'number' then
      return false;
    end if;

    observation_edge_id := btrim(observation->>'edge_id');
    observation_conditions_fp := btrim(observation->>'conditions_fp');
    observation_speed := (observation->>'speed_ms')::double precision;
    observation_peak := (observation->>'peak_speed_ms')::double precision;
    observation_duration := (observation->>'duration_s')::double precision;
    observation_distance := (observation->>'distance_m')::double precision;

    if observation_edge_id = ''
       or length(observation_edge_id) > 512
       or observation_conditions_fp = ''
       or length(observation_conditions_fp) > 1024
       or observation_edge_id = any(seen_edge_ids)
       or observation_speed <= 0
       or observation_speed > 30
       or observation_peak < observation_speed
       or observation_peak > 45
       or observation_duration <= 0
       or observation_duration > 86400
       or observation_distance <= 0
       or observation_distance > 10000000 then
      return false;
    end if;

    seen_edge_ids := array_append(seen_edge_ids, observation_edge_id);
  end loop;

  return true;
exception
  when others then
    -- Cast overflow or malformed wire values fail closed at ingress.
    return false;
end;
$function$;

create or replace function public.edge_pace_observations_match_segments(
  payload jsonb,
  segment_ids text[]
)
returns boolean
language sql
immutable
strict
set search_path to 'public'
as $function$
  select case
    when jsonb_typeof(payload) <> 'array' then false
    else not exists (
      select 1
      from jsonb_array_elements(payload) as observation
      where nullif(btrim(observation->>'edge_id'), '') is null
         or not (btrim(observation->>'edge_id') = any(segment_ids))
    )
  end
$function$;

alter table public.imported_runs
  add column if not exists edge_observations jsonb not null default '[]'::jsonb;

alter table public.imported_runs
  drop constraint if exists imported_runs_edge_observations_valid;
alter table public.imported_runs
  add constraint imported_runs_edge_observations_valid
  check (
    public.valid_edge_pace_observations(edge_observations)
    and public.edge_pace_observations_match_segments(
      edge_observations,
      matched_segment_ids
    )
  );

comment on column public.imported_runs.edge_observations is
  'Edge-local pace evidence. Multi-edge runs train only from these GPS-attributed intervals; empty remains display/stat history only.';

create or replace function public.recompute_profile_edge_speeds(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  tau_days constant double precision := 60.0 / ln(2.0);
begin
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
