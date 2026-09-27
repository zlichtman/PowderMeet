-- Operator-authored, manifest-bound safe meetup landmarks.
--
-- A row anchors human copy (lodge, patrol, signed meeting zone) to a stable
-- OSM source vertex used by the graph builder. The builder resolves the wire
-- node as `src:<anchor_osm_node_id>` and fails the complete graph build if the
-- anchor is missing, duplicated, incompatible, or outside score bounds.

create table if not exists public.canonical_rendezvous_point (
  resort_id          text not null,
  manifest_version   int not null,
  anchor_osm_node_id bigint not null check (anchor_osm_node_id > 0),
  kind               text not null check (
    kind in ('liftBase', 'midStation', 'signedMeetingArea', 'lodge', 'patrol')
  ),
  display_name       text not null check (
    length(btrim(display_name)) between 1 and 80
  ),
  confidence         double precision not null default 1
    check (confidence between 0 and 1),
  quality            double precision not null default 0.9
    check (quality between 0 and 1),
  notes              text,
  primary key (resort_id, manifest_version, anchor_osm_node_id),
  foreign key (resort_id, manifest_version)
    references public.resort_canonical_manifest (resort_id, manifest_version)
    on delete cascade
);

create index if not exists canonical_rendezvous_manifest_idx
  on public.canonical_rendezvous_point (resort_id, manifest_version);

alter table public.canonical_rendezvous_point enable row level security;

drop policy if exists canonical_rendezvous_public_read
  on public.canonical_rendezvous_point;
create policy canonical_rendezvous_public_read
  on public.canonical_rendezvous_point
  for select
  to authenticated, anon
  using (true);

-- Atomic operator replacement for one staged manifest. JSON rows:
-- { anchor_osm_node_id, kind, display_name, confidence?, quality?, notes? }
create or replace function public.replace_canonical_rendezvous_points(
  p_resort_id text,
  p_manifest_version int,
  p_points jsonb
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_point jsonb;
  v_count int := 0;
begin
  if not exists (
    select 1
    from public.resort_canonical_manifest
    where resort_id = p_resort_id
      and manifest_version = p_manifest_version
  ) then
    raise exception 'canonical manifest does not exist';
  end if;

  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    raise exception 'p_points must be a JSON array';
  end if;

  delete from public.canonical_rendezvous_point
   where resort_id = p_resort_id
     and manifest_version = p_manifest_version;

  for v_point in select * from jsonb_array_elements(p_points)
  loop
    insert into public.canonical_rendezvous_point (
      resort_id,
      manifest_version,
      anchor_osm_node_id,
      kind,
      display_name,
      confidence,
      quality,
      notes
    ) values (
      p_resort_id,
      p_manifest_version,
      (v_point->>'anchor_osm_node_id')::bigint,
      v_point->>'kind',
      btrim(v_point->>'display_name'),
      coalesce((v_point->>'confidence')::double precision, 1),
      coalesce((v_point->>'quality')::double precision, 0.9),
      v_point->>'notes'
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.replace_canonical_rendezvous_points(text, int, jsonb)
  from public, anon, authenticated;
grant execute on function public.replace_canonical_rendezvous_points(text, int, jsonb)
  to service_role;
