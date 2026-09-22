-- Collapse self_read + friend_read into one SELECT policy so Postgres only
-- evaluates a single permissive policy per row. Functionally identical: a
-- caller can read their own row OR rows belonging to accepted friends.
drop policy if exists live_presence_self_read on public.live_presence;
drop policy if exists live_presence_friend_read on public.live_presence;

create policy live_presence_read on public.live_presence
  for select
  using (
    (select auth.uid()) = user_id
    or exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and (
          (f.requester_id = (select auth.uid()) and f.addressee_id = live_presence.user_id)
          or (f.addressee_id = (select auth.uid()) and f.requester_id = live_presence.user_id)
        )
    )
  );;
