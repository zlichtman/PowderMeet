-- Harden meet_requests + friendships status lifecycle.

-- 1. CHECK constraint on meet_requests.status
alter table public.meet_requests
  drop constraint if exists meet_requests_status_check;

alter table public.meet_requests
  add constraint meet_requests_status_check
  check (status in ('pending', 'accepted', 'declined', 'expired'));

-- 2. UPDATE RLS: sender can cancel own request
drop policy if exists "Users can respond to meet requests" on public.meet_requests;
drop policy if exists "Users can update own meet requests" on public.meet_requests;

create policy "Users can update own meet requests"
  on public.meet_requests
  for update
  using (
    (select auth.uid()) = sender_id
    or (select auth.uid()) = receiver_id
  )
  with check (
    (select auth.uid()) = sender_id
    or (select auth.uid()) = receiver_id
  );

-- 3. Status-transition triggers
create or replace function public.enforce_meet_request_status_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = new.status then
    return new;
  end if;
  if old.status = 'pending' and new.status in ('accepted', 'declined', 'expired') then
    return new;
  end if;
  if old.status = 'accepted' and new.status = 'expired' then
    return new;
  end if;
  raise exception 'invalid meet_requests status transition: % -> %', old.status, new.status
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists meet_requests_status_transition on public.meet_requests;
create trigger meet_requests_status_transition
  before update of status on public.meet_requests
  for each row
  execute function public.enforce_meet_request_status_transition();

create or replace function public.enforce_friendship_status_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = new.status then
    return new;
  end if;
  if old.status = 'pending' and new.status = 'accepted' then
    return new;
  end if;
  raise exception 'invalid friendships status transition: % -> %', old.status, new.status
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists friendships_status_transition on public.friendships;
create trigger friendships_status_transition
  before update of status on public.friendships
  for each row
  execute function public.enforce_friendship_status_transition();;
