-- 0005 Triggers (specs/04-SCHEMA.md section 4) and, at the end, the execute
-- privileges for every function in `public`.
--
-- Transition triggers bind every writer, including the service role and the
-- table owner: a forged row is rejected no matter who writes it.

-- ================================================================ friendships

create function public.friendships_transitions()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'invalid_state';
    end if;
    new.responded_at := null;
    return new;
  end if;
  if new is not distinct from old then
    return new;
  end if;
  if new.id <> old.id or new.requester_id <> old.requester_id or new.addressee_id <> old.addressee_id
     or new.created_at <> old.created_at
     or old.status <> 'pending' or new.status <> 'accepted' then
    raise exception 'invalid_state';
  end if;
  new.responded_at := coalesce(new.responded_at, clock());
  return new;
end;
$$;

create trigger friendships_transitions
  before insert or update on public.friendships
  for each row execute function public.friendships_transitions();

-- Friend events go to the counterpart: the person who did not make the change.
create function public.friendships_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if tg_op = 'INSERT' then
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
    if v_actor is distinct from old.addressee_id then
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

create trigger friendships_notify
  after insert or update or delete on public.friendships
  for each row execute function public.friendships_notify();

-- ====================================================================== meets

-- The transition table of specs/03-PROTOCOL.md section 1.
create function public.meets_transitions()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_ok boolean;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'proposed' or new.end_reason is not null or new.responded_at is not null
       or new.ended_at is not null or new.superseded_by is not null then
      raise exception 'invalid_state';
    end if;
    return new;
  end if;

  if new is not distinct from old then
    return new;
  end if;
  if new.meet_id <> old.meet_id or new.resort_id <> old.resort_id
     or new.rendezvous_id <> old.rendezvous_id
     or new.proposer_id <> old.proposer_id or new.invitee_id <> old.invitee_id
     or new.created_at <> old.created_at or new.expires_at <> old.expires_at
     or new.bundle_id is distinct from old.bundle_id
     or new.proposer_eta_s is distinct from old.proposer_eta_s
     or new.proposer_eta_sd_s is distinct from old.proposer_eta_sd_s then
    raise exception 'invalid_state';
  end if;

  if old.status = 'proposed' then
    v_ok := (new.status = 'active' and new.end_reason is null)
         or (new.status = 'declined' and new.end_reason in ('declined_by_user', 'declined_cannot_route'))
         or (new.status = 'cancelled' and new.end_reason = 'user_cancelled')
         or (new.status = 'expired' and new.end_reason = 'timeout')
         or (new.status = 'invalidated'
             and new.end_reason in ('superseded', 'rendezvous_removed', 'partner_left'));
  elsif old.status = 'active' then
    v_ok := (new.status = 'completed' and new.end_reason = 'arrived')
         or (new.status = 'cancelled' and new.end_reason = 'user_cancelled')
         or (new.status = 'expired' and new.end_reason = 'timeout')
         or (new.status = 'invalidated'
             and new.end_reason in ('status_blocks_route', 'partner_left', 'rendezvous_removed'))
    ;
    -- The invitee's estimate and the response time are fixed once active.
    if new.invitee_eta_s is distinct from old.invitee_eta_s
       or new.invitee_eta_sd_s is distinct from old.invitee_eta_sd_s
       or new.responded_at is distinct from old.responded_at then
      v_ok := false;
    end if;
  else
    -- Terminal states never change.
    v_ok := false;
  end if;
  if not coalesce(v_ok, false) then
    raise exception 'invalid_state';
  end if;
  if new.superseded_by is distinct from old.superseded_by
     and new.end_reason is distinct from 'superseded' then
    raise exception 'invalid_state';
  end if;

  if new.status = 'active' then
    new.responded_at := coalesce(new.responded_at, clock());
  else
    new.ended_at := coalesce(new.ended_at, clock());
  end if;
  return new;
end;
$$;

create trigger meets_transitions
  before insert or update on public.meets
  for each row execute function public.meets_transitions();

-- What a push needs to render without another query: the meet, the reason and
-- the other person's name as it was when the event happened.
create function public.meet_push_payload(p_meet public.meets, p_recipient uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'meet_id', (p_meet).meet_id,
    'resort_id', (p_meet).resort_id,
    'rendezvous_id', (p_meet).rendezvous_id,
    'status', (p_meet).status,
    'end_reason', (p_meet).end_reason,
    'responded_at', (p_meet).responded_at,
    'partner_id', o.other,
    'partner_name', (select p.display_name from public.profiles p where p.id = o.other))
  from (select case when (p_meet).proposer_id = p_recipient
                    then (p_meet).invitee_id else (p_meet).proposer_id end as other) o;
$$;

create function public.meets_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := (select auth.uid());
  v_row jsonb := to_jsonb(new);
