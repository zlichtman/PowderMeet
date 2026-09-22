create extension if not exists postgis;

create table if not exists public.live_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  resort_id text not null,
  lat double precision not null,
  lon double precision not null,
  altitude_m double precision,
  speed_mps double precision,
  heading_deg double precision,
  accuracy_m double precision,
  geohash6 text not null,
  captured_at timestamptz not null,
  last_seen timestamptz not null default now()
);

create index if not exists live_presence_resort_cell_idx
  on public.live_presence (resort_id, geohash6, last_seen desc);

create index if not exists live_presence_last_seen_idx
  on public.live_presence (last_seen);

create index if not exists live_presence_user_idx
  on public.live_presence (user_id);

create or replace function public.live_presence_compute()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  new.geohash6 := substr(st_geohash(st_setsrid(st_makepoint(new.lon, new.lat), 4326), 6), 1, 6);
  new.last_seen := now();
  return new;
end;
$$;

drop trigger if exists live_presence_compute_trg on public.live_presence;
create trigger live_presence_compute_trg
  before insert or update of lat, lon on public.live_presence
  for each row execute function public.live_presence_compute();

alter table public.live_presence enable row level security;

drop policy if exists live_presence_self_write on public.live_presence;
create policy live_presence_self_write on public.live_presence
  for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists live_presence_friend_read on public.live_presence;
create policy live_presence_friend_read on public.live_presence
  for select
  using (
    exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and (
          (f.requester_id = (select auth.uid()) and f.addressee_id = live_presence.user_id)
          or (f.addressee_id = (select auth.uid()) and f.requester_id = live_presence.user_id)
        )
    )
  );

create or replace function public.live_presence_cleanup()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.live_presence
   where last_seen < (now() - interval '15 minutes');
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'live_presence_cleanup_5m',
      '*/5 * * * *',
      $cron$ select public.live_presence_cleanup() $cron$
    );
  end if;
exception when others then
  null;
end $$;

alter publication supabase_realtime add table public.live_presence;;
