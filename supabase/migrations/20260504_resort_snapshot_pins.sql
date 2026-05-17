-- Server-driven canonical pinned snapshot dates per resort.
--
-- Until this table existed, `ResortEntry.defaultPinnedSnapshotDate`
-- was a hardcoded constant in the iOS IPA. Two devices on different
-- app versions therefore held different defaults and built different
-- graphs from the same OSM source. The receiver-side
-- "DIFFERENT TRAIL MAP" confirm catches this AFTER the fact; this
-- table prevents it FROM the start by making the canonical pin
-- date a server-controlled value every device fetches at startup.
--
-- Resolution priority (client-side):
--   1. resort_snapshot_pins[resort_id]                — per-resort server override
--   2. resort_snapshot_pins['__catalog__']            — catalog-wide server default
--   3. ResortEntry.pinnedSnapshotDate (baked)         — per-resort IPA override
--   4. ResortEntry.defaultPinnedSnapshotDate (baked)  — IPA-baked fallback
--
-- The baked defaults remain the offline fallback for the very-first
-- cold launch (no UserDefaults cache yet) and for offline launches.
-- Successful fetches cache to UserDefaults; subsequent cold launches
-- use the cached server pins until the next refresh.
--
-- To bump everyone, update the '__catalog__' row. To bump a single
-- resort, upsert a per-resort row.

create table if not exists public.resort_snapshot_pins (
  resort_id     text primary key,
  snapshot_date text not null,
  updated_at    timestamptz not null default now()
);

alter table public.resort_snapshot_pins enable row level security;

drop policy if exists resort_snapshot_pins_public_read on public.resort_snapshot_pins;
create policy resort_snapshot_pins_public_read
  on public.resort_snapshot_pins
  for select
  to authenticated, anon
  using (true);

-- Seed catalog-wide pin to today's baked default. Bump this single
-- row to re-pin all 159 resorts in one move.
insert into public.resort_snapshot_pins (resort_id, snapshot_date)
values ('__catalog__', '2026-04-28')
on conflict (resort_id) do nothing;