begin
  if tg_op = 'INSERT' then
    perform emit('user:' || new.invitee_id::text, 'meet.proposed', v_row);
    perform push_enqueue(new.invitee_id, 'meet.proposed', meet_push_payload(new, new.invitee_id));
    return null;
  end if;
  if new.status = old.status then
    return null;
  end if;

  perform emit('user:' || new.proposer_id::text, 'meet.updated', v_row);
  perform emit('user:' || new.invitee_id::text, 'meet.updated', v_row);

  -- Pushes: exactly the set in specs/11-SETUP-RELEASE.md section 5.
  if new.status = 'active' then
    perform push_enqueue(new.proposer_id, 'meet.accepted', meet_push_payload(new, new.proposer_id));
  elsif new.status = 'declined' then
    perform push_enqueue(new.proposer_id, 'meet.declined', meet_push_payload(new, new.proposer_id));
  elsif new.status = 'expired' then
    perform push_enqueue(new.proposer_id, 'meet.expired', meet_push_payload(new, new.proposer_id));
    if old.status = 'active' then
      perform push_enqueue(new.invitee_id, 'meet.expired', meet_push_payload(new, new.invitee_id));
    end if;
  elsif new.status in ('cancelled', 'invalidated') and new.end_reason <> 'superseded' then
    -- To whoever did not end it; to both when the server did. A superseded
    -- proposal is followed at once by the new one, which carries its own push.
    if v_actor is distinct from new.proposer_id then
      perform push_enqueue(new.proposer_id, 'meet.ended', meet_push_payload(new, new.proposer_id));
    end if;
    if v_actor is distinct from new.invitee_id then
      perform push_enqueue(new.invitee_id, 'meet.ended', meet_push_payload(new, new.invitee_id));
    end if;
  end if;
  return null;
end;
$$;

create trigger meets_notify
  after insert or update on public.meets
  for each row execute function public.meets_notify();

create function public.meet_progress_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet meets;
  v_other uuid;
begin
  select m.* into v_meet from meets m where m.meet_id = new.meet_id;
  if not found then
    return null;
  end if;
  v_other := case when v_meet.proposer_id = new.user_id then v_meet.invitee_id else v_meet.proposer_id end;

  perform emit('user:' || v_other::text, 'meet.progress', jsonb_build_object(
    'meet_id', new.meet_id, 'user_id', new.user_id, 'eta_s', new.eta_s, 'eta_sd_s', new.eta_sd_s,
    'remaining_m', new.remaining_m, 'state', new.state, 'fix_at', new.fix_at));

  if new.state = 'arrived' and (tg_op = 'INSERT' or old.state is distinct from 'arrived') then
    perform push_enqueue(v_other, 'meet.partner_arrived', meet_push_payload(v_meet, v_other));
  end if;
  return null;
end;
$$;

create trigger meet_progress_notify
  after insert or update on public.meet_progress
  for each row execute function public.meet_progress_notify();

-- =================================================================== presence

-- Positions go only to presence_recipients(): no display name, no public topic.
create function public.presence_fanout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recipient uuid;
  v_data jsonb := jsonb_build_object(
    'user_id', new.user_id, 'resort_id', new.resort_id, 'lon', new.lon, 'lat', new.lat,
    'accuracy_m', new.accuracy_m, 'speed_ms', new.speed_ms, 'heading_deg', new.heading_deg,
    'captured_at', new.captured_at);
begin
  for v_recipient in select r from presence_recipients(new.user_id, new.resort_id) r loop
    perform emit('user:' || v_recipient::text, 'presence', v_data);
  end loop;
  return null;
end;
$$;

create trigger presence_fanout
  after insert or update on public.presence
  for each row execute function public.presence_fanout();

-- ==================================================================== resorts

create function public.resort_status_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform emit('resort:' || new.resort_id, 'resort.status', to_jsonb(new));
  return null;
end;
$$;

create trigger resort_status_notify
  after insert on public.resort_status
  for each row execute function public.resort_status_notify();

-- A new active bundle that lacks a rendezvous ends every open meet there.
create function public.bundle_publish_invalidate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update meets m
  set status = 'invalidated', end_reason = 'rendezvous_removed', ended_at = clock()
  where m.resort_id = new.resort_id
    and m.status in ('proposed', 'active')
    and not (m.rendezvous_id = any (new.rendezvous_ids));
  return null;
end;
$$;

create trigger bundle_publish_invalidate
  after insert or update on public.resort_active_bundle
  for each row execute function public.bundle_publish_invalidate();

-- =================================================================== profiles

create function public.profiles_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(left(btrim(coalesce(
      new.raw_user_meta_data ->> 'display_name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name', '')), 40), ''), 'Skier'))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger profiles_from_auth
  after insert on auth.users
  for each row execute function public.profiles_from_auth();

-- ======================================================== execute privileges
-- The API surface, in one place. Everything is closed first; then the client
-- RPCs are opened to `authenticated` by name. `anon` can call nothing.
-- The service role keeps execute on everything (workers and the pipeline).

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

grant execute on function
  public.clock(),
  public.is_accepted_friend(uuid, uuid),
  public.friend_request(uuid),
  public.friend_respond(uuid, boolean),
  public.friend_remove(uuid),
  public.block_user(uuid),
  public.unblock_user(uuid),
  public.find_users(text[], text[]),
  public.social_snapshot(),
  public.profile_update(jsonb),
  public.profile_private(),
  public.account_delete(),
  public.presence_update(text, double precision, double precision, real, real, real, timestamptz),
  public.presence_snapshot(text),
  public.device_token_register(text, text, text),
  public.device_token_unregister(text),
  public.client_event(text, jsonb),
  public.meet_propose(uuid, uuid, text, text, text, int, int, uuid),
  public.meet_respond(uuid, boolean, int, int, text),
  public.meet_progress_update(uuid, int, int, int, text, timestamptz),
  public.meet_end(uuid, text),
  public.meet_current(),
  public.meet_history(int),
  public.descent_upsert(jsonb),
  public.descent_delete(uuid)
to authenticated;
