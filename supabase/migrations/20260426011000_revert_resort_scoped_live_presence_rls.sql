-- Revert the resort-scoped clause on `live_presence_friend_read`.
--
-- The added `live_presence.resort_id = caller.resort_id` filter blocked
-- legitimate friend-location reads in too many states:
--   - viewer's own live_presence row is briefly missing or stale on
--     session start / cold launch
--   - friend updates resort just before viewer's snapshot refreshes
--   - either party "between resorts" (in the parking lot, on the drive)
--
-- The client already filters friend dots by resort at the app layer
-- (see RealtimeLocationService.hydrateFromTable + friendLocations
-- per-resort handling), so the RLS clause was defence-in-depth at the
-- cost of breaking the realtime path entirely. Drop it; restore the
-- pre-audit policy which gates only on accepted friendship.

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
  );;
