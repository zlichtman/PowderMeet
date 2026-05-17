-- Per-edge skill memory.
--
-- Phase 2 of the import → algorithm loop. The bucketed-difficulty average
-- (profile.speed_blue, etc.) collapses every blue run a skier has ever
-- skied into one number, which means "I went faster on Run X today" gets
-- diluted across N other blue runs and the next prediction barely moves.
--
-- This table caches per-(profile, resort, edge) rolling speeds so the
-- solver can read directly: same edge, same conditions fingerprint →
-- direct lookup, no smoothing through unrelated edges. The cache is
-- recomputed from `imported_runs` (ground truth) after every import,
-- so deletes / re-imports / restores all converge to the same values.
--
-- conditions_fp is a stable string built from edge attributes
-- ('moguls=true|groomed=false|gladed=false'). Future enrichments will
-- extend it with weather state — for now the framework is in place
-- without changing the runtime contract.

create table if not exists public.profile_edge_speeds (
  profile_id        uuid not null references public.profiles(id) on delete cascade,
  resort_id         text not null,
  edge_id           text not null,
  conditions_fp     text not null default 'default',
  observation_count int  not null default 0,
  rolling_speed_ms  double precision not null default 0,
  rolling_peak_ms   double precision,
  rolling_duration_s double precision not null default 0,
  last_observed_at  timestamptz not null default now(),
  primary key (profile_id, resort_id, edge_id, conditions_fp)
);

create index if not exists profile_edge_speeds_profile_idx
  on public.profile_edge_speeds (profile_id);
create index if not exists profile_edge_speeds_profile_resort_idx
  on public.profile_edge_speeds (profile_id, resort_id);

alter table public.profile_edge_speeds enable row level security;

drop policy if exists profile_edge_speeds_owner on public.profile_edge_speeds;
create policy profile_edge_speeds_owner on public.profile_edge_speeds
  for all to authenticated
  using (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

-- Recompute aggregates from the source of truth (`imported_runs`). Called
-- by the importer after `recompute_profile_stats` and during backup
-- restore. Atomic delete + insert keeps the table consistent even if a
-- previous import wrote stale rows for edges that were later deleted.
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
    'default' as conditions_fp,
    count(*)::int,
    avg(speed_ms),
    max(coalesce(peak_speed_ms, speed_ms)),
    avg(duration_s),
    max(run_at)
  from public.imported_runs
  where profile_id = uid
    and edge_id is not null;
end;
$function$;
