-- 0004 Functions: internal helpers, client RPCs, service RPCs and the functions
-- cron calls. specs/04-SCHEMA.md sections 6 and 7, specs/03-PROTOCOL.md.
--
-- Every RPC is SECURITY DEFINER with a pinned search_path and reads the caller
-- from auth.uid(). Failures are raised with errcode P0001 and a message code
-- (specs/03-PROTOCOL.md section 5, plus not_authenticated, invalid, not_found
-- and rate_limited). Execute privileges are set in one place, at the end of
-- 0005, once every function exists.

-- ============================================================ internal helpers

create function public.require_uid()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  return v_uid;
end;
$$;

create function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_blocks ub
    where (ub.blocker_id = a and ub.blocked_id = b) or (ub.blocker_id = b and ub.blocked_id = a));
$$;

-- Transaction-scoped locks on two users, always taken in the same order, so
-- two calls about the same people run one after the other.
create function public.lock_users(a uuid, b uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('user:' || least(a, b)::text, 0));
  if a <> b then
    perform pg_advisory_xact_lock(hashtextextended('user:' || greatest(a, b)::text, 0));
  end if;
end;
$$;

-- Fixed-window rate limit. Raises rate_limited once the window is full.
create function public.rate_limit(p_user uuid, p_bucket text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamptz := date_bin(p_window, clock(), timestamptz '2000-01-01 00:00:00+00');
  v_count int;
begin
  insert into rate_limits as rl (user_id, bucket, window_start, count)
  values (p_user, p_bucket, v_start, 1)
  on conflict (user_id, bucket, window_start) do update set count = rl.count + 1
  returning rl.count into v_count;
  if v_count > p_max then
    raise exception 'rate_limited';
  end if;
end;
$$;

-- The app build the client reported in the `x-app-build` request header.
create function public.request_app_build()
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  return left(nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-app-build', 32);
exception when others then
  return null;
end;
$$;

create function public.profile_brief(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'user_id', p_user,
    'display_name', (select p.display_name from public.profiles p where p.id = p_user),
    'avatar_url', (select p.avatar_url from public.profiles p where p.id = p_user));
$$;

-- Sends one event on a private Realtime topic. Realtime is a hint channel: a
-- failure to send must never undo the write that caused it.
create function public.emit(p_topic text, p_type text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform realtime.send(
    jsonb_build_object('v', 1, 'type', p_type, 'at', clock(), 'data', p_data),
    p_type, p_topic, true);
exception when others then
  raise warning 'emit % on % failed: %', p_type, p_topic, sqlerrm;
end;
$$;

-- Asks an edge worker to run, p_times times (one job per invocation), at most
-- 20 at once so a full catalog of resorts drains in waves, not one burst. The
-- project URL and the worker secret are read from Vault (`project_url`,
-- `worker_secret`); with either missing this does nothing and returns false.
create function public.worker_ping(p_function text, p_times int default 1)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select ds.decrypted_secret into v_url from vault.decrypted_secrets ds where ds.name = 'project_url';
  select ds.decrypted_secret into v_secret from vault.decrypted_secrets ds where ds.name = 'worker_secret';
  if v_url is null or v_secret is null then
    return false;
  end if;
  for i in 1 .. greatest(least(coalesce(p_times, 1), 20), 1) loop
    perform net.http_post(
      url := rtrim(v_url, '/') || '/functions/v1/' || p_function,
      body := '{}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret),
      timeout_milliseconds := 30000);
  end loop;
  return true;
exception when others then
  raise warning 'worker_ping(%) failed: %', p_function, sqlerrm;
  return false;
end;
$$;

-- Queues one notification. Users with no registered device get no row.
create function public.push_enqueue(p_user uuid, p_kind text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user is null or not exists (select 1 from device_tokens dt where dt.user_id = p_user) then
    return;
  end if;
  insert into push_outbox (user_id, kind, payload, created_at)
  values (p_user, p_kind, coalesce(p_payload, '{}'::jsonb), clock());
  perform worker_ping('push-drain', 1);
end;
$$;

-- Ends every non-terminal meet between two users.
create function public.meets_end_between(a uuid, b uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update meets m
  set status = 'invalidated', end_reason = p_reason, ended_at = clock()
  where m.status in ('proposed', 'active')
    and ((m.proposer_id = a and m.invitee_id = b) or (m.proposer_id = b and m.invitee_id = a));
end;
$$;

-- Who receives a position (DECISION 7): accepted, unblocked friends who are
-- looking at or standing in the same resort, plus any friend in a non-terminal
-- meet with the sender.
create function public.presence_recipients(p_user uuid, p_resort_id text)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select o.other
  from (
    select case when f.requester_id = p_user then f.addressee_id else f.requester_id end as other
    from public.friendships f
    where f.status = 'accepted' and p_user in (f.requester_id, f.addressee_id)
  ) o
  where not public.is_blocked_between(p_user, o.other)
    and (
      (p_resort_id is not null and (
        exists (select 1 from public.profiles p where p.id = o.other and p.current_resort_id = p_resort_id)
        or exists (select 1 from public.presence pr
                   where pr.user_id = o.other and pr.resort_id = p_resort_id
                     and pr.received_at > public.clock() - interval '15 minutes')))
      or exists (
        select 1 from public.meets m
        where m.status in ('proposed', 'active')
          and ((m.proposer_id = p_user and m.invitee_id = o.other)
            or (m.proposer_id = o.other and m.invitee_id = p_user))));
$$;

-- ==================================================================== social

create function public.friend_request(p_user uuid)
returns public.friendships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_row friendships;
begin
  if p_user is null or p_user = v_me then
    raise exception 'invalid';
  end if;
  if not exists (select 1 from profiles p where p.id = p_user) then
    raise exception 'invalid';
  end if;
  perform lock_users(v_me, p_user);
  if is_blocked_between(v_me, p_user) then
    raise exception 'blocked';
  end if;

  select f.* into v_row
  from friendships f
  where (f.requester_id = v_me and f.addressee_id = p_user)
     or (f.requester_id = p_user and f.addressee_id = v_me);
  if found then
    -- The other person already asked: accept. Otherwise this is a repeat.
    if v_row.status = 'pending' and v_row.addressee_id = v_me then
      update friendships f set status = 'accepted', responded_at = clock()
      where f.id = v_row.id
      returning f.* into v_row;
    end if;
    return v_row;
  end if;

  perform rate_limit(v_me, 'friend_request', 30, interval '1 hour');
  insert into friendships (requester_id, addressee_id, status, created_at)
  values (v_me, p_user, 'pending', clock())
  returning * into v_row;
  return v_row;
end;
$$;

create function public.friend_respond(p_friendship_id uuid, p_accept boolean)
returns public.friendships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_row friendships;
begin
  if p_accept is null then
    raise exception 'invalid';
  end if;
  select f.* into v_row from friendships f where f.id = p_friendship_id for update;
  if not found or v_me not in (v_row.requester_id, v_row.addressee_id) then
    raise exception 'not_found';
  end if;
  -- Only the person who was asked may answer.
  if v_row.addressee_id <> v_me then
    raise exception 'invalid_state';
  end if;
  if v_row.status = 'accepted' then
    if p_accept then
      return v_row;
    end if;
    raise exception 'invalid_state';
  end if;
  if p_accept then
    update friendships f set status = 'accepted', responded_at = clock()
    where f.id = v_row.id
    returning f.* into v_row;
  else
    delete from friendships f where f.id = v_row.id;
  end if;
  return v_row;
end;
$$;

create function public.friend_remove(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  if p_user is null or p_user = v_me then
    raise exception 'invalid';
  end if;
  perform lock_users(v_me, p_user);
  delete from friendships f
  where (f.requester_id = v_me and f.addressee_id = p_user)
     or (f.requester_id = p_user and f.addressee_id = v_me);
  perform meets_end_between(v_me, p_user, 'partner_left');
end;
$$;

create function public.block_user(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  if p_user is null or p_user = v_me then
    raise exception 'invalid';
  end if;
  if not exists (select 1 from profiles p where p.id = p_user) then
    raise exception 'invalid';
  end if;
  perform lock_users(v_me, p_user);
  insert into user_blocks (blocker_id, blocked_id, created_at)
  values (v_me, p_user, clock())
  on conflict do nothing;
  delete from friendships f
  where (f.requester_id = v_me and f.addressee_id = p_user)
     or (f.requester_id = p_user and f.addressee_id = v_me);
  perform meets_end_between(v_me, p_user, 'partner_left');
end;
$$;

create function public.unblock_user(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  delete from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p_user;
end;
$$;

-- Contact discovery by hashes computed on the phone. Minimal columns, capped
-- input, rate limited: not an enumeration oracle.
create function public.find_users(p_email_hashes text[], p_phone_hashes text[])
returns table (id uuid, display_name text, avatar_url text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_me uuid := require_uid();
begin
  if coalesce(cardinality(p_email_hashes), 0) > 50 or coalesce(cardinality(p_phone_hashes), 0) > 50 then
    raise exception 'invalid';
  end if;
  perform rate_limit(v_me, 'find_users', 20, interval '1 minute');
  return query
    select p.id, p.display_name, p.avatar_url
    from profiles p
    where p.id <> v_me
      and (p.email_hash = any (coalesce(p_email_hashes, '{}'::text[]))
        or p.phone_hash = any (coalesce(p_phone_hashes, '{}'::text[])))
      and not is_blocked_between(v_me, p.id);
end;
$$;

create function public.social_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  return jsonb_build_object(
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'since', f.responded_at)
             order by p.display_name, p.id)
      from friendships f
      join profiles p
        on p.id = case when f.requester_id = v_me then f.addressee_id else f.requester_id end
      where f.status = 'accepted' and v_me in (f.requester_id, f.addressee_id)), '[]'::jsonb),
    'pending_in', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', f.created_at)
             order by f.created_at desc, f.id)
      from friendships f
      join profiles p on p.id = f.requester_id
      where f.status = 'pending' and f.addressee_id = v_me), '[]'::jsonb),
    'pending_out', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', f.created_at)
             order by f.created_at desc, f.id)
      from friendships f
      join profiles p on p.id = f.addressee_id
      where f.status = 'pending' and f.requester_id = v_me), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', b.created_at)
             order by b.created_at desc, p.id)
      from user_blocks b
      join profiles p on p.id = b.blocked_id
      where b.blocker_id = v_me), '[]'::jsonb));
