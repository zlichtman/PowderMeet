-- Friend-read RLS for profile_edge_speeds.
--
-- Until this policy, only the row owner could read their own per-edge
-- rolling-speed cache (`profile_edge_speeds_owner`). MeetSolver therefore
-- always seeded the friend's per-skier history with `[:]`, forcing the
-- solver to fall back to bucketed difficulty for the friend's pace —
-- so two skiers with identical bucketed-difficulty profiles got
-- identical traverse times, and uploading activity files only
-- improved your own half of the route.
--
-- This policy lets confirmed friends (`status = 'accepted'`) read each
-- other's `profile_edge_speeds` rows. Pattern matches
-- `live_presence_friend_read` from 20260417 — same friendships shape,
-- same `for select` only (no insert/update/delete leakage).
--
-- Privacy posture: per-edge rolling speed reveals which named edges a
-- user has skied and how quickly, but only on a graph the friend
-- already shares (resort topology). Lower sensitivity than realtime
-- location, which is already shared friends-only via `live_presence`.

drop policy if exists profile_edge_speeds_friend_read on public.profile_edge_speeds;
create policy profile_edge_speeds_friend_read on public.profile_edge_speeds
  for select
  using (
    exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and (
          (f.requester_id = (select auth.uid()) and f.addressee_id = profile_edge_speeds.profile_id)
          or (f.addressee_id = (select auth.uid()) and f.requester_id = profile_edge_speeds.profile_id)
        )
    )
  );
