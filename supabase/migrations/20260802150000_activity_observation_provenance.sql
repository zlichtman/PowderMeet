-- Versioned activity/run observations.
--
-- Stable segment sequences replace the legacy one-edge attribution. Only
-- high-confidence, version-coherent matches are allowed into per-edge skill
-- memory. Existing strict edge_id rows are retained as legacy observations.

alter table public.imported_runs
  add column if not exists dataset_version text,
  add column if not exists matched_segment_ids text[] not null default '{}',
  add column if not exists match_confidence double precision not null default 0,
  add column if not exists match_method text not null default 'legacy_unmatched',
  add column if not exists equipment_id_at_activity uuid,
  add column if not exists raw_source_identity text;

alter table public.imported_runs
  drop constraint if exists imported_runs_match_confidence_check;
alter table public.imported_runs
  add constraint imported_runs_match_confidence_check
  check (match_confidence >= 0 and match_confidence <= 1);

update public.imported_runs
set matched_segment_ids = array[edge_id],
    match_confidence = 1,
    match_method = 'legacy_strict',
    raw_source_identity = coalesce(raw_source_identity, source_file_hash)
where edge_id is not null
  and cardinality(matched_segment_ids) = 0;

update public.imported_runs
set raw_source_identity = source_file_hash
where raw_source_identity is null;

create index if not exists imported_runs_profile_dataset_idx
  on public.imported_runs (profile_id, resort_id, dataset_version);
create index if not exists imported_runs_matched_segments_gin_idx
  on public.imported_runs using gin (matched_segment_ids);

alter table public.profile_edge_speeds
  add column if not exists dataset_version text not null default 'legacy';

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
    observation_count,
    rolling_speed_ms, rolling_peak_ms, rolling_duration_s,
    rolling_speed_variance_ms2,
    last_observed_at
  )
  with eligible as (
    select
      r.*,
      coalesce(r.dataset_version, 'legacy') as observation_dataset_version
    from public.imported_runs r
    where r.profile_id = uid
      and r.match_confidence >= 0.75
      and cardinality(r.matched_segment_ids) > 0
  ),
  latest_dataset as (
    -- Keep one coherent identity per resort. `created_at` reflects which
    -- dataset the client most recently used even for an old GPX activity.
    select distinct on (coalesce(resort_id, 'unknown'))
      coalesce(resort_id, 'unknown') as resort_id,
      observation_dataset_version
    from eligible
    order by coalesce(resort_id, 'unknown'), created_at desc
  ),
  weighted as (
    select
      coalesce(e.resort_id, 'unknown') as resort_id,
      segment.edge_id,
      coalesce(e.conditions_fp, 'default') as conditions_fp,
      e.observation_dataset_version as dataset_version,
      e.speed_ms,
      coalesce(e.peak_speed_ms, e.speed_ms) as peak_speed_ms,
      e.duration_s / greatest(cardinality(e.matched_segment_ids), 1) as duration_s,
      e.run_at,
      exp(-greatest(0, extract(epoch from (now() - e.run_at)) / 86400.0) / tau_days) as w
    from eligible e
    join latest_dataset latest
      on latest.resort_id = coalesce(e.resort_id, 'unknown')
     and latest.observation_dataset_version = e.observation_dataset_version
    cross join lateral unnest(e.matched_segment_ids) as segment(edge_id)
  ),
  agg as (
    select
      resort_id, edge_id, conditions_fp, dataset_version,
      count(*)::int as obs_count,
      sum(speed_ms * w) / nullif(sum(w), 0) as weighted_mean_speed,
      sum(power(speed_ms, 2) * w) / nullif(sum(w), 0) as weighted_mean_sq_speed,
      max(peak_speed_ms) as peak_speed,
      sum(duration_s * w) / nullif(sum(w), 0) as weighted_mean_duration,
      max(run_at) as last_seen
    from weighted
    group by resort_id, edge_id, conditions_fp, dataset_version
  )
  select
    uid,
    resort_id, edge_id, conditions_fp, dataset_version,
    obs_count,
    coalesce(weighted_mean_speed, 0),
    peak_speed,
    coalesce(weighted_mean_duration, 0),
    greatest(0, coalesce(weighted_mean_sq_speed, 0) - power(coalesce(weighted_mean_speed, 0), 2)),
    last_seen
  from agg;
end;
$function$;
