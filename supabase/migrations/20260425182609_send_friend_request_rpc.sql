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
      return v_existing.id;
    end if;
  end if;

  insert into public.friendships (requester_id, addressee_id, status)
    values (v_caller, p_addressee_id, 'pending')
    returning id into v_new_id;

  return v_new_id;
end;
$$;

revoke all on function public.send_friend_request(uuid) from public;
grant execute on function public.send_friend_request(uuid) to authenticated;;
