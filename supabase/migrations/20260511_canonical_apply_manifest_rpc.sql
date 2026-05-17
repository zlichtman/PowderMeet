-- Atomic single-call manifest apply RPC.
--
-- Replaces the multi-POST insert path in tools/canonical_ingest/apply.py
-- (manifest insert → trail bulk → lift bulk) which had a partial-failure
-- window if the second/third call errored after the first committed.
-- This RPC wraps everything in a single transaction.
--
-- Returns the manifest_version that was written (the next integer above
-- whatever was current). Callers should compare to the previous current
-- version to know whether they bumped the cache for every client.
--
-- Source-noise discipline: this RPC trusts the caller to have already
-- decided the diff is real. canonical_ingest.apply.py compares
-- content_hash before invoking; this RPC does NOT re-check.
--
-- Authentication: SECURITY DEFINER + execute restricted to service_role
-- only. The canonical_ingest tool runs with SUPABASE_SERVICE_ROLE_KEY
-- in the operator's environment, so it can call this. Nobody else can.
--
-- Already applied to production via Supabase MCP. This file mirrors the
-- live state so version control stays in sync.

create or replace function public.apply_canonical_manifest(
  p_resort_id text,
  p_expected_trail_count int,
  p_expected_lift_count int,
  p_validator_notes text,
  p_trails jsonb,           -- array of { name, difficulty, is_groomed,
                            --   has_moguls, is_gladed, length_m, vert_m,
                            --   osm_way_ids[], canonical_geometry (GeoJSON or null) }
  p_lifts jsonb             -- array of { name, lift_type, capacity,
                            --   ride_time_s, vertical_rise_m,
                            --   weekday_wait_min, weekend_wait_min,
                            --   base_coord (GeoJSON or null),
                            --   top_coord (GeoJSON or null),
                            --   osm_way_ids[], canonical_geometry (GeoJSON or null) }
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next_version int;
  v_trail jsonb;
  v_lift  jsonb;
begin
  select coalesce(max(manifest_version), 0) + 1
    into v_next_version
    from public.resort_canonical_manifest
   where resort_id = p_resort_id;

  insert into public.resort_canonical_manifest
    (resort_id, manifest_version, expected_trail_count, expected_lift_count, validator_notes)
  values
    (p_resort_id, v_next_version, p_expected_trail_count, p_expected_lift_count, p_validator_notes);

  for v_trail in select * from jsonb_array_elements(coalesce(p_trails, '[]'::jsonb))
  loop
    insert into public.canonical_trail (
      resort_id, manifest_version, name, difficulty, is_groomed, has_moguls,
      is_gladed, length_m, vert_m, osm_way_ids, canonical_geometry
    ) values (
      p_resort_id,
      v_next_version,
      v_trail->>'name',
      v_trail->>'difficulty',
      (v_trail->>'is_groomed')::boolean,
      coalesce((v_trail->>'has_moguls')::boolean, false),
      coalesce((v_trail->>'is_gladed')::boolean, false),
      (v_trail->>'length_m')::double precision,
      (v_trail->>'vert_m')::double precision,
      coalesce(
        (select array_agg(value::text) from jsonb_array_elements_text(v_trail->'osm_way_ids')),
        '{}'::text[]
      ),
      case when v_trail->'canonical_geometry' is null
              or v_trail->'canonical_geometry' = 'null'::jsonb
           then null
           else st_geomfromgeojson(v_trail->'canonical_geometry')::geography
      end
    );
  end loop;

  for v_lift in select * from jsonb_array_elements(coalesce(p_lifts, '[]'::jsonb))
  loop
    insert into public.canonical_lift (
      resort_id, manifest_version, name, lift_type, capacity, ride_time_s,
      vertical_rise_m, weekday_wait_min, weekend_wait_min,
      base_coord, top_coord, osm_way_ids, canonical_geometry
    ) values (
      p_resort_id,
      v_next_version,
      v_lift->>'name',
      v_lift->>'lift_type',
      (v_lift->>'capacity')::int,
      (v_lift->>'ride_time_s')::double precision,
      (v_lift->>'vertical_rise_m')::double precision,
      (v_lift->>'weekday_wait_min')::double precision,
      (v_lift->>'weekend_wait_min')::double precision,
      case when v_lift->'base_coord' is null
              or v_lift->'base_coord' = 'null'::jsonb
           then null
           else st_geomfromgeojson(v_lift->'base_coord')::geography
      end,
      case when v_lift->'top_coord' is null
              or v_lift->'top_coord' = 'null'::jsonb
           then null
           else st_geomfromgeojson(v_lift->'top_coord')::geography
      end,
      coalesce(
        (select array_agg(value::text) from jsonb_array_elements_text(v_lift->'osm_way_ids')),
        '{}'::text[]
      ),
      case when v_lift->'canonical_geometry' is null
              or v_lift->'canonical_geometry' = 'null'::jsonb
           then null
           else st_geomfromgeojson(v_lift->'canonical_geometry')::geography
      end
    );
  end loop;

  return v_next_version;
end;
$$;

revoke all on function public.apply_canonical_manifest(text, int, int, text, jsonb, jsonb) from public;
revoke all on function public.apply_canonical_manifest(text, int, int, text, jsonb, jsonb) from anon, authenticated;
grant  execute on function public.apply_canonical_manifest(text, int, int, text, jsonb, jsonb) to service_role;
