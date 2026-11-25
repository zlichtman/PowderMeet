-- Descent display stats. The server stores raw tracks and has no parser, so the
-- importing phone sends what it measured and matched (vertical, distance,
-- speeds, the run's name and difficulty, the resort and ski day, and the pace
-- evidence per difficulty) and the history is drawn from it without the track.
-- Shape: `specs/02-DOMAIN.md` section 8. Derived data: a re-import replaces it.

alter table public.descents
  add column stats jsonb check (stats is null or jsonb_typeof(stats) = 'object');

-- `descent_upsert` as in 0004, plus `stats`.
create or replace function public.descent_upsert(p_descent jsonb)
returns table (descent_id uuid, created boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_me uuid := require_uid();
  v_hash text;
  v_source text;
  v_started timestamptz;
  v_ended timestamptz;
  v_track bytea;
  v_resort text;
  v_match jsonb;
  v_bundle text;
  v_version int;
  v_stats jsonb;
  v_id uuid;
  v_created boolean := false;
begin
  begin
    v_hash := p_descent ->> 'content_hash';
    v_source := p_descent ->> 'source';
    v_started := (p_descent ->> 'started_at')::timestamptz;
    v_ended := (p_descent ->> 'ended_at')::timestamptz;
    v_track := decode(p_descent ->> 'track', 'base64');
    v_resort := p_descent ->> 'resort_id';
    v_match := p_descent -> 'match';
    v_stats := p_descent -> 'stats';
    if v_match is not null and jsonb_typeof(v_match) = 'object' then
      v_bundle := v_match ->> 'bundle_id';
      v_version := (v_match ->> 'matcher_version')::int;
    else
      v_match := null;
    end if;
  exception when others then
    raise exception 'invalid';
  end;
  if v_hash is null or v_hash !~ '^[0-9a-f]{64}$'
     or v_source is null or v_source not in ('live', 'slopes', 'gpx', 'tcx', 'fit', 'healthkit')
     or v_started is null or v_ended is null or v_ended <= v_started
     or v_track is null or octet_length(v_track) not between 1 and 2097152 then
    raise exception 'invalid';
  end if;
  if v_stats is not null and jsonb_typeof(v_stats) = 'null' then
    v_stats := null;
  end if;
  if v_stats is not null and (jsonb_typeof(v_stats) <> 'object' or octet_length(v_stats::text) > 4096) then
    raise exception 'invalid';
  end if;
  if v_resort is not null and not exists (select 1 from resorts r where r.id = v_resort) then
    v_resort := null;
  end if;
  if v_match is not null and (
       v_version is null or jsonb_typeof(v_match -> 'matched') is distinct from 'array'
       or not exists (select 1 from resort_bundles rb where rb.bundle_id = v_bundle)) then
    raise exception 'invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('descent:' || v_me::text, 0));

  -- One physical descent is one row (I-20): same bytes, or more than 80 % of
  -- the longer recording's time shared with one already stored.
  select d.descent_id into v_id
  from descents d
  where d.owner_id = v_me and d.content_hash = v_hash;
  if v_id is null then
    select d.descent_id into v_id
    from descents d
    where d.owner_id = v_me and d.started_at < v_ended and d.ended_at > v_started
      and extract(epoch from (least(d.ended_at, v_ended) - greatest(d.started_at, v_started)))
          > 0.8 * extract(epoch from greatest(d.ended_at - d.started_at, v_ended - v_started))
    order by d.started_at
    limit 1;
  end if;
  if v_id is null then
    insert into descents as d (owner_id, source, started_at, ended_at, content_hash, track, resort_id,
                               device, app_build, created_at, stats)
    values (v_me, v_source, v_started, v_ended, v_hash, v_track, v_resort,
            left(p_descent ->> 'device', 80), left(p_descent ->> 'app_build', 32), clock(), v_stats)
    returning d.descent_id into v_id;
    v_created := true;
  elsif v_stats is not null then
    -- A re-import of the same bytes refreshes what the phone derived (a run's
    -- name after a new bundle). Another recording of the same run does not.
    update descents d set stats = v_stats
    where d.descent_id = v_id and d.content_hash = v_hash;
  end if;

  if v_match is not null then
    insert into descent_matches as dm (descent_id, bundle_id, matcher_version, matched, coverage, confidence, created_at)
    values (v_id, v_bundle, v_version, v_match -> 'matched',
            (v_match ->> 'coverage')::real, (v_match ->> 'confidence')::real, clock())
    on conflict on constraint descent_matches_pkey do update
      set matched = excluded.matched, coverage = excluded.coverage,
          confidence = excluded.confidence, created_at = excluded.created_at;

    -- Per-edge observations are a derivation of the match; rebuild them.
    delete from pace_observations po where po.descent_id = v_id and po.bundle_id = v_bundle;
    insert into pace_observations (owner_id, descent_id, bundle_id, edge_id, elapsed_s, moving_s, length_m, observed_at)
    select v_me, v_id, v_bundle, e ->> 'edge_id',
           extract(epoch from ((e ->> 'exit_at')::timestamptz - (e ->> 'enter_at')::timestamptz))::real,
           (e ->> 'moving_s')::real, (e ->> 'length_m')::real, (e ->> 'enter_at')::timestamptz
    from jsonb_array_elements(v_match -> 'matched') e
    where e ->> 'edge_id' is not null;
  end if;

  insert into jobs (kind, owner_id, run_after) values ('pace_recompute', v_me, clock())
  on conflict do nothing;

  return query select v_id, v_created;
end;
$$;
