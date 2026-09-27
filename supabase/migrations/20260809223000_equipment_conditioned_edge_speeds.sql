-- Keep learned edge speeds separated by the ski actually used.
--
-- `imported_runs.equipment_id_at_activity` is intentionally NULL for
-- historical files whose exporter cannot prove equipment. Live recordings
-- stamp the selected catalog ski. Collapsing both cases into one edge/
-- conditions row made response order decide which ski survived on the client,
-- and the solver then applied today's equipment model on top of a pace that
-- could already contain that same ski's effect.

alter table public.profile_edge_speeds
  add column if not exists equipment_key text not null default 'neutral';

alter table public.profile_edge_speeds
  drop constraint if exists profile_edge_speeds_equipment_key_check;
alter table public.profile_edge_speeds
  add constraint profile_edge_speeds_equipment_key_check
  check (
    equipment_key = 'neutral'
    or equipment_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  );

alter table public.profile_edge_speeds
  drop constraint if exists profile_edge_speeds_pkey;
alter table public.profile_edge_speeds
  add constraint profile_edge_speeds_pkey primary key (
    profile_id,
    resort_id,
    edge_id,
    conditions_fp,
    equipment_key
  );

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
      and r.speed_ms > 0
      and r.speed_ms <= 30
      and r.duration_s > 0
      and r.duration_s <= 86400
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
  weighted as (
    select
      coalesce(e.resort_id, 'unknown') as resort_id,
      segment.edge_id,
      coalesce(e.conditions_fp, 'default') as conditions_fp,
      e.observation_dataset_version as dataset_version,
      e.observation_equipment_key as equipment_key,
      e.speed_ms,
      case
        when e.peak_speed_ms >= e.speed_ms and e.peak_speed_ms <= 45
          then e.peak_speed_ms
        else e.speed_ms
      end as peak_speed_ms,
      e.duration_s / greatest(cardinality(e.matched_segment_ids), 1) as duration_s,
      e.run_at,
      exp(
        -greatest(0, extract(epoch from (now() - e.run_at)) / 86400.0)
        / tau_days
      ) as w
    from eligible e
    join latest_dataset latest
      on latest.resort_id = coalesce(e.resort_id, 'unknown')
     and latest.observation_dataset_version = e.observation_dataset_version
    cross join lateral unnest(e.matched_segment_ids) as segment(edge_id)
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
