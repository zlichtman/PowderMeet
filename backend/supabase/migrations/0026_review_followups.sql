-- 0026 Follow-ups from the 22 Nov 2026 review audit, and the owner's decisions on
-- search and on a partner's deleted account. specs/03-PROTOCOL.md sections 2, 4 and
-- 6, specs/04-SCHEMA.md sections 2, 3, 4, 6, 7, 9, 10 and 11.
--
-- Each function below is the latest definition (named per section) with only
-- the change applied:
--   - `descent_upsert` is rate-limited per minute, and new descents per day,
--     with the shared `rate_limit` (a client queues a `rate_limited` run and
--     sends it later);
--   - `presence_clear` also clears `profiles.current_resort_id`, so a friend
--     stops reading the last resort once the skier signs out or leaves;
--   - a partner's `meet_progress` row is readable only while the meet is open;
--   - `meet_propose` holds the resort's active bundle row while it checks the
--     rendezvous, so a concurrent publish cannot slip past the invalidation;
--   - `resort_bundles.status_meta` keeps what the status worker derives from a
--     bundle, so the bundle is downloaded once per bundle, not once per job.
--   - `account_delete` leaves the partner's partner-left push its name until it
--     is sent (`push_outbox_forget_name` then drops it);
--   - `search_users` matches a stored normalised name through a trigram index
--     instead of normalising every profile on each call.

-- ============================================================ descent_upsert

-- 0015's function. Every call counts toward 120 a minute; a call that stores
-- a new descent also counts toward 1,000 a day. A re-match after a new bundle
-- re-sends runs already stored and counts only per minute. Both raise
-- `rate_limited`, which the phone treats as "try later": the run stays queued.
-- The day bucket is the longest window the schema keeps (`housekeeping` drops
-- rate-limit rows after a day).
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

  perform rate_limit(v_me, 'descent_upsert', 120, interval '1 minute');

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
    perform rate_limit(v_me, 'descent_new', 1000, interval '1 day');
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

-- ============================================================ presence_clear

-- 0020's function. `current_resort_id` is the other half of "where is this
-- skier": friends read it on the profile and `presence_recipients` sends
-- positions by it, with no TTL. Clearing it with the presence row means a
-- sign-out or leaving the resort is visible to friends at once, not never.
-- The next resort the phone opens sets it again through `profile_update`.
create or replace function public.presence_clear()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  delete from presence pr where pr.user_id = v_me;
  update profiles p set current_resort_id = null, updated_at = clock()
  where p.id = v_me and p.current_resort_id is not null;
end;
$$;

-- ======================================================= meet_progress_read

-- 0003's policy. Each participant keeps reading their own row; the partner's
-- row only while the meet is open. Once a meet ends (by a block, an unfriend,
-- an expiry or arriving) the other side's last ETA, distance and state are no
-- longer anyone else's business. The rule ignores blocks on purpose: a block
-- reads exactly like any other ending, so it stays hidden (0025).
drop policy if exists meet_progress_read on public.meet_progress;
create policy meet_progress_read on public.meet_progress
  for select to authenticated
  using (exists (
    select 1 from public.meets m
    where m.meet_id = meet_progress.meet_id
      and (select auth.uid()) in (m.proposer_id, m.invitee_id)
      and (meet_progress.user_id = (select auth.uid()) or m.status in ('proposed', 'active'))));

-- ============================================================== meet_propose

-- 0025's function. The active bundle row is read `for share`: a concurrent
-- `bundle_publish` that drops the rendezvous waits for this proposal to commit,
-- and its invalidation trigger then ends it; a publish that committed first is
-- what this check reads.
create or replace function public.meet_propose(
  p_meet_id uuid, p_invitee uuid, p_resort_id text, p_rendezvous_id text,
  p_bundle_id text, p_proposer_eta_s int, p_proposer_eta_sd_s int,
  p_supersedes uuid default null)
returns public.meets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_now timestamptz := clock();
  v_meet meets;
  v_old meets;
