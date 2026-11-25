-- 0025 The owner's decisions of 22 Nov 2026. specs/03-PROTOCOL.md sections 1, 2, 5
-- and 6, specs/04-SCHEMA.md sections 2, 3, 4, 6, 9 and 10.
--
-- Each function below is the latest definition (named per section) with only
-- the change applied:
--   - a block is hidden: nobody learns from any RPC, table or event that they
--     were blocked. A request to someone who blocked you is stored and looks
--     pending to you, but the blocker never sees it and gets no event or push;
--     search, contact matching and add codes treat the blocker as a stranger;
--     a meet to them is `not_friends`. `blocked` stays a known error code for
--     older builds, but nothing raises it;
--   - a meet completes on its own once both skiers' progress says `arrived`;
--   - a deleted account leaves nothing in `user_reports` or in
--     `realtime.messages`;
--   - `profiles.phone_hash` is gone; old builds may still send it and it is
--     ignored;
--   - `apple_tokens` holds each Sign in with Apple refresh token for the
--     revocation an account deletion must do (an edge function writes and
--     reads it).

-- ======================================================== hidden requests

-- A request is hidden when its addressee has blocked its requester. Only the
-- requester can create one (the blocker cannot ask the person they blocked),
-- so the row the policy hides is always a request into the void.
drop policy friendships_read on public.friendships;
create policy friendships_read on public.friendships
  for select to authenticated
  using ((select auth.uid()) = requester_id
         or ((select auth.uid()) = addressee_id
             and not exists (
               select 1 from public.user_blocks ub
               where ub.blocker_id = addressee_id and ub.blocked_id = requester_id)));

-- ============================================================== friend_request

-- 0004's function. The person who blocked you sees nothing: the request is
-- stored, so your own lists and search show it pending as for anyone who
-- never answers, but `friendships_notify` sends them no event or push and
-- every read of theirs leaves it out. Someone you blocked is, to you, nobody
-- you can ask: `invalid`, as for an unknown user.
create or replace function public.friend_request(p_user uuid)
returns public.friendships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_row friendships;
  v_hidden boolean;
begin
  if p_user is null or p_user = v_me then
    raise exception 'invalid';
  end if;
  if not exists (select 1 from profiles p where p.id = p_user) then
    raise exception 'invalid';
  end if;
  perform lock_users(v_me, p_user);
  if exists (select 1 from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p_user) then
    raise exception 'invalid';
  end if;
  v_hidden := exists (select 1 from user_blocks ub where ub.blocker_id = p_user and ub.blocked_id = v_me);

  select f.* into v_row
  from friendships f
  where (f.requester_id = v_me and f.addressee_id = p_user)
     or (f.requester_id = p_user and f.addressee_id = v_me);
  if found then
    -- The other person already asked: accept. Otherwise this is a repeat.
    -- Under a hidden block there is nothing of theirs to accept.
    if not v_hidden and v_row.status = 'pending' and v_row.addressee_id = v_me then
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

-- ============================================================== friend_respond

-- 0004's function. A hidden request does not exist for the blocker, even by
-- id: `not_found`, as for anyone else's request.
create or replace function public.friend_respond(p_friendship_id uuid, p_accept boolean)
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
  if v_row.addressee_id = v_me and exists (
       select 1 from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = v_row.requester_id) then
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

-- ================================================================ unblock_user