end;
$$;

-- Whitelisted keys only. avatar_url must be a path under the caller's own
-- folder in the avatars bucket.
create function public.profile_update(p_patch jsonb)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_key text;
  v_row profiles;
  v_allowed constant text[] := array['display_name', 'avatar_url', 'ability', 'max_difficulty',
    'baseline_speeds', 'equipment', 'avoid', 'max_pitch_deg', 'height_cm', 'weight_kg',
    'email_hash', 'phone_hash', 'current_resort_id'];
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'invalid';
  end if;
  for v_key in select jsonb_object_keys(p_patch) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'invalid';
    end if;
  end loop;
  if (p_patch ->> 'avatar_url') is not null
     and (p_patch ->> 'avatar_url') !~ ('^' || v_me::text || '/[A-Za-z0-9._-]{1,80}$') then
    raise exception 'invalid';
  end if;
  if (p_patch ->> 'current_resort_id') is not null
     and not exists (select 1 from resorts r where r.id = p_patch ->> 'current_resort_id' and r.published) then
    raise exception 'resort_not_published';
  end if;

  begin
    update profiles p set
      display_name = case when p_patch ? 'display_name' then btrim(p_patch ->> 'display_name') else p.display_name end,
      avatar_url = case when p_patch ? 'avatar_url' then p_patch ->> 'avatar_url' else p.avatar_url end,
      ability = case when p_patch ? 'ability' then p_patch ->> 'ability' else p.ability end,
      max_difficulty = case when p_patch ? 'max_difficulty' then p_patch ->> 'max_difficulty' else p.max_difficulty end,
      baseline_speeds = case when p_patch ? 'baseline_speeds' then p_patch -> 'baseline_speeds' else p.baseline_speeds end,
      equipment = case when p_patch ? 'equipment' then nullif(p_patch -> 'equipment', 'null'::jsonb) else p.equipment end,
      avoid = case when p_patch ? 'avoid'
        then array(select distinct a from jsonb_array_elements_text(p_patch -> 'avoid') a order by a)
        else p.avoid end,
      max_pitch_deg = case when p_patch ? 'max_pitch_deg' then (p_patch ->> 'max_pitch_deg')::smallint else p.max_pitch_deg end,
      height_cm = case when p_patch ? 'height_cm' then (p_patch ->> 'height_cm')::smallint else p.height_cm end,
      weight_kg = case when p_patch ? 'weight_kg' then (p_patch ->> 'weight_kg')::smallint else p.weight_kg end,
      email_hash = case when p_patch ? 'email_hash' then p_patch ->> 'email_hash' else p.email_hash end,
      phone_hash = case when p_patch ? 'phone_hash' then p_patch ->> 'phone_hash' else p.phone_hash end,
      current_resort_id = case when p_patch ? 'current_resort_id' then p_patch ->> 'current_resort_id' else p.current_resort_id end,
      updated_at = clock()
    where p.id = v_me
    returning p.* into v_row;
  -- data_exception: a value of the wrong JSON type or out of a column's range.
  exception when check_violation or not_null_violation or unique_violation or data_exception then
    raise exception 'invalid';
  end;
  if v_row.id is null then
    raise exception 'not_found';
  end if;
  return v_row;
