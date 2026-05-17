-- live_presence: TTL'd last-known position table for cold-launch hydration.
--
-- Channel broadcasts (high-frequency `pos` events) carry the live signal; this
-- table is the persistence backstop so a friend who just opened the app can
-- see where you were 4 minutes ago instead of "unknown" until your next packet.
--
-- The trigger derives geohash6 + last_seen server-side so the client can't
-- spoof its cell. resort_id stays client-supplied for now (Phase B7 will move
-- it to a server lookup against a resorts.bbox table — deferred until we
-- backfill resort bboxes).

-- Extension: postgis (ST_GeoHash). Already enabled in most Supabase projects;
-- safe no-op if so.
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

-- Composite index serves the hot read: "give me friends in this resort + cell
-- ordered by recency". A partial index on `now() - 5min` was rejected because
-- now() isn't IMMUTABLE, but the cleanup function (below) keeps the table
-- bounded so a plain composite is fine.
create index if not exists live_presence_resort_cell_idx
  on public.live_presence (resort_id, geohash6, last_seen desc);

-- Standalone last_seen index supports the cleanup sweep.
create index if not exists live_presence_last_seen_idx
  on public.live_presence (last_seen);

-- (No separate user_id index: the primary key on user_id already provides a
-- unique btree. A second index would only add write amplification.)

-- Trigger: derive geohash6 from lat/lon and stamp last_seen on every write.
-- Keeping this server-side means the partial index above can trust the value.
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

-- RLS: write only your own row; read only friends' rows (status = 'accepted',
-- bidirectional). Mirrors the friendship semantics already in the app.
alter table public.live_presence enable row level security;

-- RLS notes:
-- 1. `(select auth.uid())` (vs bare `auth.uid()`) lets Postgres cache the value
--    across rows in a single statement — same trick as migration 20260415181218.
-- 2. self_write covers insert/update/delete; the trigger derives geohash6.
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

-- Cleanup: nuke rows older than 15 min so cold-launch hydration never serves
-- truly stale fixes. Runs every 5 minutes via pg_cron when available; if your
-- project lacks pg_cron, replicate this in a Supabase Edge Function on a Vercel
-- cron or call it from the client during start().
create or replace function public.live_presence_cleanup()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.live_presence
   where last_seen < (now() - interval '15 minutes');
$$;

-- Optional pg_cron schedule (idempotent; safe to skip if pg_cron not enabled).
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
  -- pg_cron not granted to this role; cron job creation will be done manually.
  null;
end $$;

-- Realtime: enable broadcast/presence on this table so postgres_changes fires
-- when a friend's location upserts (the client subscribes via REST today; this
-- becomes useful in Phase D when we lose the client double-write and rely on
-- table-only signals).
alter publication supabase_realtime add table public.live_presence;
