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
  );;
