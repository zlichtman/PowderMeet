-- Per-user blocks. Asymmetric: A blocking B is independent of B blocking A.
-- A block hides the blocked user from the blocker's friend list, social
-- snapshot, presence broadcasts, and per-edge-speed reads — and vice versa
-- for the blockee viewing the blocker, since `not exists` checks both
-- directions on the friendships / presence / edge-speeds policies.
--
-- Dedicated table over a `'blocked'` status on `friendships` because:
--   * blocks don't require a prior friendship,
--   * the existing friendships status enum + transition trigger stays
--     unchanged,
--   * RLS for "exclude blocks" on the friend-readable surfaces is a
--     simple `not exists` clause that works regardless of friendship
--     state,
--   * unblocking restores the friendship row's prior status (if any)
--     for free — no data migration needed on block/unblock.

create table if not exists public.user_blocks (
  blocker_id  uuid not null references auth.users(id) on delete cascade,
  blockee_id  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blockee_id),
  check (blocker_id <> blockee_id)
);

create index if not exists user_blocks_blocker_idx on public.user_blocks (blocker_id);
create index if not exists user_blocks_blockee_idx on public.user_blocks (blockee_id);

alter table public.user_blocks enable row level security;

drop policy if exists user_blocks_owner on public.user_blocks;
create policy user_blocks_owner on public.user_blocks
  for all
  to authenticated
  using (auth.uid() = blocker_id)
  with check (auth.uid() = blocker_id);

-- Exclude blocked relationships from friendship reads. A block in either
-- direction (caller blocked them, or they blocked caller) hides the row.
drop policy if exists "Users can view own friendships" on public.friendships;
create policy "Users can view own friendships" on public.friendships
  for select
  using (
    (auth.uid() = requester_id or auth.uid() = addressee_id)
    and not exists (
      select 1 from public.user_blocks ub
      where (ub.blocker_id = auth.uid() and ub.blockee_id = case when auth.uid() = requester_id then addressee_id else requester_id end)
         or (ub.blockee_id = auth.uid() and ub.blocker_id = case when auth.uid() = requester_id then addressee_id else requester_id end)
    )
  );

-- Exclude blocked users from live presence reads. Same bidirectional check.
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
    and not exists (
      select 1 from public.user_blocks ub
      where (ub.blocker_id = (select auth.uid()) and ub.blockee_id = live_presence.user_id)
         or (ub.blockee_id = (select auth.uid()) and ub.blocker_id = live_presence.user_id)
    )
  );

-- Exclude blocked users from per-edge-speed reads. Same bidirectional check.
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
    and not exists (
      select 1 from public.user_blocks ub
      where (ub.blocker_id = (select auth.uid()) and ub.blockee_id = profile_edge_speeds.profile_id)
         or (ub.blockee_id = (select auth.uid()) and ub.blocker_id = profile_edge_speeds.profile_id)
    )
  );
