-- 0015 Server pace model (specs/08-ACTIVITY.md section 4.2). Additive: one
-- nullable column, a replaced `descent_upsert` (0011's body plus that column),
-- two service-role functions and a cron entry. Nothing existing is removed.
--
-- `descent_upsert` queues a `pace_recompute` job per owner (0004, 0011); until
-- now nothing ran it. `pace_recompute_drain()` claims those jobs once a minute
-- and rewrites each owner's `pace_models` row from their `pace_observations`,
-- so learned pace lives on the server and survives a reinstall. The client
-- reads it through `pace_models_friend_read` (MeetSession), as before.

-- ------------------------------------------------- pace_observations.difficulty
-- The server has no bundle parser, so it cannot look up an edge's difficulty.
-- The phone that matched the descent sends it per matched edge. Rows written
-- before this migration have none and are left out of the model until the run
-- is imported again.
alter table public.pace_observations
  add column difficulty text
    check (difficulty is null or difficulty in ('green', 'blue', 'black', 'double_black', 'park'));

-- `descent_upsert` as in 0011, plus `difficulty` per matched edge.
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
    insert into pace_observations (owner_id, descent_id, bundle_id, edge_id, elapsed_s, moving_s, length_m,
                                   observed_at, difficulty)
    select v_me, v_id, v_bundle, e ->> 'edge_id',
           extract(epoch from ((e ->> 'exit_at')::timestamptz - (e ->> 'enter_at')::timestamptz))::real,
           (e ->> 'moving_s')::real, (e ->> 'length_m')::real, (e ->> 'enter_at')::timestamptz,
           case when e ->> 'difficulty' in ('green', 'blue', 'black', 'double_black', 'park')
                then e ->> 'difficulty' end
    from jsonb_array_elements(v_match -> 'matched') e
    where e ->> 'edge_id' is not null;
  end if;

  insert into jobs (kind, owner_id, run_after) values ('pace_recompute', v_me, clock())
  on conflict do nothing;

  return query select v_id, v_created;
end;
$$;

-- ------------------------------------------------------------ pace_recompute
-- One owner's model from all their observations (section 4.2):
--
--   speed(o)             = length_m / moving_s, for o with moving_s >= 5 s and length_m >= 20 m
--   w(o)                 = 0.5 ^ max(0, whole seasons of age - 1): full weight for two
--                          seasons, then halved per season (a season is 365 days)
--   difficulty_factor[d] = shrink(Σw·clamp(speed/baseline[d]) / Σw, Σw, 8)
--   edge_factor[e]       = shrink(Σw·clamp(speed/(baseline[d]·difficulty_factor[d])) / Σw, Σw, 5)
--   stops_per_km         = shrink(stops / km, descents, 10), toward the solver's default 0.4
--   shrink(x, n, k)      = (n·x + k·neutral) / (n + k)
--
-- `baseline[d]` is the owner's own `profiles.baseline_speeds`, which the phone
-- has already calibrated from the same runs (section 4.1), so the factors say
-- how far the skier has moved from that and do not count the evidence twice.
-- A difficulty with no baseline, or an observation with no difficulty, is
-- left out. A stop is an edge where elapsed time exceeds moving time by 20 s
-- or more. Ratios are clamped to 0.3...3 so one bad GPS edge cannot swing the
-- model. An owner with no usable observations has no model row.
create function public.pace_recompute(p_owner uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
  v_baseline jsonb;
  v_difficulty jsonb;
  v_edges jsonb;
  v_descents int;
  v_stops real;
  v_km real;
  v_stop_rate real;
begin
  select p.baseline_speeds into v_baseline from profiles p where p.id = p_owner;
  if v_baseline is null then
    delete from pace_models pm where pm.owner_id = p_owner;
    return;
  end if;

  create temporary table if not exists pace_work (
    edge_id text, difficulty text, ratio double precision, w double precision,
    descent_id uuid, stopped boolean, length_m double precision
  ) on commit drop;
  truncate pace_work;

  insert into pace_work (edge_id, difficulty, ratio, w, descent_id, stopped, length_m)
  select o.edge_id, o.difficulty,
         least(greatest((o.length_m / o.moving_s) / (v_baseline ->> o.difficulty)::double precision, 0.3), 3.0),
         power(0.5, greatest(0, floor(extract(epoch from (v_now - coalesce(o.observed_at, v_now))) / (365 * 86400)) - 1)),
         o.descent_id,
         coalesce(o.elapsed_s - o.moving_s >= 20, false),
         o.length_m
  from pace_observations o
  where o.owner_id = p_owner
    and o.difficulty is not null
    and o.moving_s >= 5 and o.length_m >= 20
    and jsonb_typeof(v_baseline -> o.difficulty) = 'number'
    and (v_baseline ->> o.difficulty)::double precision > 0;

  select count(distinct pw.descent_id) into v_descents from pace_work pw;
  if v_descents = 0 then
    delete from pace_models pm where pm.owner_id = p_owner;
    return;
  end if;

  select coalesce(jsonb_object_agg(f.difficulty, round(f.factor::numeric, 3)), '{}'::jsonb) into v_difficulty
  from (
    select pw.difficulty, (sum(pw.w * pw.ratio) + 8) / (sum(pw.w) + 8) as factor
    from pace_work pw group by pw.difficulty
  ) f;

  select coalesce(jsonb_object_agg(f.edge_id, round(f.factor::numeric, 3)), '{}'::jsonb) into v_edges
  from (
    select pw.edge_id,
           (sum(pw.w * least(greatest(pw.ratio / (v_difficulty ->> pw.difficulty)::double precision, 0.3), 3.0)) + 5)
             / (sum(pw.w) + 5) as factor
    from pace_work pw group by pw.edge_id
  ) f;

  select count(*) filter (where pw.stopped), sum(pw.length_m) / 1000 into v_stops, v_km from pace_work pw;
  v_stop_rate := (v_descents * (v_stops / greatest(v_km, 0.1)) + 10 * 0.4) / (v_descents + 10);

  insert into pace_models as pm (owner_id, computed_at, difficulty_factor, edge_factor, stops_per_km, n_descents)
  values (p_owner, v_now, v_difficulty, v_edges, round(v_stop_rate::numeric, 3), v_descents)
  on conflict (owner_id) do update
    set computed_at = excluded.computed_at, difficulty_factor = excluded.difficulty_factor,
        edge_factor = excluded.edge_factor, stops_per_km = excluded.stops_per_km,
        n_descents = excluded.n_descents;
end;
$$;

-- The consumer: claims due `pace_recompute` jobs and runs them, one failure
-- not stopping the rest. Returns how many succeeded. Cron calls it every
-- minute, so a new descent reaches the model within about a minute.
create function public.pace_recompute_drain(p_limit int default 50)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job jobs;
  v_done int := 0;
begin
  for v_job in select * from jobs_claim('pace_recompute', p_limit) loop
    begin
      if v_job.owner_id is not null then
        perform pace_recompute(v_job.owner_id);
      end if;
      perform jobs_complete(v_job.id);
      v_done := v_done + 1;
    exception when others then
      perform jobs_complete(v_job.id, sqlerrm);
    end;
  end loop;
  return v_done;
end;
$$;

-- The factors are measured against `baseline_speeds`. The phone saves a newly
-- calibrated baseline after the descents that changed it, and an ability
-- change replaces it, so a model computed in between would be measured
-- against the old one: recompute whenever it changes.
create function public.pace_recompute_on_baseline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.baseline_speeds is distinct from old.baseline_speeds
     and exists (select 1 from pace_observations o where o.owner_id = new.id) then
    insert into jobs (kind, owner_id, run_after) values ('pace_recompute', new.id, clock())
    on conflict do nothing;
  end if;
  return new;
end;
$$;

create trigger profiles_baseline_pace_recompute
  after update of baseline_speeds on public.profiles
  for each row execute function public.pace_recompute_on_baseline();

revoke execute on function public.pace_recompute(uuid), public.pace_recompute_drain(int),
  public.pace_recompute_on_baseline()
  from public, anon, authenticated;
grant execute on function public.pace_recompute(uuid), public.pace_recompute_drain(int),
  public.pace_recompute_on_baseline() to service_role;

-- Jobs older than a day were swept by `housekeeping`, so queue one for every
-- owner who has observations; the first drain builds their model.
insert into public.jobs (kind, owner_id, run_after)
select distinct 'pace_recompute', o.owner_id, now()
from public.pace_observations o
on conflict do nothing;

select cron.schedule('pace_recompute', '* * * * *', $$select public.pace_recompute_drain()$$);
