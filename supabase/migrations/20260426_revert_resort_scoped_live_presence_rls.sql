-- Revert: drop the resort-scoped clause on live_presence_friend_read.
--
-- An earlier audit-pass migration tightened the RLS policy with
--   AND live_presence.resort_id = caller.resort_id
-- The intent was defence-in-depth on top of the client-side resort filter.
-- The effect was a realtime regression: the row-level gate silently rejects
-- friend rows whenever the viewer's own live_presence row is briefly
-- missing or not yet matching the friend's resort_id — which happens on
-- cold launch, when either party is between resorts, and during the
-- subscribe-before-broadcast window. Realtime postgres_changes events for
-- live_presence stop arriving entirely.
--
-- The client (`RealtimeLocationService.hydrateFromTable` and the per-resort
-- friendLocations cache) already handles cross-resort isolation correctly,
-- so the RLS layer doesn't need to enforce it. Restore the friendship-only
-- gate that was in place before the audit.
--
-- Safe to re-run: drop+create is idempotent.

begin;

drop policy if exists live_presence_friend_read on public.live_presence;

create policy live_presence_friend_read on public.live_presence
  for select
  using (
    exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and (
          (f.requester_id = (select auth.uid()) and f.addressee_id = live_presence.user_id)
          or (f.addressee_id = (select auth.uid()) and f.requester_id = live_presence.user_id)
        )
    )
  );

commit;
