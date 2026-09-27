-- Stage canonical manifests until one exact, successfully-built graph blob is
-- explicitly published. `apply_canonical_manifest` remains the immutable
-- manifest writer; this migration removes its old side effect of making the
-- newest row immediately visible to clients.

begin;

-- A publication must stay tied to the exact metadata row that was built.
-- Including both the hash and storage path in this referenced key prevents a
-- later upsert from silently changing the bytes or path behind a publication.
alter table public.resort_graph_blob
  add constraint resort_graph_blob_exact_identity_unique
  unique (
    resort_id, manifest_version, snapshot_date, graph_version,
    sha256, blob_storage_path
  );

create table if not exists public.resort_canonical_publication (
  resort_id          text not null,
  manifest_version   int not null,
  graph_version      text not null,
  snapshot_date      date not null,
  content_sha256     text not null,
  blob_storage_path  text not null,
  published_at       timestamptz not null default now(),
  primary key (
    resort_id, manifest_version, snapshot_date, graph_version, content_sha256
  ),
  foreign key (resort_id, manifest_version)
    references public.resort_canonical_manifest (resort_id, manifest_version)
    on delete restrict,
  foreign key (
    resort_id, manifest_version, snapshot_date, graph_version,
    content_sha256, blob_storage_path
  )
    references public.resort_graph_blob
      (
        resort_id, manifest_version, snapshot_date, graph_version,
        sha256, blob_storage_path
      )
    on delete restrict,
  check (manifest_version > 0),
  check (graph_version ~ '^v[0-9]+(-s[0-9]+)?$'),
  check (content_sha256 ~ '^[0-9a-f]{64}$'),
  check (btrim(blob_storage_path) <> '')
);

create table if not exists public.resort_canonical_active (
  resort_id          text primary key,
  manifest_version   int not null,
  graph_version      text not null,
  snapshot_date      date not null,
  content_sha256     text not null,
  activated_at       timestamptz not null default now(),
  foreign key (
    resort_id, manifest_version, snapshot_date, graph_version, content_sha256
  )
    references public.resort_canonical_publication
      (
        resort_id, manifest_version, snapshot_date, graph_version,
        content_sha256
      )
    on delete restrict
);

create index if not exists resort_canonical_publication_lookup_idx
  on public.resort_canonical_publication
    (resort_id, manifest_version, graph_version, published_at desc);

alter table public.resort_canonical_publication enable row level security;
alter table public.resort_canonical_active enable row level security;

revoke all on table public.resort_canonical_publication
  from public, anon, authenticated;
revoke all on table public.resort_canonical_active
  from public, anon, authenticated;

drop policy if exists resort_canonical_publication_public_read
  on public.resort_canonical_publication;
create policy resort_canonical_publication_public_read
  on public.resort_canonical_publication
  for select to authenticated, anon using (true);

drop policy if exists resort_canonical_active_public_read
  on public.resort_canonical_active;
create policy resort_canonical_active_public_read
  on public.resort_canonical_active
  for select to authenticated, anon using (true);

grant select on public.resort_canonical_publication to authenticated, anon;
grant select on public.resort_canonical_active to authenticated, anon;

-- Preserve any already-operational dataset, but never backfill a manifest
-- that lacks graph metadata. The latest manifest with a real blob becomes the
-- active pointer; newer unbuilt manifests become staged automatically.
with candidates as (
  select distinct on (m.resort_id)
    m.resort_id,
    m.manifest_version,
    b.graph_version,
    b.snapshot_date,
    b.sha256 as content_sha256,
    b.blob_storage_path
  from public.resort_canonical_manifest m
  join public.resort_graph_blob b
    on b.resort_id = m.resort_id
   and b.manifest_version = m.manifest_version
  where b.sha256 ~ '^[0-9a-f]{64}$'
    and btrim(b.blob_storage_path) <> ''
  order by
    m.resort_id, m.manifest_version desc,
    b.snapshot_date desc, b.built_at desc, b.graph_version desc
)
insert into public.resort_canonical_publication (
  resort_id, manifest_version, graph_version, snapshot_date,
  content_sha256, blob_storage_path
)
select
  resort_id, manifest_version, graph_version, snapshot_date,
  content_sha256, blob_storage_path
from candidates
on conflict do nothing;

insert into public.resort_canonical_active (
  resort_id, manifest_version, graph_version, snapshot_date, content_sha256
)
select
  resort_id, manifest_version, graph_version, snapshot_date, content_sha256
from public.resort_canonical_publication
on conflict (resort_id) do update set
  manifest_version = excluded.manifest_version,
  graph_version = excluded.graph_version,
  snapshot_date = excluded.snapshot_date,
  content_sha256 = excluded.content_sha256,
  activated_at = now();

create or replace view public.current_resort_canonical_manifest as
select
  m.*,
  a.graph_version as published_graph_version,
  a.content_sha256 as published_content_sha256,
  p.snapshot_date as published_snapshot_date,
  p.blob_storage_path as published_blob_storage_path,
  p.published_at,
  a.activated_at
