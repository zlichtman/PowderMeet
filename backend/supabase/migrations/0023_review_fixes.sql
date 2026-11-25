-- 0023 Fixes from the 22 Nov 2026 tree review. specs/03-PROTOCOL.md sections 1, 2
-- and 3, specs/04-SCHEMA.md sections 1, 4, 6 and 9.
--
-- Each function below is the latest definition (named per section) with only
-- the fix applied:
--   - account_delete leaves the deleted user in nobody's queued push;
--   - meet_propose is rate-limited, like every other RPC that pushes to
--     someone else;
--   - meet estimates are capped, so one bad value cannot keep a meet open for
--     decades;
--   - a progress fix from a phone whose clock runs ahead no longer freezes
--     progress, and a state change on the same fix is kept;
--   - only a confirmed email address gets a contact hash;
--   - presence broadcasts are purged from realtime.messages after the TTL;
--   - an ended meet records who ended it (`ended_by`).

-- ================================================================ meets.ended_by

-- Who moved the meet to its terminal state: the participant whose request did
-- it (meet_end, a decline, a supersede, friend_remove, block_user,
-- account_delete), or null when the server did (the expiry sweep, a bundle
-- publish). The app needs it to say "You left" or "<name> left". Never a third
-- person's id.
alter table public.meets add column ended_by uuid;
alter table public.meets add constraint meets_ended_by_participant
  check (ended_by is null or ended_by = proposer_id or ended_by = invitee_id);

-- Runs before `meets_transitions` (name order), which still decides whether
-- the transition is allowed. Nobody writes `ended_by` directly: it is set here
-- once, on the move to a terminal state, and never changes after.
create function public.meets_ended_by()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if tg_op = 'INSERT' then
    new.ended_by := null;
    return new;
  end if;
  if old.status in ('proposed', 'active') and new.status not in ('proposed', 'active') then
    new.ended_by := case when v_actor in (new.proposer_id, new.invitee_id) then v_actor end;
  else
    new.ended_by := old.ended_by;
  end if;
  return new;
end;
$$;

create trigger meets_ended_by
  before insert or update on public.meets
  for each row execute function public.meets_ended_by();

-- ================================================================ meet_propose

-- 0004's function with a rate limit after the idempotent retry (a retry is not
-- a new proposal) and estimates capped at a day.
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

-- ================================================================ meet_respond

