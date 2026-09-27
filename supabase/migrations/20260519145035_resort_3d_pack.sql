create table if not exists public.resort_3d_pack (
  resort_id        text        not null,
  pack_version     text        not null,
  manifest_version integer     not null default 0,
  snapshot_date    text        not null default 'static',
  storage_path     text        not null,
  sha256           text        not null,
  byte_size        bigint      not null,
  built_at         timestamptz not null default now(),
  primary key (resort_id, pack_version, manifest_version, snapshot_date)
);

alter table public.resort_3d_pack enable row level security;

-- Public read of metadata only (mirrors resort_snapshot_pins); the
-- .usdz blob itself stays signed-URL gated in the private bucket.
drop policy if exists resort_3d_pack_public_read on public.resort_3d_pack;
create policy resort_3d_pack_public_read
  on public.resort_3d_pack for select
  to anon, authenticated
  using (true);

-- Writes are service-role only (no policy → RLS denies anon/auth;
-- service role bypasses RLS, like the canonical pipeline upload).
;