from public.resort_canonical_active a
join public.resort_canonical_manifest m
  on m.resort_id = a.resort_id
 and m.manifest_version = a.manifest_version
join public.resort_canonical_publication p
  on p.resort_id = a.resort_id
 and p.manifest_version = a.manifest_version
 and p.snapshot_date = a.snapshot_date
 and p.graph_version = a.graph_version
 and p.content_sha256 = a.content_sha256;

grant select on public.current_resort_canonical_manifest
  to authenticated, anon;

create or replace function public.publish_canonical_manifest(
  p_resort_id text,
  p_manifest_version int,
  p_graph_version text,
  p_snapshot_date date,
  p_content_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_manifest public.resort_canonical_manifest%rowtype;
  v_blob public.resort_graph_blob%rowtype;
  v_trail_count int;
  v_lift_count int;
begin
  if p_resort_id is null or btrim(p_resort_id) = '' then
    raise exception 'resort_id is required';
  end if;
  if p_manifest_version is null or p_manifest_version <= 0 then
    raise exception 'manifest_version must be positive';
  end if;
  if p_graph_version is null
     or p_graph_version !~ '^v[0-9]+(-s[0-9]+)?$' then
    raise exception 'invalid graph_version';
  end if;
  if p_snapshot_date is null then
    raise exception 'snapshot_date is required';
  end if;
  if p_content_sha256 is null
     or p_content_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'content_sha256 must be a lowercase SHA-256';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_resort_id, 0));

  select * into v_manifest
  from public.resort_canonical_manifest
  where resort_id = p_resort_id
    and manifest_version = p_manifest_version
  for update;
  if not found then
    raise exception 'canonical manifest % v% does not exist',
      p_resort_id, p_manifest_version;
  end if;

  select count(*) into v_trail_count
  from public.canonical_trail
  where resort_id = p_resort_id
    and manifest_version = p_manifest_version;
  select count(*) into v_lift_count
  from public.canonical_lift
  where resort_id = p_resort_id
    and manifest_version = p_manifest_version;
  if v_trail_count <> v_manifest.expected_trail_count
     or v_lift_count <> v_manifest.expected_lift_count then
    raise exception
      'canonical identity counts changed after staging: expected %/% loaded %/%',
      v_manifest.expected_trail_count, v_manifest.expected_lift_count,
      v_trail_count, v_lift_count;
  end if;

  if exists (
    select 1 from public.canonical_trail
    where resort_id = p_resort_id
      and manifest_version = p_manifest_version
      and btrim(name) = ''
  ) or exists (
    select 1 from public.canonical_lift
    where resort_id = p_resort_id
      and manifest_version = p_manifest_version
      and btrim(name) = ''
  ) then
    raise exception 'canonical identities contain an empty name';
  end if;

  if (
    select count(*) <> count(distinct lower(btrim(name)))
    from public.canonical_trail
    where resort_id = p_resort_id
      and manifest_version = p_manifest_version
  ) or (
    select count(*) <> count(distinct lower(btrim(name)))
    from public.canonical_lift
    where resort_id = p_resort_id
      and manifest_version = p_manifest_version
  ) then
    raise exception 'canonical identity names are not unique';
  end if;

  select * into v_blob
  from public.resort_graph_blob
  where resort_id = p_resort_id
    and manifest_version = p_manifest_version
    and graph_version = p_graph_version
    and snapshot_date = p_snapshot_date
    and sha256 = p_content_sha256
  limit 1;
  if not found then
    raise exception
      'exact built graph blob does not exist for % v% % % %',
      p_resort_id, p_manifest_version, p_graph_version,
      p_snapshot_date, p_content_sha256;
  end if;
  if btrim(v_blob.blob_storage_path) = '' then
    raise exception 'built graph blob has an empty storage path';
  end if;

  insert into public.resort_canonical_publication (
    resort_id, manifest_version, graph_version, snapshot_date,
    content_sha256, blob_storage_path
  ) values (
    p_resort_id, p_manifest_version, p_graph_version, p_snapshot_date,
    p_content_sha256, v_blob.blob_storage_path
  )
  on conflict do nothing;

  insert into public.resort_canonical_active (
    resort_id, manifest_version, graph_version, snapshot_date, content_sha256
  ) values (
    p_resort_id, p_manifest_version, p_graph_version, p_snapshot_date,
    p_content_sha256
  )
  on conflict (resort_id) do update set
    manifest_version = excluded.manifest_version,
    graph_version = excluded.graph_version,
    snapshot_date = excluded.snapshot_date,
    content_sha256 = excluded.content_sha256,
    activated_at = now();

  return jsonb_build_object(
    'resort_id', p_resort_id,
    'manifest_version', p_manifest_version,
    'graph_version', p_graph_version,
    'snapshot_date', p_snapshot_date,
    'content_sha256', p_content_sha256,
    'blob_storage_path', v_blob.blob_storage_path
  );
end;
$$;

revoke all on function public.publish_canonical_manifest(
  text, int, text, date, text
) from public, anon, authenticated;
grant execute on function public.publish_canonical_manifest(
  text, int, text, date, text
) to service_role;

commit;