-- 0004's function with the invitee's estimates capped at a day, as the
-- proposer's are: expire_meets waits for the larger one.
create or replace function public.meet_respond(
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
  if p_accept is null or p_invitee_eta_s not between 0 and 86400
     or p_invitee_eta_sd_s not between 0 and 86400 then
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

-- ======================================================== meet_progress_update

-- 0004's function. A phone whose clock ran ahead (D14) stored a future
-- `fix_at`, after which every honest fix was older and dropped: no
-- meet.progress events, a stale `updated_at`, and expire_meets could end a meet
-- both people were navigating. Now the stored time is clamped to a minute past
-- server time, and a stored time beyond that (written before this migration)
-- no longer blocks anything, as presence_update already allows. A fix at the
-- same time is applied, so a state change on the same fix reaches the partner:
-- only an older fix is ignored (I-19).
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
  select m.* into v_meet from meets m where m.meet_id = p_meet_id;
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
end;
$$;

-- ============================================================== account_delete

-- 0021's function, now also clearing the deleted user out of other people's
-- queued pushes (each carries a name, a photo path or an id, kept up to 7
-- days) and their own presence broadcasts. The `meet.ended` push this call
-- just queued for a partner is kept, so an offline partner still learns the
-- meet ended, but without who it was: it reads "A friend left".
create or replace function public.account_delete()
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

  -- Other people's pushes that name this user (meet pushes carry
  -- `partner_id`, friend pushes `user_id`).
  update push_outbox po
  set payload = po.payload - array['partner_id', 'partner_name', 'user_id', 'display_name', 'avatar_url']
  where po.kind = 'meet.ended' and po.sent_at is null
    and po.payload ->> 'partner_id' = v_me::text;
  delete from push_outbox po
  where po.payload ->> 'partner_id' = v_me::text or po.payload ->> 'user_id' = v_me::text;

  -- Positions this user broadcast to friends. Realtime is a hint channel: a
  -- refusal here must never block the deletion.
  begin
    delete from realtime.messages rm
    where rm.extension = 'broadcast' and rm.event = 'presence'
      and rm.payload -> 'data' ->> 'user_id' = v_me::text;
  exception when others then
    raise warning 'account_delete: presence broadcasts not purged: %', sqlerrm;
  end;

  -- Avatar files left behind (the client's own removal failed) are removed by
  -- the `avatar-sweep` worker through the Storage API once the profile is gone.
  -- The job has no owner, so it does not cascade away with the profile; the
  -- ping is sent after this transaction commits.
  insert into jobs (kind, run_after) values ('avatar_sweep', clock());
  perform worker_ping('avatar-sweep', 1);

  -- The rest (meets, progress, events, rate limits, jobs) cascades.
  delete from profiles p where p.id = v_me;
  delete from auth.users u where u.id = v_me;
end;
$$;

-- ============================================================ presence_cleanup

-- 0004's function. Every presence broadcast is also a row in
-- realtime.messages, holding lon and lat, which nothing read past the 15 minute
-- TTL and nothing removed: a location history on each friend's topic for as
-- long as the platform keeps messages. Those rows go once the TTL has passed,
-- judged by the envelope's server time (`at`). The count returned is still the
-- presence rows removed.
create or replace function public.presence_cleanup()
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

  begin
    delete from realtime.messages rm
    where rm.extension = 'broadcast' and rm.event = 'presence'
      and (rm.payload ->> 'at')::timestamptz < clock() - interval '15 minutes';
  exception when others then
    raise warning 'presence_cleanup: presence broadcasts not purged: %', sqlerrm;
  end;
  return v_count;
end;
$$;

-- ================================================================ email hash

-- 0022's trigger function, hashing only a confirmed address. With "Confirm
-- email" on, a sign-up inserts its auth row unconfirmed: anyone could sign up
-- as someone else's address, never confirm it, and be what that person's
-- friends found by contacts, while the real owner was left with no hash.
create or replace function public.profiles_email_hash_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_hash text := case when new.email_confirmed_at is not null then email_hash_of(new.email) end;
begin
  begin
    if v_hash is not null
       and exists (select 1 from profiles p where p.email_hash = v_hash and p.id <> new.id) then
      v_hash := null;
    end if;
    update profiles p set email_hash = v_hash
    where p.id = new.id and p.email_hash is distinct from v_hash;
  exception
    when unique_violation then
      begin
        update profiles p set email_hash = null where p.id = new.id;
      exception when others then
        raise log 'profiles_email_hash_from_auth: % for %', sqlerrm, new.id;
      end;
    when others then
      raise log 'profiles_email_hash_from_auth: % for %', sqlerrm, new.id;
  end;
  return null;
end;
$$;

-- Unconfirmed accounts lose their hash; then each hash that is free goes to
-- the oldest confirmed account with that address and no hash yet.
update public.profiles p set email_hash = null
from auth.users u
where u.id = p.id and u.email_confirmed_at is null and p.email_hash is not null;

update public.profiles p set email_hash = w.hash
from (
  select distinct on (h.hash) h.id, h.hash
  from (
    select u.id, u.created_at, public.email_hash_of(u.email) as hash
    from auth.users u
    join public.profiles pr on pr.id = u.id
    where u.email_confirmed_at is not null and pr.email_hash is null
  ) h
  where h.hash is not null
    and not exists (select 1 from public.profiles q where q.email_hash = h.hash)
  order by h.hash, h.created_at, h.id
) w
where p.id = w.id;

-- 0022's trigger (insert, email change) stays as it is; this one adds the
-- moment the address is confirmed. When both columns change at once the
-- function runs twice, which changes nothing the second time.
create trigger profiles_email_hash_on_confirm
  after update of email_confirmed_at on auth.users
  for each row execute function public.profiles_email_hash_from_auth();

-- ========================================================== execute privileges

-- `create or replace` keeps each replaced function's grants; only the new
-- trigger function needs closing.
revoke execute on function public.meets_ended_by() from public, anon, authenticated;
grant execute on function public.meets_ended_by() to service_role;