-- 0004's function. A request that waited unseen behind the block is removed
-- first, so it does not surface as a stale request the moment the block
-- lifts. To its sender that reads as a decline (`friend.removed`), which is
-- what any unanswered request may become.
create or replace function public.unblock_user(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  delete from friendships f
  where f.requester_id = p_user and f.addressee_id = v_me and f.status = 'pending'
    and exists (select 1 from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p_user);
  delete from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p_user;
end;
$$;

-- ========================================================= friendships_notify

-- 0005's function. A hidden request tells the blocker nothing when it is made
-- or when it goes away (the sender withdrawing it or deleting their account).
create or replace function public.friendships_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := (select auth.uid());
  v_hidden boolean;
begin
  if tg_op = 'DELETE' then
    v_hidden := exists (select 1 from user_blocks ub
                        where ub.blocker_id = old.addressee_id and ub.blocked_id = old.requester_id);
  else
    v_hidden := exists (select 1 from user_blocks ub
                        where ub.blocker_id = new.addressee_id and ub.blocked_id = new.requester_id);
  end if;
  if tg_op = 'INSERT' then
    if v_hidden then
      return null;
    end if;
    perform emit('user:' || new.addressee_id::text, 'friend.requested',
                 profile_brief(new.requester_id) || jsonb_build_object('friendship_id', new.id));
    perform push_enqueue(new.addressee_id, 'friend.requested',
                 profile_brief(new.requester_id) || jsonb_build_object('friendship_id', new.id));
  elsif tg_op = 'UPDATE' then
    if old.status = 'pending' and new.status = 'accepted' then
      perform emit('user:' || new.requester_id::text, 'friend.accepted',
                   profile_brief(new.addressee_id) || jsonb_build_object('friendship_id', new.id));
      perform push_enqueue(new.requester_id, 'friend.accepted',
                   profile_brief(new.addressee_id) || jsonb_build_object('friendship_id', new.id));
    end if;
  else
    if v_actor is distinct from old.addressee_id and not v_hidden then
      perform emit('user:' || old.addressee_id::text, 'friend.removed',
                   profile_brief(old.requester_id) || jsonb_build_object('friendship_id', old.id));
    end if;
    if v_actor is distinct from old.requester_id then
      perform emit('user:' || old.requester_id::text, 'friend.removed',
                   profile_brief(old.addressee_id) || jsonb_build_object('friendship_id', old.id));
    end if;
  end if;
  return null;
end;
$$;

-- ============================================================= social_snapshot

-- 0016's function. `pending_in` leaves out a request from someone the caller
-- blocked. The other lists are unchanged: the sender's `pending_out` still
-- shows it.
create or replace function public.social_snapshot()
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
               'avatar_url', p.avatar_url, 'since', f.responded_at,
               'ability', p.ability, 'equipment', p.equipment,
               'stats', lifetime_stats(p.id),
               'last_seen', (
                 select jsonb_build_object('resort_id', pr.resort_id, 'at', pr.captured_at)
                 from presence pr
                 where pr.user_id = p.id and pr.received_at > clock() - interval '15 minutes'))
             order by p.display_name, p.id)
      from friendships f
      join profiles p
        on p.id = case when f.requester_id = v_me then f.addressee_id else f.requester_id end
      where f.status = 'accepted' and v_me in (f.requester_id, f.addressee_id)
        and not is_blocked_between(v_me, p.id)), '[]'::jsonb),
    'pending_in', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', f.created_at)
             order by f.created_at desc, f.id)
      from friendships f
      join profiles p on p.id = f.requester_id
      where f.status = 'pending' and f.addressee_id = v_me
        and not exists (select 1 from user_blocks ub
                        where ub.blocker_id = v_me and ub.blocked_id = f.requester_id)), '[]'::jsonb),
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

-- ================================================================== find_users

