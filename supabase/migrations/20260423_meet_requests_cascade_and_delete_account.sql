-- Include meet_requests in account deletion.
--
-- Symptom this fixes: after a user deletes their account, meet requests they
-- sent or received can linger in the other party's inbox with a now-invalid
-- sender/receiver reference. Same failure mode that
-- 20260418_friendships_cascade_and_delete_hardening.sql fixed for friendships:
-- meet_requests was created outside the migrations tree, so its FK cascade
-- behavior is unknown on existing deployments, and the `delete_user_account()`
-- RPC didn't explicitly clean meet_requests.
--
-- This migration:
--   1. One-shot cleanup of meet_requests rows referencing a user who is
--      already gone from auth.users / profiles.
--   2. Re-declares sender_id / receiver_id FKs with ON DELETE CASCADE so
--      future account deletions auto-clean both sides.
--   3. Extends `delete_user_account()` to explicitly remove the caller's
--      meet_requests before dropping the profile — belt-and-suspenders on
--      any environment where the CASCADE isn't in place yet.
--
-- Safe to re-run: every statement is idempotent or guarded.

begin;

-- ── 1. Orphan cleanup ─────────────────────────────────────────────────────

delete from public.meet_requests mr
  where not exists (select 1 from auth.users u where u.id = mr.sender_id)
     or not exists (select 1 from auth.users u where u.id = mr.receiver_id)
     or not exists (select 1 from public.profiles p where p.id = mr.sender_id)
     or not exists (select 1 from public.profiles p where p.id = mr.receiver_id);

-- ── 2. Harden foreign keys with ON DELETE CASCADE ─────────────────────────
--
-- Mirrors the friendships hardening pattern — drop any existing FK on
-- sender_id / receiver_id (name unknown across deployments) and re-add
-- pointing at profiles(id) with ON DELETE CASCADE.

do $$
declare
  fk_name text;
begin
  for fk_name in
    select conname from pg_constraint
     where conrelid = 'public.meet_requests'::regclass
       and contype = 'f'
       and conkey = (
         select array_agg(attnum order by attnum)
           from pg_attribute
          where attrelid = 'public.meet_requests'::regclass
            and attname = 'sender_id'
       )
  loop
    execute format('alter table public.meet_requests drop constraint %I', fk_name);
  end loop;

  for fk_name in
    select conname from pg_constraint
     where conrelid = 'public.meet_requests'::regclass
       and contype = 'f'
       and conkey = (
         select array_agg(attnum order by attnum)
           from pg_attribute
          where attrelid = 'public.meet_requests'::regclass
            and attname = 'receiver_id'
       )
  loop
    execute format('alter table public.meet_requests drop constraint %I', fk_name);
  end loop;
end $$;

alter table public.meet_requests
  add constraint meet_requests_sender_id_fkey
    foreign key (sender_id) references public.profiles(id) on delete cascade;

alter table public.meet_requests
  add constraint meet_requests_receiver_id_fkey
    foreign key (receiver_id) references public.profiles(id) on delete cascade;

-- ── 3. delete_user_account RPC — add meet_requests cleanup ────────────────
--
-- Copy of the function from 20260418_friendships_cascade_and_delete_hardening
-- with an added `delete from public.meet_requests` step. The deletion only
-- touches rows that reference the caller's uid (both sender and receiver
-- sides) — it never removes a meet_request where neither party is the caller,
-- so only the user's own data is wiped.

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

  -- 1. Friendships (both sides).
  delete from public.friendships
   where requester_id = uid or addressee_id = uid;

  -- 2. Meet requests (both sides). Must precede the profile delete on any
  --    environment where the FK cascade above hasn't propagated yet —
  --    otherwise the profile delete errors on a RESTRICT constraint.
  delete from public.meet_requests
   where sender_id = uid or receiver_id = uid;

  -- 3. Live presence row (FK-cascaded via auth.users; explicit here to
  --    avoid relying on cascade order during the transaction below).
  delete from public.live_presence where user_id = uid;

  -- 4. Imported runs / profile stats — both keyed on profile_id, both
  --    optional per-environment, so guard with to_regclass.
  if to_regclass('public.imported_runs') is not null then
    execute 'delete from public.imported_runs where profile_id = $1' using uid;
  end if;
  if to_regclass('public.profile_stats') is not null then
    execute 'delete from public.profile_stats where profile_id = $1' using uid;
  end if;

  -- 5. Drop the profile row (cascades to anything keyed on profiles.id).
  delete from public.profiles where id = uid;

  -- 6. Finally remove the auth user. Also invalidates issued refresh tokens
  --    on the server side.
  delete from auth.users where id = uid;
end;
$$;

grant execute on function public.delete_user_account() to authenticated;

commit;