end;
$$;

-- Height and weight have no column grant; this is the only way to read them,
-- and it only ever answers for the caller.
create function public.profile_private()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('height_cm', p.height_cm, 'weight_kg', p.weight_kg)
  from profiles p
  where p.id = require_uid();
$$;

-- App Store guideline 5.1.1: removes the account and everything it owns.
create function public.account_delete()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
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

  -- Unpublish the avatar. Storage refuses direct deletes unless this setting
  -- is on; the file itself is removed by the client through the Storage API
  -- before it calls this function (it owns `avatars/<id>/`).
  begin
    perform set_config('storage.allow_delete_query', 'true', true);
    delete from storage.objects o where o.bucket_id = 'avatars' and o.name like v_me::text || '/%';
  exception when others then
    raise warning 'account_delete: avatar rows not removed: %', sqlerrm;
  end;

  -- The rest (meets, progress, events, rate limits, jobs) cascades.
  delete from profiles p where p.id = v_me;
  delete from auth.users u where u.id = v_me;
end;
$$;

-- ================================================================== presence

create function public.presence_update(
  p_resort_id text, p_lon double precision, p_lat double precision,
  p_accuracy_m real, p_speed_ms real, p_heading_deg real, p_captured_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_now timestamptz := clock();
  v_cur presence;
begin
  if p_lon is null or p_lat is null or p_captured_at is null
     or p_lon not between -180 and 180 or p_lat not between -90 and 90 then
    raise exception 'invalid';
  end if;
  if p_resort_id is not null
     and not exists (select 1 from resorts r where r.id = p_resort_id and r.published) then
    raise exception 'resort_not_published';
  end if;

  select pr.* into v_cur from presence pr where pr.user_id = v_me for update;
  if found then
    -- At most one stored fix per 2 s; extra calls are dropped, not errors.
    if v_cur.received_at > v_now - interval '2 seconds' then
      return;
    end if;
    -- Monotonic sender time (I-19). A stored time in the future means the
    -- phone's clock was wrong and has since been corrected: let it through.
    if p_captured_at <= v_cur.captured_at and v_cur.captured_at <= v_now + interval '1 minute' then
      return;
    end if;
    update presence pr set
      resort_id = p_resort_id, lon = p_lon, lat = p_lat, accuracy_m = p_accuracy_m,
      speed_ms = p_speed_ms, heading_deg = p_heading_deg, captured_at = p_captured_at,
      received_at = v_now, app_build = request_app_build()
    where pr.user_id = v_me;
  else
    insert into presence (user_id, resort_id, lon, lat, accuracy_m, speed_ms, heading_deg,
                          captured_at, received_at, app_build)
    values (v_me, p_resort_id, p_lon, p_lat, p_accuracy_m, p_speed_ms, p_heading_deg,
            p_captured_at, v_now, request_app_build())
    on conflict (user_id) do nothing;
  end if;
end;
$$;

-- Friends' fresh positions at a resort, plus the caller's meet partner.
create function public.presence_snapshot(p_resort_id text)
returns setof public.presence
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  return query
    select pr.*
    from presence pr
    where pr.user_id <> v_me
      and pr.received_at > clock() - interval '15 minutes'
      and is_accepted_friend(v_me, pr.user_id)
      and (pr.resort_id = p_resort_id
           or exists (
             select 1 from meets m
             where m.status in ('proposed', 'active')
               and ((m.proposer_id = v_me and m.invitee_id = pr.user_id)
                 or (m.proposer_id = pr.user_id and m.invitee_id = v_me))));
end;
$$;

-- ============================================================== device tokens

-- A token belongs to one phone. Registering it for this account removes it
-- from any other account, so the previous user's pushes stop arriving there.
create function public.device_token_register(p_token text, p_environment text, p_app_build text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{32,200}$'
     or p_environment is null or p_environment not in ('development', 'production') then
    raise exception 'invalid';
  end if;
  delete from device_tokens dt where dt.token = p_token and dt.user_id <> v_me;
  insert into device_tokens (user_id, token, environment, app_build, created_at, updated_at)
  values (v_me, p_token, p_environment, left(p_app_build, 32), clock(), clock())
  on conflict (user_id, token) do update
    set environment = excluded.environment, app_build = excluded.app_build, updated_at = excluded.updated_at;
end;
$$;

create function public.device_token_unregister(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  delete from device_tokens dt where dt.user_id = v_me and dt.token = p_token;
end;
$$;

-- =============================================================== client events

create function public.client_event(p_kind text, p_props jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  if p_kind is null or char_length(p_kind) not between 1 and 64
     or pg_column_size(coalesce(p_props, '{}'::jsonb)) > 8192 then
    raise exception 'invalid';
  end if;
  perform rate_limit(v_me, 'client_event', 300, interval '1 minute');
  insert into client_events (user_id, kind, props, at, app_build)
  values (v_me, p_kind, p_props, clock(), request_app_build());
end;
$$;

-- ====================================================================== meets

create function public.meet_propose(
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
     or p_proposer_eta_s < 0 or p_proposer_eta_sd_s < 0 then
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

  if is_blocked_between(v_me, p_invitee) then
    raise exception 'blocked';
  end if;
  if not is_accepted_friend(v_me, p_invitee) then
    raise exception 'not_friends';
  end if;
  if not exists (select 1 from resorts r where r.id = p_resort_id and r.published) then
    raise exception 'resort_not_published';
  end if;
  -- I-01: a meet may end only at a rendezvous in the active bundle.
  if not exists (
    select 1 from resort_active_bundle ab
    where ab.resort_id = p_resort_id and p_rendezvous_id = any (ab.rendezvous_ids)) then
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

create function public.meet_respond(
  p_meet_id uuid, p_accept boolean,
  p_invitee_eta_s int default null, p_invitee_eta_sd_s int default null,
  p_decline_reason text default null)
returns public.meets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_now timestamptz := clock();
  v_meet meets;
  v_reason text := coalesce(p_decline_reason, 'declined_by_user');
begin
  if p_accept is null or p_invitee_eta_s < 0 or p_invitee_eta_sd_s < 0 then
    raise exception 'invalid';
  end if;
  select m.* into v_meet from meets m where m.meet_id = p_meet_id for update;
  if not found or v_me not in (v_meet.proposer_id, v_meet.invitee_id) then
    raise exception 'not_participant';
  end if;
  -- Only the invitee answers. The proposer cannot accept their own proposal.
  if v_meet.invitee_id <> v_me then
    raise exception 'invalid_state';
  end if;
  if v_meet.status <> 'proposed' then
    raise exception 'meet_not_proposed';
  end if;

  if p_accept then
    if v_now >= v_meet.expires_at then
      raise exception 'meet_expired';
    end if;
    update meets m
    set status = 'active', responded_at = v_now,
        invitee_eta_s = p_invitee_eta_s, invitee_eta_sd_s = p_invitee_eta_sd_s
    where m.meet_id = p_meet_id
    returning m.* into v_meet;
  else
    if v_reason not in ('declined_by_user', 'declined_cannot_route') then
      raise exception 'invalid_reason';
    end if;
    update meets m
    set status = 'declined', end_reason = v_reason, responded_at = v_now, ended_at = v_now
    where m.meet_id = p_meet_id
    returning m.* into v_meet;
  end if;
  return v_meet;
end;
$$;

create function public.meet_progress_update(
  p_meet_id uuid, p_eta_s int, p_eta_sd_s int, p_remaining_m int,
  p_state text, p_fix_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_meet meets;
begin
  select m.* into v_meet from meets m where m.meet_id = p_meet_id;
  if not found or v_me not in (v_meet.proposer_id, v_meet.invitee_id) then
    raise exception 'not_participant';
  end if;
  if v_meet.status <> 'active' or p_fix_at is null
     or p_state is null or p_state not in ('navigating', 'rerouting', 'arrived', 'lost') then
    raise exception 'invalid_state';
  end if;
  -- A caller writes only their own row; a fix older than the stored one is
  -- ignored (I-19).
  insert into meet_progress as mp (meet_id, user_id, eta_s, eta_sd_s, remaining_m, state, fix_at, updated_at)
  values (p_meet_id, v_me, p_eta_s, p_eta_sd_s, p_remaining_m, p_state, p_fix_at, clock())
  on conflict (meet_id, user_id) do update
    set eta_s = excluded.eta_s, eta_sd_s = excluded.eta_sd_s, remaining_m = excluded.remaining_m,
        state = excluded.state, fix_at = excluded.fix_at, updated_at = excluded.updated_at
    where excluded.fix_at > mp.fix_at;
end;
$$;

create function public.meet_end(p_meet_id uuid, p_reason text)
returns public.meets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_meet meets;
  v_status text;
begin
  if p_reason is null
     or p_reason not in ('arrived', 'user_cancelled', 'status_blocks_route', 'partner_left') then
    raise exception 'invalid_reason';
  end if;
  select m.* into v_meet from meets m where m.meet_id = p_meet_id for update;
  if not found or v_me not in (v_meet.proposer_id, v_meet.invitee_id) then
    raise exception 'not_participant';
  end if;
  -- Terminal states never change; ending twice returns the same row.
  if v_meet.status not in ('proposed', 'active') then
    return v_meet;
  end if;

  if v_meet.status = 'proposed' then
    -- Only the proposer withdraws a proposal; the invitee declines instead.
    if v_meet.proposer_id <> v_me or p_reason <> 'user_cancelled' then
      raise exception 'invalid_state';
    end if;
    v_status := 'cancelled';
  else
    v_status := case p_reason
      when 'arrived' then 'completed'
      when 'user_cancelled' then 'cancelled'
      else 'invalidated'
    end;
  end if;

  update meets m
  set status = v_status, end_reason = p_reason, ended_at = clock()
  where m.meet_id = p_meet_id
  returning m.* into v_meet;
  return v_meet;
end;
$$;

-- The caller's non-terminal meet, or null.
create function public.meet_current()
returns public.meets
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_meet meets;
begin
  select m.* into v_meet
  from meets m
  where m.status in ('proposed', 'active') and v_me in (m.proposer_id, m.invitee_id)
  order by m.created_at desc
  limit 1;
  if not found then
    return null;
  end if;
  return v_meet;
end;
$$;

create function public.meet_history(p_limit int default 50)
returns setof public.meets
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  return query
    select m.*
    from meets m
    where v_me in (m.proposer_id, m.invitee_id)
    order by m.created_at desc
    limit greatest(least(coalesce(p_limit, 50), 200), 1);
end;
$$;

-- Server sweep, run by cron every minute. All expiries are server time (I-24).
create function public.expire_meets()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
  v_count int;
begin
  with proposed as (
    update meets m
    set status = 'expired', end_reason = 'timeout', ended_at = v_now
    where m.status = 'proposed' and m.expires_at <= v_now
    returning 1
  ), active as (
    -- No progress from either participant for 45 minutes, counted from the
    -- later expected arrival.
    update meets m
    set status = 'expired', end_reason = 'timeout', ended_at = v_now
    where m.status = 'active'
      and v_now >= m.responded_at
                   + make_interval(secs => greatest(coalesce(m.proposer_eta_s, 0), coalesce(m.invitee_eta_s, 0)))
                   + interval '45 minutes'
      and not exists (
        select 1 from meet_progress mp
        where mp.meet_id = m.meet_id and mp.updated_at > v_now - interval '45 minutes')
    returning 1
  )
  select (select count(*) from proposed) + (select count(*) from active) into v_count;
  return v_count;
end;
$$;

-- ================================================================== descents

-- p_descent: source, started_at, ended_at, content_hash, track (base64 of the
-- gzipped track), resort_id, device, app_build, and optionally
-- match {bundle_id, matcher_version, matched, coverage, confidence}.
create function public.descent_upsert(p_descent jsonb)
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
                               device, app_build, created_at)
    values (v_me, v_source, v_started, v_ended, v_hash, v_track, v_resort,
            left(p_descent ->> 'device', 80), left(p_descent ->> 'app_build', 32), clock())
    returning d.descent_id into v_id;
    v_created := true;
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

create function public.descent_delete(p_descent_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  delete from descents d where d.descent_id = p_descent_id and d.owner_id = v_me;
  if found then
    insert into jobs (kind, owner_id, run_after) values ('pace_recompute', v_me, clock())
    on conflict do nothing;
  end if;
end;
$$;

-- ============================================================ service: bundles

-- Moves a resort's active-bundle pointer. p_rendezvous_ids is the bundle's
-- rendezvous catalog; the trigger on resort_active_bundle invalidates any open
-- meet whose rendezvous is no longer in it.
create function public.bundle_publish(
  p_resort_id text, p_bundle_id text, p_rendezvous_ids text[], p_report jsonb, p_published_by text)
returns public.resort_active_bundle
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
  v_previous text;
  v_row resort_active_bundle;
begin
  if p_published_by is null or p_rendezvous_ids is null or cardinality(p_rendezvous_ids) = 0
     or not exists (select 1 from resort_bundles rb
                    where rb.bundle_id = p_bundle_id and rb.resort_id = p_resort_id) then
    raise exception 'invalid';
  end if;
  select ab.bundle_id into v_previous
  from resort_active_bundle ab
  where ab.resort_id = p_resort_id
  for update;

  insert into resort_active_bundle as ab (resort_id, bundle_id, rendezvous_ids, published_at, published_by)
  values (p_resort_id, p_bundle_id, p_rendezvous_ids, v_now, p_published_by)
  on conflict (resort_id) do update
    set bundle_id = excluded.bundle_id, rendezvous_ids = excluded.rendezvous_ids,
        published_at = excluded.published_at, published_by = excluded.published_by
  returning ab.* into v_row;

  insert into resort_bundle_publications (resort_id, bundle_id, published_at, published_by,
                                          previous_bundle_id, rendezvous_ids, report)
  values (p_resort_id, p_bundle_id, v_now, p_published_by, v_previous, p_rendezvous_ids, p_report);
  return v_row;
end;
$$;

-- Re-points a resort to a bundle it has published before.
create function public.bundle_rollback(p_resort_id text, p_bundle_id text)
returns public.resort_active_bundle
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pub resort_bundle_publications;
begin
  select pub.* into v_pub
  from resort_bundle_publications pub
  where pub.resort_id = p_resort_id and pub.bundle_id = p_bundle_id
  order by pub.published_at desc, pub.id desc
  limit 1;
  if not found then
    raise exception 'invalid';
  end if;
  return bundle_publish(p_resort_id, p_bundle_id, v_pub.rendezvous_ids, v_pub.report, 'rollback');
end;
$$;

-- ================================================================ service: jobs

-- Claims up to p_limit due jobs of one kind for 5 minutes. SKIP LOCKED lets
-- several workers claim at once without waiting on or double-taking a row.
create function public.jobs_claim(p_kind text, p_limit int default 1)
returns setof public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
begin
  return query
    update jobs j
    set leased_until = v_now + interval '5 minutes', attempts = j.attempts + 1
    where j.id in (
      select c.id
      from jobs c
      where c.kind = p_kind and c.run_after <= v_now
        and (c.leased_until is null or c.leased_until < v_now)
      order by c.run_after, c.id
      limit greatest(least(coalesce(p_limit, 1), 100), 1)
      for update skip locked)
    returning j.*;
end;
$$;

-- Success deletes the job. Failure releases it with backoff; after five
-- attempts it is dropped and the next cron tick queues a fresh one.
create function public.jobs_complete(p_id bigint, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_error is null then
    delete from jobs j where j.id = p_id;
    return;
  end if;
  update jobs j
  set leased_until = null,
      last_error = left(p_error, 500),
      run_after = clock() + least(interval '15 minutes', interval '30 seconds' * power(2, j.attempts))
  where j.id = p_id and j.attempts < 5;
  if not found then
    delete from jobs j where j.id = p_id;
  end if;
end;
$$;

-- ================================================================ service: push

-- Claims one batch of notifications for the push worker, with each row's
-- device tokens. Before claiming it retires rows that should not be sent:
-- older than 15 minutes, or a duplicate (same user, kind and meet) of a newer
-- waiting row or of one sent in the last 60 seconds.
create function public.push_outbox_claim(p_limit int default 25)
returns table (id bigint, user_id uuid, kind text, payload jsonb, tokens jsonb)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_now timestamptz := clock();
begin
  update push_outbox o
  set sent_at = v_now, last_error = 'stale'
  where o.sent_at is null and o.created_at < v_now - interval '15 minutes';

  update push_outbox o
  set sent_at = v_now, last_error = 'collapsed'
  where o.sent_at is null
    and o.payload ? 'meet_id'
    and exists (
      select 1 from push_outbox n
      where n.id <> o.id and n.user_id = o.user_id and n.kind = o.kind
        and n.payload ->> 'meet_id' = o.payload ->> 'meet_id'
        and ((n.sent_at is null and n.id > o.id)
          or (n.sent_at is not null and n.last_error is null
              and n.sent_at > v_now - interval '60 seconds')));

  return query
    with due as (
      select o.id
      from push_outbox o
      where o.sent_at is null and (o.leased_until is null or o.leased_until < v_now)
      order by o.id
      limit greatest(least(coalesce(p_limit, 25), 100), 1)
      for update skip locked
    ), claimed as (
      update push_outbox o
      set leased_until = v_now + interval '2 minutes', attempts = o.attempts + 1
      from due
      where o.id = due.id
      returning o.id, o.user_id, o.kind, o.payload
    )
    select c.id, c.user_id, c.kind, c.payload,
           coalesce((
             select jsonb_agg(jsonb_build_object('token', dt.token, 'environment', dt.environment))
             from device_tokens dt
             where dt.user_id = c.user_id), '[]'::jsonb)
    from claimed c
    order by c.id;
end;
$$;

-- Records the outcome of one claimed row and removes tokens APNs reported dead.
create function public.push_outbox_complete(p_id bigint, p_error text default null, p_dead_tokens text[] default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
begin
  if p_dead_tokens is not null then
    delete from device_tokens dt
    using push_outbox o
    where o.id = p_id and dt.user_id = o.user_id and dt.token = any (p_dead_tokens);
  end if;
  if p_error is null then
    update push_outbox o
    set sent_at = v_now, last_error = null, leased_until = null
    where o.id = p_id and o.sent_at is null;
  else
    update push_outbox o
    set last_error = left(p_error, 500),
        leased_until = v_now + interval '30 seconds' * o.attempts,
        sent_at = case when o.attempts >= 5 then v_now else null end
    where o.id = p_id and o.sent_at is null;
  end if;
end;
$$;

-- ======================================================================= cron

create function public.presence_cleanup()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  with gone as (
    delete from presence pr where pr.received_at < clock() - interval '2 hours' returning 1
  )
  select count(*) into v_count from gone;
  return v_count;
end;
$$;

create function public.enqueue_status_refresh()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  with queued as (
    insert into jobs (kind, resort_id, run_after)
    select 'status_refresh', r.id, clock()
    from resorts r
    where r.published and r.status_mode = 'live'
    on conflict do nothing
    returning 1
  )
  select count(*) into v_count from queued;
  if v_count > 0 then
    perform worker_ping('status-refresh', v_count);
  end if;
  return v_count;
end;
$$;

-- Hourly rows for resorts without a live provider, so clients have one code
-- path. No worker and no job: the row is `source = scheduled` with empty
-- `groups`, which says "no live information for any lift; use operating
-- hours". (The lift groups themselves live in the bundle, not here.)
create function public.scheduled_status_rows()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
  v_count int;
begin
  with written as (
    insert into resort_status (resort_id, observed_at, expires_at, source, groups, groomed, created_at)
    select r.id, v_now, v_now + interval '75 minutes', 'scheduled', '{}'::jsonb, '{}'::text[], v_now
    from resorts r
    where r.published and r.status_mode = 'scheduled_only'
    returning 1
  )
  select count(*) into v_count from written;
  return v_count;
end;
$$;

create function public.enqueue_conditions_refresh()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  with queued as (
    insert into jobs (kind, resort_id, run_after)
    select 'conditions_refresh', r.id, clock()
    from resorts r
    where r.published
    on conflict do nothing
    returning 1
  )
  select count(*) into v_count from queued;
  if v_count > 0 then
    perform worker_ping('conditions-refresh', v_count);
  end if;
  return v_count;
end;
$$;

-- Drains the queue: pings a worker once per job that has been due and
-- unclaimed for 20 seconds (the enqueue functions ping for the first wave).
-- Run every minute, 20 at a time, about 160 resorts clear in 8 minutes.
create function public.worker_ping_pending(p_kind text, p_function text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
  v_count int;
begin
  select count(*) into v_count
  from jobs j
  where j.kind = p_kind and j.run_after <= v_now - interval '20 seconds'
    and (j.leased_until is null or j.leased_until < v_now);
  if v_count > 0 then
    perform worker_ping(p_function, v_count);
  end if;
  return v_count;
end;
$$;

create function public.push_drain_ping()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
begin
  if exists (select 1 from push_outbox o
             where o.sent_at is null and (o.leased_until is null or o.leased_until < v_now)) then
    return worker_ping('push-drain', 1);
  end if;
  return false;
end;
$$;

-- Daily retention for append-only tables.
create function public.housekeeping()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock();
begin
  delete from resort_status s where s.created_at < v_now - interval '7 days';
  delete from resort_conditions c where c.created_at < v_now - interval '7 days';
  delete from push_outbox o where o.created_at < v_now - interval '7 days';
  delete from rate_limits rl where rl.window_start < v_now - interval '1 day';
  delete from client_events ce where ce.at < v_now - interval '90 days';
  delete from jobs j where j.attempts >= 8 or j.created_at < v_now - interval '1 day';
end;
$$;
