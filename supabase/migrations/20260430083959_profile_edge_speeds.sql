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
$function$;;
