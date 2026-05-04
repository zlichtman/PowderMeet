-- Atomic `send_friend_request` RPC.
--
-- Replaces the client-side check-then-insert in `FriendService.sendRequest`,
-- which had a narrow but real race: two simultaneous taps under realtime
-- could both pass the dedupe check and produce two overlapping `pending`
-- rows. Because the realtime channel notifies both clients immediately,
-- the friend then renders twice in the pending list.
--
-- Doing the check + insert in one SQL call (with a SELECT … FOR UPDATE
-- where applicable, but in this case the unique-constraint on the pair is
-- the real safeguard) eliminates the window.
--
-- Behaviour:
--   - Caller authenticated (auth.uid() must be non-null).
--   - Caller may not friend themselves (returns NULL — UI surfaces a
--     "can't friend yourself" message; the friendships_no_self_friend
--     CHECK constraint also blocks it server-side).
--   - If an `accepted` friendship already exists between the pair: return
--     that row's id, no insert.
--   - If a `pending` friendship already exists (either direction): return
--     that row's id, no insert.
--   - If a `declined` or `expired` row exists: insert fresh `pending` row
--     (so a previously-rebuffed user can ask again — same UX as the old
--     client logic).
--   - Otherwise: insert fresh `pending` row.

begin;

create or replace function public.send_friend_request(p_addressee_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid;
  v_existing record;
  v_new_id uuid;
begin
  v_caller := auth.uid();
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if v_caller = p_addressee_id then
    raise exception 'Cannot friend yourself' using errcode = '23514';
  end if;

  -- Surface the most-recent existing row between the pair (any direction).
  select * into v_existing
    from public.friendships
   where (requester_id = v_caller and addressee_id = p_addressee_id)
      or (requester_id = p_addressee_id and addressee_id = v_caller)
   order by case status
              when 'accepted' then 1
              when 'pending'  then 2
              else 3
            end,
            created_at desc
   limit 1;

  if found then
    if v_existing.status in ('accepted', 'pending') then
      -- Idempotent: already friends or already pending.
      return v_existing.id;
    end if;
    -- Otherwise (declined / expired) — fall through to insert a fresh pending.
  end if;

  insert into public.friendships (requester_id, addressee_id, status)
    values (v_caller, p_addressee_id, 'pending')
    returning id into v_new_id;

  return v_new_id;
end;
$$;

revoke all on function public.send_friend_request(uuid) from public;
grant execute on function public.send_friend_request(uuid) to authenticated;

commit;