-- 0004's function. The person who blocked you matches as for anyone (leaving
-- them out would tell you); someone you blocked stays out of your matches.
-- `p_phone_hashes` is still accepted, since build 3.0.0 sends it by name, and
-- ignored: no phone hash is stored any more.
create or replace function public.find_users(p_email_hashes text[], p_phone_hashes text[])
returns table (id uuid, display_name text, avatar_url text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_me uuid := require_uid();
begin
  if coalesce(cardinality(p_email_hashes), 0) > 50 then
    raise exception 'invalid';
  end if;
  perform rate_limit(v_me, 'find_users', 20, interval '1 minute');
  return query
    select p.id, p.display_name, p.avatar_url
    from profiles p
    where p.id <> v_me
      and p.email_hash = any (coalesce(p_email_hashes, '{}'::text[]))
      and not exists (select 1 from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p.id);
end;
$$;

-- ================================================================ search_users

-- 0019's function, with the same rule as find_users: hidden from you is only
-- someone you blocked.
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
      and not display_name_is_placeholder(p.display_name)
      and lower(display_name_normalize(p.display_name)) like '%' || v_pattern || '%' escape '\'
      and not exists (select 1 from user_blocks ub where ub.blocker_id = v_me and ub.blocked_id = p.id)
    order by
      case when lower(display_name_normalize(p.display_name)) like v_pattern || '%' escape '\' then 0 else 1 end,
      lower(p.display_name), p.id
    limit 20;
end;
$$;

-- =========================================================== friend_code_owner

-- 0016's function. A code held by someone who blocked you resolves as for
-- anyone, and a request sent with it is hidden like any other; the code of
-- someone you blocked answers as unknown.
create or replace function public.friend_code_owner(p_me uuid, p_code text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select fc.user_id
  from friend_codes fc
  where fc.code = friend_code_normalize(p_code)
    and not exists (select 1 from user_blocks ub where ub.blocker_id = p_me and ub.blocked_id = fc.user_id);
$$;

-- ================================================================ meet_propose

-- 0023's function without its block check. A block removes the friendship, so
-- `is_accepted_friend` already refuses the pair, with the code a non-friend
-- gets.
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

-- ======================================================== meet_progress_update

-- 0023's function. When, after this fix, both skiers' stored progress says
-- `arrived`, the meet completes here as `meet_end(arrived)` completes it
-- (status `completed`, end reason `arrived`, `meet.updated` to both, the
-- caller recorded in `ended_by`), and both get a `meet.ended` push. The meet
-- row is locked first, so two arrivals at the same moment run one after the
-- other and the second sees the first; completing only an `active` meet
-- makes it happen once.
create or replace function public.meet_progress_update(
  p_meet_id uuid, p_eta_s int, p_eta_sd_s int, p_remaining_m int,
  p_state text, p_fix_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_now timestamptz := clock();
  v_meet meets;
begin
  select m.* into v_meet from meets m where m.meet_id = p_meet_id for update;
  if not found or v_me not in (v_meet.proposer_id, v_meet.invitee_id) then
    raise exception 'not_participant';
  end if;
  if v_meet.status <> 'active' or p_fix_at is null
     or p_state is null or p_state not in ('navigating', 'rerouting', 'arrived', 'lost') then
    raise exception 'invalid_state';
  end if;
  -- A caller writes only their own row.
  insert into meet_progress as mp (meet_id, user_id, eta_s, eta_sd_s, remaining_m, state, fix_at, updated_at)
  values (p_meet_id, v_me, p_eta_s, p_eta_sd_s, p_remaining_m, p_state,
          least(p_fix_at, v_now + interval '1 minute'), v_now)
  on conflict (meet_id, user_id) do update
    set eta_s = excluded.eta_s, eta_sd_s = excluded.eta_sd_s, remaining_m = excluded.remaining_m,
        state = excluded.state, fix_at = excluded.fix_at, updated_at = excluded.updated_at
    where excluded.fix_at >= mp.fix_at or mp.fix_at > v_now + interval '1 minute';

  if (select count(*) from meet_progress mp
      where mp.meet_id = p_meet_id and mp.state = 'arrived'
        and mp.user_id in (v_meet.proposer_id, v_meet.invitee_id)) = 2 then
    update meets m
    set status = 'completed', end_reason = 'arrived', ended_at = v_now
    where m.meet_id = p_meet_id and m.status = 'active'
    returning m.* into v_meet;
    if found then
      perform push_enqueue(v_meet.proposer_id, 'meet.ended', meet_push_payload(v_meet, v_meet.proposer_id));
      perform push_enqueue(v_meet.invitee_id, 'meet.ended', meet_push_payload(v_meet, v_meet.invitee_id));
    end if;
  end if;
end;
$$;

-- ============================================================== profile_update

-- 0022's function. `phone_hash` is dropped silently like `email_hash`, so a
-- patch from a build that still sends it applies.
create or replace function public.profile_update(p_patch jsonb)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_key text;
  v_row profiles;
  v_name text;
  v_problem text;
  v_constraint text;
  v_allowed constant text[] := array['display_name', 'avatar_url', 'ability', 'max_difficulty',
    'baseline_speeds', 'equipment', 'avoid', 'max_pitch_deg', 'height_cm', 'weight_kg',
    'current_resort_id'];
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'invalid';
  end if;
  p_patch := p_patch - 'email_hash' - 'phone_hash';
  for v_key in select jsonb_object_keys(p_patch) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'invalid';
    end if;
  end loop;
  if p_patch ? 'display_name' then
    if jsonb_typeof(p_patch -> 'display_name') <> 'string' then
      raise exception 'invalid';
    end if;
    v_problem := display_name_problem(p_patch ->> 'display_name', v_me);
    if v_problem is not null then
      raise exception '%', v_problem;
    end if;
    v_name := display_name_normalize(p_patch ->> 'display_name');
  end if;
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
      display_name = case when p_patch ? 'display_name' then v_name else p.display_name end,
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
      current_resort_id = case when p_patch ? 'current_resort_id' then p_patch ->> 'current_resort_id' else p.current_resort_id end,
      updated_at = clock()
    where p.id = v_me
    returning p.* into v_row;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'profiles_display_name_lower' then
        raise exception 'name_taken';
      end if;
      raise exception 'invalid';
    -- data_exception: a value of the wrong JSON type or out of a column's range.
    when check_violation or not_null_violation or data_exception then
      raise exception 'invalid';
  end;
  if v_row.id is null then
    raise exception 'not_found';
  end if;
  return v_row;
end;
$$;

-- ============================================================ profiles.phone_hash

-- Nothing has set it since contacts moved to email; after the two functions
-- above nothing reads it either. Its unique index goes with it.
alter table public.profiles drop column phone_hash;

-- ============================================================== account_delete

-- 0023's function, now also leaving nothing in `user_reports` or
-- `realtime.messages`:
--   - reports about the user are deleted: they hold the name and photo path
--     copied at report time, and the reporter's note may name them, so
--     keeping the row would keep their personal data; reports they filed keep
--     their rows without the reporter's id (the foreign key's `set null`);
--   - every stored realtime message that mentions the user, and everything on
--     their own topic, is deleted before this call writes its own events. The
--     events this call then sends to partners and friends (`meet.updated`,
--     `friend.removed`) are kept so their phones catch up, with the name and
--     photo stripped. Realtime is a hint channel: a refusal here must never
--     block the deletion, so both steps only warn.
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

-- Reports about accounts deleted before this migration: the account's id is
-- already gone and only its copied name and photo path remain.
delete from public.user_reports where reported_id is null;

-- ================================================================ apple_tokens

-- The Sign in with Apple refresh token of each account that signed in with
-- Apple, kept so deleting the account can revoke it (App Store guideline
-- 5.1.1(v)). An edge function writes it after sign-in and reads it before
-- `account_delete`; the row goes with the auth user. Service role only: no
-- policy, no client grant.
create table public.apple_tokens (
  user_id uuid primary key references auth.users (id) on delete cascade,
  refresh_token text not null,
  updated_at timestamptz default now()
);
alter table public.apple_tokens enable row level security;
revoke all on public.apple_tokens from public, anon, authenticated;

-- `create or replace` keeps each replaced function's grants, and no new
-- function is created, so no execute privilege changes.
