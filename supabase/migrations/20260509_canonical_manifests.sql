-- Canonical resort manifests + immutable graph blobs.
--
-- Today the source of truth for trail / lift names + counts is bundled
-- per-resort JSON in `PowderMeet/Resources/ResortData/{resortId}.json`.
-- 142 of the 159 files are 4-line stubs (resortId + version only); the
-- 17 populated files (palisades-tahoe, whistler, mammoth, ...) carry the
-- only real ground truth, and even those ride along with the IPA. Two
-- devices on different app versions therefore build different graphs
-- from the same OSM snapshot. The "Curated overlay drift" target in
-- CLAUDE.md is exactly this.
--
-- This migration moves canonical truth to Postgres so:
--   1. build-resort-graph (server-side edge function) joins OSM geometry
--      to canonical_trail / canonical_lift rows + canonical_geometry_override
--      to produce a fully enriched, deterministic graph blob keyed by
--      (resort_id, manifest_version, snapshot_date, graph_version).
--   2. Devices fetch the immutable blob via get-resort-graph instead of
--      running CuratedResortLoader.applyOverlay locally. No async race,
--      no app-version drift.
--   3. Cache lives indefinitely between manifest_version bumps. When a
--      resort genuinely adds a lift / trail (rare), an operator runs the
--      canonical_ingest tool, applies a new manifest_version, and every
--      client picks up the new graph on next foreground.
--
-- Bumping discipline:
--   manifest_version bumps ONLY when reality changes (new lift, new run,
--   geometry correction, official name correction). Skimap.org typo
--   churn or Overpass node-id reshuffles do NOT bump it. The ingestion
--   tool surfaces noise for human review; only confirmed real-world
--   changes flow through `apply.py`.
--
-- Resolution priority for client load (CanonicalGraphFetcher.swift):
--   1. cached graph blob if cached_manifest_version == current_manifest_version
--   2. else download new blob, replace cache atomically
--
-- Server retains every historical manifest_version forever so a meet
-- request stamped with v3 can still be solved deterministically by both
-- devices even after the resort moves to v4.

-- ── resort_canonical_manifest ─────────────────────────────────────────
--
-- One row per (resort_id, manifest_version). Latest version per resort
-- exposed via `current_resort_canonical_manifest` view below.

create table if not exists public.resort_canonical_manifest (
  resort_id              text not null,
  manifest_version       int  not null,
  expected_trail_count   int  not null,
  expected_lift_count    int  not null,
  last_validated_at      timestamptz not null default now(),
  validator_notes        text,
  primary key (resort_id, manifest_version)
);

create or replace view public.current_resort_canonical_manifest as
  select distinct on (resort_id) *
  from public.resort_canonical_manifest
  order by resort_id, manifest_version desc;

alter table public.resort_canonical_manifest enable row level security;

drop policy if exists resort_canonical_manifest_public_read on public.resort_canonical_manifest;
create policy resort_canonical_manifest_public_read
  on public.resort_canonical_manifest
  for select
  to authenticated, anon
  using (true);

-- writes are service_role only (enforced by absence of insert/update/delete
-- policies for authenticated/anon — RLS denies by default).

