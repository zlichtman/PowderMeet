-- Friendship cleanup & hardening.
--
-- Symptom this fixes: "people that were friends become friend requests again
-- on app wipe". Root cause: when user B deletes their account (or is removed
-- via Supabase admin), their auth.users row is removed, but `friendships`
-- rows referencing them can linger — either because the FK wasn't ON DELETE
-- CASCADE, or because the app's `delete_user_account` RPC didn't clean them
-- up first. User B later re-signs-up with a brand new auth.users.id, adds
-- user A again, and A sees a pending request from someone the DB still has
-- as an accepted friend (the stale row).
--
-- This migration:
--   1. Deletes friendships rows whose requester_id OR addressee_id no
--      longer exists in auth.users (or in public.profiles) — one-shot
--      cleanup of any orphans left behind by earlier versions.
--   2. Re-declares the foreign keys with ON DELETE CASCADE so future
--      account deletions auto-clean their friendship rows.
--   3. Redefines `delete_user_account()` (SECURITY DEFINER) so it
--      explicitly nukes the user's friendships + profile + avatar
--      records before deleting the auth row — belt-and-suspenders with
--      the FK cascade for any environments where CASCADE isn't in place.
--
-- Safe to re-run: every statement is idempotent or guarded.

begin;

-- ── 1. Orphan cleanup ─────────────────────────────────────────────────────

-- Delete any friendships where either participant is gone from auth.users.
-- (Profiles.id is a 1:1 mirror of auth.users.id, so we only need the auth
-- check — but include profile for belt-and-suspenders.)
delete from public.friendships f
  where not exists (select 1 from auth.users u where u.id = f.requester_id)
     or not exists (select 1 from auth.users u where u.id = f.addressee_id)
     or not exists (select 1 from public.profiles p where p.id = f.requester_id)
     or not exists (select 1 from public.profiles p where p.id = f.addressee_id);

-- ── 2. Harden foreign keys with ON DELETE CASCADE ─────────────────────────
--
-- Drop any existing FK on requester_id / addressee_id and re-add with
-- CASCADE. `do $$ … $$` block so we can find the FK name dynamically —
-- older deployments may have used different constraint names.

do $$
declare
  fk_name text;
begin
  -- requester_id → auth.users.id (or profiles.id — whichever is referenced)
  for fk_name in
    select conname from pg_constraint
     where conrelid = 'public.friendships'::regclass
       and contype = 'f'
       and conkey = (
         select array_agg(attnum order by attnum)
           from pg_attribute
          where attrelid = 'public.friendships'::regclass
            and attname = 'requester_id'
       )
  loop
    execute format('alter table public.friendships drop constraint %I', fk_name);
  end loop;

  -- addressee_id FK
  for fk_name in
    select conname from pg_constraint
     where conrelid = 'public.friendships'::regclass
       and contype = 'f'
       and conkey = (
         select array_agg(attnum order by attnum)
           from pg_attribute
          where attrelid = 'public.friendships'::regclass
            and attname = 'addressee_id'
       )
  loop
    execute format('alter table public.friendships drop constraint %I', fk_name);
  end loop;
end $$;

-- Re-add the FKs pointing at profiles (which itself references auth.users
-- ON DELETE CASCADE, so the chain cleans friendships transitively when an
-- auth user is deleted).
alter table public.friendships
  add constraint friendships_requester_id_fkey
    foreign key (requester_id) references public.profiles(id) on delete cascade;

alter table public.friendships
  add constraint friendships_addressee_id_fkey
    foreign key (addressee_id) references public.profiles(id) on delete cascade;

-- ── 3. Harden delete_user_account RPC ─────────────────────────────────────
--
-- Works even where CASCADE hasn't propagated yet (e.g. Supabase projects
-- with older schema versions). Explicit delete of friendships is cheap
-- compared to an orphan leaking into the pending-requests UI.

create or replace function public.delete_user_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  -- 1. Clean friendships referencing this user (both sides).
  delete from public.friendships
   where requester_id = uid or addressee_id = uid;

  -- 2. Clean live_presence row (also FK-cascaded via auth.users, but
  --    explicit here to avoid relying on cascade order).
  delete from public.live_presence where user_id = uid;

  -- 3. Clean imported runs / profile stats if those tables exist in this
  --    environment. Both tables key on `profile_id` (matches the app's
  --    `ImportedRunRow.profile_id` + `recompute_profile_stats` RPC). An
  --    earlier version of this migration wrote `user_id` here, which would
  --    raise "column user_id does not exist" and roll back the entire
  --    delete transaction at runtime. `to_regclass` guards against missing
  --    tables on environments that never enabled activity import.
  if to_regclass('public.imported_runs') is not null then
    execute 'delete from public.imported_runs where profile_id = $1' using uid;
  end if;
  if to_regclass('public.profile_stats') is not null then
    execute 'delete from public.profile_stats where profile_id = $1' using uid;
  end if;

  -- 4. Drop the profile row (cascades to anything keyed on profiles.id).
  delete from public.profiles where id = uid;

  -- 5. Finally remove the auth user. This also invalidates any issued
  --    refresh tokens on the server side.
  delete from auth.users where id = uid;
end;
$$;

-- Only authenticated callers can invoke their own delete. The function
-- derives the uid from auth.uid() so it can't be abused to delete others.
grant execute on function public.delete_user_account() to authenticated;

commit;