begin
  if p_meet_id is null or p_invitee is null or p_resort_id is null or p_rendezvous_id is null
     or p_proposer_eta_s not between 0 and 86400 or p_proposer_eta_sd_s not between 0 and 86400 then
    raise exception 'invalid';
  end if;
  if p_invitee = v_me then
    raise exception 'not_friends';
  end if;

  perform lock_users(v_me, p_invitee);

  -- Idempotent retry: the same proposer sending the same meet_id again.
  select m.* into v_meet from meets m where m.meet_id = p_meet_id;
  if found then
    if v_meet.proposer_id = v_me then
      return v_meet;
    end if;
    raise exception 'meet_id_taken';
  end if;

  -- Each proposal pushes to the invitee, and propose-then-cancel frees the
  -- busy check, so without a limit a friend could push-spam.
  perform rate_limit(v_me, 'meet_propose', 20, interval '1 hour');

  if not is_accepted_friend(v_me, p_invitee) then
    raise exception 'not_friends';
  end if;
  if not exists (select 1 from resorts r where r.id = p_resort_id and r.published) then
    raise exception 'resort_not_published';
  end if;
  -- I-01: a meet may end only at a rendezvous in the active bundle.
  perform 1 from resort_active_bundle ab
  where ab.resort_id = p_resort_id and p_rendezvous_id = any (ab.rendezvous_ids)
  for share;
  if not found then
    raise exception 'rendezvous_unknown';
  end if;

  if p_supersedes is not null then
    select m.* into v_old from meets m where m.meet_id = p_supersedes for update;
    if not found or v_old.proposer_id <> v_me then
      raise exception 'not_participant';
    end if;
    if v_old.invitee_id <> p_invitee or v_old.status = 'active' then
      raise exception 'invalid_state';
    end if;
    if v_old.status = 'proposed' then
      update meets m
      set status = 'invalidated', end_reason = 'superseded', ended_at = v_now, superseded_by = p_meet_id
      where m.meet_id = p_supersedes;
    end if;
  end if;

  -- I-23: one non-terminal meet per user, in either role.
  if exists (select 1 from meets m
             where m.status in ('proposed', 'active') and v_me in (m.proposer_id, m.invitee_id)) then
    raise exception 'meet_busy_proposer';
  end if;
  if exists (select 1 from meets m
             where m.status in ('proposed', 'active') and p_invitee in (m.proposer_id, m.invitee_id)) then
    raise exception 'meet_busy_invitee';
  end if;

  insert into meets (meet_id, resort_id, bundle_id, rendezvous_id, proposer_id, invitee_id, status,
                     proposer_eta_s, proposer_eta_sd_s, created_at, expires_at)
  values (p_meet_id, p_resort_id, p_bundle_id, p_rendezvous_id, v_me, p_invitee, 'proposed',
          p_proposer_eta_s, p_proposer_eta_sd_s, v_now, v_now + interval '30 minutes')
  returning * into v_meet;
  return v_meet;
end;
$$;

-- ================================================== resort_bundles.status_meta

-- What the status worker needs from a bundle (provider aliases, lift and trail
-- group ids), derived by the worker from the verified bytes the first time it
-- sees the bundle and read back on every later job. A bundle id is the hash
-- of its bytes, so the derivation never goes stale. Written by the service
-- role only; it is public data like the bundle it comes from.
alter table public.resort_bundles add column if not exists status_meta jsonb
  check (status_meta is null or jsonb_typeof(status_meta) = 'object');

-- ============================================================ account_delete