-- ── canonical_trail ───────────────────────────────────────────────────
--
-- Mirrors CuratedTrail in PowderMeet/Services/CuratedResortData.swift.
-- osm_way_ids stored as text[] because GraphBuilder edge IDs use the
-- string form ("t123456") and CuratedResortLoader.stripEdgeIdToOSMId
-- compares string-to-string. canonical_geometry is the OSM-gap-fill:
-- when not null, build-resort-graph substitutes this LineString for
-- whatever OSM had (or didn't have) for this trail name.

create table if not exists public.canonical_trail (
  id                     uuid primary key default gen_random_uuid(),
  resort_id              text not null,
  manifest_version       int  not null,
  name                   text not null,
  difficulty             text,        -- green / blue / black / doubleBlack / terrainPark
  is_groomed             boolean,     -- tri-state: true / false / null = unknown
  has_moguls             boolean default false,
  is_gladed              boolean default false,
  length_m               double precision,
  vert_m                 double precision,
  osm_way_ids            text[] not null default '{}',
  canonical_geometry     geography(LineString, 4326),
  foreign key (resort_id, manifest_version)
    references public.resort_canonical_manifest (resort_id, manifest_version)
    on delete cascade
);

create index if not exists canonical_trail_resort_version_idx
  on public.canonical_trail (resort_id, manifest_version);
create index if not exists canonical_trail_geom_gix
  on public.canonical_trail using gist (canonical_geometry);

alter table public.canonical_trail enable row level security;

drop policy if exists canonical_trail_public_read on public.canonical_trail;
create policy canonical_trail_public_read
  on public.canonical_trail
  for select
  to authenticated, anon
  using (true);

-- ── canonical_lift ────────────────────────────────────────────────────
--
-- Mirrors CuratedLift. base_coord / top_coord let the geometry tool
-- snap an operator-drawn LineString to known endpoints when OSM lift
-- ways are missing or wrong. capacity / ride_time_s / wait minutes feed
-- EdgeAttributes directly; weekday / weekend split is preserved for
-- CuratedLift.currentWaitMinutes parity.

create table if not exists public.canonical_lift (
  id                     uuid primary key default gen_random_uuid(),
  resort_id              text not null,
  manifest_version       int  not null,
  name                   text not null,
  lift_type              text,        -- chairlift / gondola / funicular / tBar / ...
  capacity               int,
  ride_time_s            double precision,
  vertical_rise_m        double precision,
  weekday_wait_min       double precision,
  weekend_wait_min       double precision,
  base_coord             geography(Point, 4326),
  top_coord              geography(Point, 4326),
  osm_way_ids            text[] not null default '{}',
  canonical_geometry     geography(LineString, 4326),
  foreign key (resort_id, manifest_version)
    references public.resort_canonical_manifest (resort_id, manifest_version)
    on delete cascade
);

create index if not exists canonical_lift_resort_version_idx
  on public.canonical_lift (resort_id, manifest_version);
create index if not exists canonical_lift_geom_gix
  on public.canonical_lift using gist (canonical_geometry);

alter table public.canonical_lift enable row level security;

drop policy if exists canonical_lift_public_read on public.canonical_lift;
create policy canonical_lift_public_read
  on public.canonical_lift
  for select
  to authenticated, anon
  using (true);

-- ── canonical_geometry_override ───────────────────────────────────────
--
-- Append-only hand-traced geometry. Joined by (resort_id, target_kind,
-- target_name) so an override drawn against manifest v2 keeps applying
-- to v3 + v4 + ... until the operator either supersedes it (insert a
-- newer override row with the same name) or removes it (delete by id
-- via service_role tooling). build-resort-graph picks the most recent
-- override per (resort_id, kind, name) at build time.
--
-- Why a separate table from canonical_trail.canonical_geometry: the
-- override survives manifest_version bumps. canonical_trail rows are
-- copies-per-version so attribute history is preserved; geometry
-- overrides are operator-asserted ground truth that doesn't need to
-- be re-drawn each time a name or capacity changes.

create table if not exists public.canonical_geometry_override (
  id                            uuid primary key default gen_random_uuid(),
  resort_id                     text not null,
  target_kind                   text not null check (target_kind in ('trail', 'lift')),
  target_name                   text not null,
  geometry                      geography(LineString, 4326) not null,
  notes                         text,
  manifest_version_introduced   int not null,
  created_at                    timestamptz not null default now()
);

create index if not exists canonical_geometry_override_lookup_idx
  on public.canonical_geometry_override (resort_id, target_kind, target_name, created_at desc);
create index if not exists canonical_geometry_override_geom_gix
  on public.canonical_geometry_override using gist (geometry);

alter table public.canonical_geometry_override enable row level security;

drop policy if exists canonical_geometry_override_public_read on public.canonical_geometry_override;
create policy canonical_geometry_override_public_read
  on public.canonical_geometry_override
  for select
  to authenticated, anon
  using (true);

-- ── resort_graph_blob ─────────────────────────────────────────────────
--
-- Tracks immutable build outputs. PK includes graph_version so a Swift
-- schema bump (graphVersion = "v9") doesn't collide with v8 blobs of
-- the same (resort, manifest_version, snapshot_date). build-resort-graph
-- short-circuits to the existing signed URL if a row already matches.

create table if not exists public.resort_graph_blob (
  resort_id          text not null,
  manifest_version   int  not null,
  snapshot_date      date not null,
  graph_version      text not null,
  blob_storage_path  text not null,    -- e.g. "vail/3-2026-04-28-v8.json.gz"
  sha256             text not null,
  built_at           timestamptz not null default now(),
  primary key (resort_id, manifest_version, snapshot_date, graph_version),
  foreign key (resort_id, manifest_version)
    references public.resort_canonical_manifest (resort_id, manifest_version)
    on delete cascade
);

create index if not exists resort_graph_blob_resort_idx
  on public.resort_graph_blob (resort_id, built_at desc);

alter table public.resort_graph_blob enable row level security;

drop policy if exists resort_graph_blob_public_read on public.resort_graph_blob;
create policy resort_graph_blob_public_read
  on public.resort_graph_blob
  for select
  to authenticated, anon
  using (true);

-- ── Storage bucket ────────────────────────────────────────────────────
--
-- Mirror the resort-snapshots pattern: private bucket, signed URLs
-- minted by get-resort-graph for clients. Skip create if the bucket
-- already exists (idempotent re-runs during local dev).

insert into storage.buckets (id, name, public)
values ('resort-graphs', 'resort-graphs', false)
on conflict (id) do nothing;

-- ── RPC helpers (read-only projections for build-resort-graph) ────────
--
-- Edge functions consume these instead of selecting from canonical_*
-- directly so PostGIS conversion (geography → GeoJSON text) happens
-- server-side. SECURITY INVOKER + RLS public-read above means anon
-- callers see the same rows they'd see via direct select; the RPCs
-- exist purely to avoid baking ST_AsGeoJSON into the TS layer.

create or replace function public.canonical_trails_with_geom(
  p_resort_id text,
  p_manifest_version int
)
returns table (
  id uuid,
  name text,
  difficulty text,
  is_groomed boolean,
  has_moguls boolean,
  is_gladed boolean,
  length_m double precision,
  vert_m double precision,
  osm_way_ids text[],
  canonical_geometry text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    id, name, difficulty, is_groomed, has_moguls, is_gladed,
    length_m, vert_m, osm_way_ids,
    case when canonical_geometry is null
         then null
         else st_asgeojson(canonical_geometry)
    end
  from public.canonical_trail
  where resort_id = p_resort_id
    and manifest_version = p_manifest_version
$$;

create or replace function public.canonical_lifts_with_geom(
  p_resort_id text,
  p_manifest_version int
)
returns table (
  id uuid,
  name text,
  lift_type text,
  capacity int,
  ride_time_s double precision,
  vertical_rise_m double precision,
  weekday_wait_min double precision,
  weekend_wait_min double precision,
  base_coord text,
  top_coord text,
  osm_way_ids text[],
  canonical_geometry text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    id, name, lift_type, capacity, ride_time_s, vertical_rise_m,
    weekday_wait_min, weekend_wait_min,
    case when base_coord is null then null else st_asgeojson(base_coord) end,
    case when top_coord  is null then null else st_asgeojson(top_coord)  end,
    osm_way_ids,
    case when canonical_geometry is null
         then null
         else st_asgeojson(canonical_geometry)
    end
  from public.canonical_lift
  where resort_id = p_resort_id
    and manifest_version = p_manifest_version
$$;

-- Most-recent override per (resort, kind, name). DISTINCT ON over a
-- created_at desc sort gives latest-wins semantics — operators can
-- supersede an earlier override by inserting a fresher row with the
-- same (resort, kind, name).
create or replace function public.latest_geometry_overrides(
  p_resort_id text
)
returns table (
  target_kind text,
  target_name text,
  geometry text,
  manifest_version_introduced int
)
language sql
stable
security invoker
set search_path = public
as $$
  select distinct on (target_kind, target_name)
    target_kind, target_name,
    st_asgeojson(geometry),
    manifest_version_introduced
  from public.canonical_geometry_override
  where resort_id = p_resort_id
  order by target_kind, target_name, created_at desc
$$;
