-- Harden meet_requests + friendships status lifecycle.
--
-- 1. meet_requests.status: add CHECK constraint matching the app's four-state
--    model (pending / accepted / declined / expired). Until now the column
--    was free-form text — a client bug could have silently written any value
--    and broken receiver filtering.
--
-- 2. meet_requests UPDATE RLS: allow the sender to cancel their own request
--    (moving it to 'expired'). The original policy only permitted the
--    receiver to respond (accept/decline), so `MeetRequestService.cancelRequest`
--    by the sender was silently rejected by RLS.
--
-- 3. Backwards-transition trigger on meet_requests + friendships: once a
--    row reaches a terminal state (accepted/declined/expired for meets,
--    accepted for friendships) it must not revert to 'pending'. Without
--    this a bug or hostile client could reopen a closed request.
--
-- Pre-flight: existing meet_requests.status values are 'accepted' or 'expired'
-- only, so the CHECK constraint adds cleanly without data fix-up.

begin;

-- ── 1. CHECK constraint on meet_requests.status ───────────────────────────

alter table public.meet_requests
  drop constraint if exists meet_requests_status_check;

alter table public.meet_requests
  add constraint meet_requests_status_check
  check (status in ('pending', 'accepted', 'declined', 'expired'));

-- ── 2. UPDATE RLS: sender can cancel own request ──────────────────────────
--
-- Replace the receiver-only policy with one that accepts either party.
-- The status-transition trigger below enforces what each party may change.

drop policy if exists "Users can respond to meet requests" on public.meet_requests;
drop policy if exists "Users can update own meet requests" on public.meet_requests;

create policy "Users can update own meet requests"
  on public.meet_requests
  for update
  using (
    (select auth.uid()) = sender_id
    or (select auth.uid()) = receiver_id
  )
  with check (
    (select auth.uid()) = sender_id
    or (select auth.uid()) = receiver_id
  );

-- ── 3. Status-transition trigger: no going backwards ──────────────────────
--
-- Allowed transitions:
--   meet_requests:  pending  → accepted | declined | expired
--                   accepted → expired                 (either party cancels live meetup)
--                   declined → (terminal)
--                   expired  → (terminal)
--   friendships:    pending  → accepted
--                   accepted → (terminal; unfriend is a DELETE, not a status change)
--
-- Terminal rows are frozen at the status level — attribute updates are still
-- allowed (e.g. sender_eta_seconds on an accepted meetup) as long as status
-- doesn't regress.

create or replace function public.enforce_meet_request_status_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = new.status then
    return new;
  end if;
  if old.status = 'pending' and new.status in ('accepted', 'declined', 'expired') then
    return new;
  end if;
  if old.status = 'accepted' and new.status = 'expired' then
    return new;
  end if;
  raise exception 'invalid meet_requests status transition: % → %', old.status, new.status
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists meet_requests_status_transition on public.meet_requests;
create trigger meet_requests_status_transition
  before update of status on public.meet_requests
  for each row
  execute function public.enforce_meet_request_status_transition();

create or replace function public.enforce_friendship_status_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = new.status then
    return new;
  end if;
  if old.status = 'pending' and new.status = 'accepted' then
    return new;
  end if;
  raise exception 'invalid friendships status transition: % → %', old.status, new.status
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists friendships_status_transition on public.friendships;
create trigger friendships_status_transition
  before update of status on public.friendships
  for each row
  execute function public.enforce_friendship_status_transition();

commit;

-- Note: home_resort_id / meet_preference / aspect_preference /
-- prefer_night_skiing on public.profiles were dropped in
-- 20260502_drop_dormant_profile_columns.sql.
