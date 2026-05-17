-- Self-friend prevention.
--
-- friendships table accepts requester_id == addressee_id today (only the
-- client validates against it). A direct REST call could insert a self-
-- friend row, which would render confusingly in the UI. Add a CHECK
-- constraint so the database rejects it.
--
-- ⚠️  An earlier version of this migration ALSO added a resort-scoped clause
-- to the `live_presence_friend_read` RLS policy. That clause broke realtime
-- friend-location reads in production (any state where the viewer's own
-- live_presence row was missing or not-yet-matching the friend's resort_id
-- silently blocked the friend's row, which is the realtime hot path).
-- Reverted in `20260426_revert_resort_scoped_live_presence_rls.sql`. The
-- client-side resort filter in `RealtimeLocationService.hydrateFromTable`
-- handles cross-resort isolation correctly without needing an RLS clause.
--
-- Safe to re-run: every statement is idempotent.

begin;

-- ── Self-friend CHECK ─────────────────────────────────────────────────────

-- Clean up any self-friend rows that may have slipped in before the check.
delete from public.friendships
  where requester_id = addressee_id;

-- Drop the constraint if it already exists, then re-add — keeps the
-- migration re-runnable when iterating in dev.
do $$
begin
  if exists (
    select 1 from pg_constraint
     where conname = 'friendships_no_self_friend'
       and conrelid = 'public.friendships'::regclass
  ) then
    alter table public.friendships drop constraint friendships_no_self_friend;
  end if;
end $$;

alter table public.friendships
  add constraint friendships_no_self_friend
  check (requester_id <> addressee_id);

commit;