-- 0025's function. An open meet already ends for the partner here, as any
-- partner-left ending does: status `invalidated`, end reason `partner_left`,
-- `meet.updated` on both topics (the partner's copy survives the purge) and a
-- `meet.ended` push to the partner, the deleting user being the one who ended
-- it. What 0025 left out is the name in that push: it said "A friend left".
-- The row itself still cascades away with the profile, since it holds the
-- deleted user's id and position in the meet; a phone that missed both hints
-- finds no meet and says the partner left (03-PROTOCOL section 4).
create or replace function public.account_delete()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  -- Before any event of this call is written, so what is left afterwards
  -- naming this user is this call's own. Covers the presence broadcasts 0023
  -- purged here.
  begin
    delete from realtime.messages rm
    where rm.payload::text like '%' || v_me::text || '%' or rm.topic = 'user:' || v_me::text;
  exception when others then
    raise warning 'account_delete: realtime messages not purged: %', sqlerrm;
  end;

  -- Tell partners first, while the profile still exists for the notification.
  update meets m
  set status = 'invalidated', end_reason = 'partner_left', ended_at = clock()
  where m.status in ('proposed', 'active') and v_me in (m.proposer_id, m.invitee_id);

  delete from friendships f where v_me in (f.requester_id, f.addressee_id);
  delete from user_blocks ub where v_me in (ub.blocker_id, ub.blocked_id);
  delete from presence pr where pr.user_id = v_me;
  delete from descents d where d.owner_id = v_me;
  delete from pace_models pm where pm.owner_id = v_me;
  delete from device_tokens dt where dt.user_id = v_me;
  delete from push_outbox po where po.user_id = v_me;
  delete from user_reports ur where ur.reported_id = v_me;

  -- Other people's pushes that name this user (meet pushes carry
  -- `partner_id`, friend pushes `user_id`).
  -- The partner's `meet.ended` for the meet this call ended keeps the name
  -- until it is sent, so it reads "Meet ended: <name> left" as any partner-left
  -- ending does; `push_outbox_forget_name` drops the name once the row is sent
  -- or given up on. It loses the id now, so nothing below deletes it.
  update push_outbox po
  set payload = po.payload - array['partner_id', 'user_id', 'display_name', 'avatar_url']
  where po.kind = 'meet.ended' and po.sent_at is null
    and po.payload ->> 'partner_id' = v_me::text
    and po.payload ->> 'end_reason' = 'partner_left';
  update push_outbox po
  set payload = po.payload - array['partner_id', 'partner_name', 'user_id', 'display_name', 'avatar_url']
  where po.kind = 'meet.ended' and po.sent_at is null
    and po.payload ->> 'partner_id' = v_me::text;
  delete from push_outbox po
  where po.payload ->> 'partner_id' = v_me::text or po.payload ->> 'user_id' = v_me::text;

  -- This call's own events: those on this user's topic have no reader any
  -- more; the rest keep the ids the partner's phone needs (`user_id`,
  -- `friendship_id`, the meet's columns) and lose the name and photo. If the
  -- name cannot be stripped, the event goes: storing nothing outranks replay.
  begin
    delete from realtime.messages rm where rm.topic = 'user:' || v_me::text;
  exception when others then
    raise warning 'account_delete: own topic not purged: %', sqlerrm;
  end;
  begin
    update realtime.messages rm
    set payload = jsonb_set(rm.payload, '{data}',
                            (rm.payload -> 'data') - array['display_name', 'avatar_url'])
    where rm.payload -> 'data' ->> 'user_id' = v_me::text
      and (rm.payload -> 'data') ?| array['display_name', 'avatar_url'];
  exception when others then
    begin
      delete from realtime.messages rm
      where rm.payload -> 'data' ->> 'user_id' = v_me::text
        and (rm.payload -> 'data') ?| array['display_name', 'avatar_url'];
    exception when others then
      raise warning 'account_delete: realtime messages not stripped: %', sqlerrm;
    end;
  end;

  -- Avatar files left behind (the client's own removal failed) are removed by
  -- the `avatar-sweep` worker through the Storage API once the profile is gone.
  -- The job has no owner, so it does not cascade away with the profile; the
  -- ping is sent after this transaction commits.
  insert into jobs (kind, run_after) values ('avatar_sweep', clock());
  perform worker_ping('avatar-sweep', 1);

  -- The rest (meets, progress, events, rate limits, jobs, the Apple token)
  -- cascades.
  delete from profiles p where p.id = v_me;
  delete from auth.users u where u.id = v_me;
end;
$$;

-- ================================================== push_outbox_forget_name

-- A queued push that still carries a partner's name but no partner id is the
-- partner-left push of a deleted account (above): every other meet push names
-- its partner by id. Once it is sent, collapsed, dropped as stale or given up
-- on, the name has done its job and goes.
create or replace function public.push_outbox_forget_name()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.payload := new.payload - 'partner_name';
  return new;
end;
$$;

revoke execute on function public.push_outbox_forget_name() from public, anon, authenticated;

drop trigger if exists push_outbox_forget_name on public.push_outbox;
create trigger push_outbox_forget_name
  before update of sent_at on public.push_outbox
  for each row
  when (old.sent_at is null and new.sent_at is not null
        and new.payload ? 'partner_name' and not new.payload ? 'partner_id')
  execute function public.push_outbox_forget_name();

-- ================================================================ search_users

-- The name as search compares it, stored so it is worked out once per write,
-- not twice per profile on every search, and indexed with trigrams so a
-- "contains" match (the query anywhere in the name) is an index scan.
-- Not granted to clients: profiles are read by named columns.
create extension if not exists pg_trgm with schema extensions;

alter table public.profiles add column if not exists search_name text
  generated always as (lower(public.display_name_normalize(display_name))) stored;

create index if not exists profiles_search_name_trgm
  on public.profiles using gin (search_name extensions.gin_trgm_ops);

-- 0025's function, matching on `search_name` with the same pattern, escapes,
-- order, limit, rate limit and block rule. A two-character query has no
-- trigram, so it still reads the whole index, but no longer normalises every
-- name to do it.
create or replace function public.search_users(p_query text)
returns table (user_id uuid, display_name text, avatar_url text, relation text)
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_me uuid := require_uid();
  v_query text := lower(display_name_normalize(coalesce(p_query, '')));
  v_pattern text;
begin
  if char_length(v_query) not between 2 and 24 then
    return;
  end if;
  perform rate_limit(v_me, 'search_users', 60, interval '1 minute');
  -- Backslash first, so the escapes added for % and _ are not doubled.
  v_pattern := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select p.id, p.display_name, p.avatar_url,
      case
        when exists (select 1 from friendships f
                     where f.status = 'accepted'
                       and ((f.requester_id = v_me and f.addressee_id = p.id)
                         or (f.requester_id = p.id and f.addressee_id = v_me))) then 'friend'
        when exists (select 1 from friendships f
                     where f.status = 'pending' and f.requester_id = v_me and f.addressee_id = p.id)
          then 'request_sent'
        when exists (select 1 from friendships f
                     where f.status = 'pending' and f.requester_id = p.id and f.addressee_id = v_me)
          then 'request_received'
        else 'none'
      end
    from profiles p
    where p.id <> v_me
      and p.search_name like '%' || v_pattern || '%' escape '\'
      and not display_name_is_placeholder(p.display_name)
      and not exists (select 1 from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p.id)
    order by
      case when p.search_name like v_pattern || '%' escape '\' then 0 else 1 end,
      lower(p.display_name), p.id
    limit 20;
end;
$$;

-- `create or replace` keeps each replaced function's grants, so no execute
-- privilege changes except for the one new function, closed above like every
-- other trigger function.
