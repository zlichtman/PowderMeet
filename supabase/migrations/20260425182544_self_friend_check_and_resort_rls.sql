-- Self-friend prevention + resort-scoped live_presence RLS.

-- ── 1. Self-friend CHECK ──────────────────────────────────────────────────
delete from public.friendships
  where requester_id = addressee_id;

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

-- ── 2. Resort-scoped live_presence RLS ────────────────────────────────────
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
    and (
      not exists (select 1 from public.live_presence me where me.user_id = (select auth.uid()))
      or live_presence.resort_id = (
        select me.resort_id from public.live_presence me where me.user_id = (select auth.uid())
      )
    )
  );;
