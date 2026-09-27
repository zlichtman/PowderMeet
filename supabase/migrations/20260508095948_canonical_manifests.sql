-- Canonical resort manifests + immutable graph blobs.
--
-- See supabase/migrations/20260509_canonical_manifests.sql for full
-- header rationale. Summary: moves canonical truth (trail / lift names,
-- counts, geometry, attributes) from IPA-bundled JSON whitelists to
-- Postgres + immutable graph blobs in Storage so two devices on
-- different app versions cannot diverge.

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

create table if not exists public.canonical_trail (
  id                     uuid primary key default gen_random_uuid(),
  resort_id              text not null,
  manifest_version       int  not null,
  name                   text not null,
  difficulty             text,
  is_groomed             boolean,
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

create table if not exists public.canonical_lift (
  id                     uuid primary key default gen_random_uuid(),
  resort_id              text not null,
  manifest_version       int  not null,
  name                   text not null,
  lift_type              text,
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

create table if not exists public.resort_graph_blob (
  resort_id          text not null,
  manifest_version   int  not null,
  snapshot_date      date not null,
  graph_version      text not null,
  blob_storage_path  text not null,
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

insert into storage.buckets (id, name, public)
values ('resort-graphs', 'resort-graphs', false)
on conflict (id) do nothing;

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
$$;;
