-- Split the FOR ALL self-write policy into per-action policies so SELECT
-- isn't covered twice (self_write + friend_read) — that double-eval was
-- flagged by the multiple_permissive_policies advisor.
drop policy if exists live_presence_self_write on public.live_presence;

create policy live_presence_self_insert on public.live_presence
  for insert
  with check ((select auth.uid()) = user_id);

create policy live_presence_self_update on public.live_presence
  for update
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy live_presence_self_delete on public.live_presence
  for delete
  using ((select auth.uid()) = user_id);

-- Add a self-row read policy so the user can also read their own latest fix.
-- friend_read already permits friends; this just covers the self case explicitly.
create policy live_presence_self_read on public.live_presence
  for select
  using ((select auth.uid()) = user_id);;
