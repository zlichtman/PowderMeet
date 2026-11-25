-- Friend card and add codes (specs/04-SCHEMA.md sections 2, 6 and 9).
--
-- Additive and data-preserving: one new table, new functions, and
-- `social_snapshot()` replaced with the same signature.
--
-- Friend card: each entry in the snapshot's `friends` list gains what the card
-- shows: ability, equipment, lifetime stats summed from the `descents.stats`
-- the importing phones already stored, and where the friend is now (the resort
-- and capture time of a presence row inside the 15 minute presence TTL, never
-- coordinates). `pending_in`, `pending_out` and `blocks` carry exactly what
-- they did before, so a stranger who sends a request learns nothing new. A
-- friendship row that coexists with a block is no longer listed as a friend.
--
-- Add codes: every user has one personal code, made on first ask and
-- replaceable, kept in `friend_codes`, which no client role can read. Holding a
-- code is how someone with a hidden Apple email is found: it names its owner
-- (`friend_code_resolve`) and sends them a request (`friend_request_by_code`).
-- An unknown or replaced code, and a code between two people with a block in
-- either direction, answer the same empty result, so a lookup never tells a
-- blocked user anything; the caller's own code says so. Both share one rate
-- limit, counted on misses as well as hits (a miss returns, it does not raise,
-- so the count is kept).

-- ------------------------------------------------------------ stats helpers

-- A number from phone-supplied JSON, or null when the value is missing, not a
-- number or out of any sensible range, so one malformed descent never fails a
-- friend's snapshot. PL/pgSQL so the type test runs before the cast.
create function public.stats_number(p_value jsonb)
returns double precision
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
begin
  if jsonb_typeof(p_value) is distinct from 'number' then
    return null;
  end if;
  if abs(p_value::numeric) >= 1e12 then
    return null;
  end if;
  return p_value::numeric::double precision;
end;
$$;

-- Lifetime totals over one skier's descents, the way the phone totals its own
-- history (`ActivityHistory.Totals` in AppCore): distance and vertical summed,
-- the top speed the highest, the average speed distance over moving time on
-- the runs that have a distance and a duration (moving time from the run's own
-- average speed when it has one, else its duration), days counted per resort
-- and ski day.
create function public.lifetime_stats(p_owner uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with runs as (
    select
      stats_number(d.stats -> 'distance_m') as distance_m,
      stats_number(d.stats -> 'vertical_m') as vertical_m,
      stats_number(d.stats -> 'top_speed_ms') as top_speed_ms,
      stats_number(d.stats -> 'avg_speed_ms') as avg_speed_ms,
      extract(epoch from d.ended_at - d.started_at)::double precision as duration_s,
      coalesce(case when jsonb_typeof(d.stats -> 'resort_name') = 'string' then d.stats ->> 'resort_name' end, '')
        || '|'
        || coalesce(case when jsonb_typeof(d.stats -> 'local_day') = 'string' then d.stats ->> 'local_day' end,
                    to_char(d.started_at at time zone 'UTC', 'YYYY-MM-DD')) as day_key
    from descents d
    where d.owner_id = p_owner
  ), timed as (
    select r.*,
      case when r.distance_m > 0 and r.duration_s > 0 then
        case when r.avg_speed_ms > 0 then r.distance_m / r.avg_speed_ms else r.duration_s end
      end as moving_s
    from runs r
  )
  select jsonb_build_object(
    'runs', count(*),
    'days', count(distinct day_key),
    'distance_m', coalesce(sum(distance_m), 0),
    'vertical_m', coalesce(sum(vertical_m), 0),
    'top_speed_ms', max(top_speed_ms),
    'avg_speed_ms', case when sum(moving_s) > 0
                         then sum(distance_m) filter (where moving_s is not null) / sum(moving_s) end)
  from timed;
$$;

-- ------------------------------------------------------------ social_snapshot

-- 0004's function. Friends: accepted and not blocked either way, with the card
-- fields. The other three lists are unchanged.
create or replace function public.social_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  return jsonb_build_object(
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'since', f.responded_at,
               'ability', p.ability, 'equipment', p.equipment,
               'stats', lifetime_stats(p.id),
               'last_seen', (
                 select jsonb_build_object('resort_id', pr.resort_id, 'at', pr.captured_at)
                 from presence pr
                 where pr.user_id = p.id and pr.received_at > clock() - interval '15 minutes'))
             order by p.display_name, p.id)
      from friendships f
      join profiles p
        on p.id = case when f.requester_id = v_me then f.addressee_id else f.requester_id end
      where f.status = 'accepted' and v_me in (f.requester_id, f.addressee_id)
        and not is_blocked_between(v_me, p.id)), '[]'::jsonb),
    'pending_in', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', f.created_at)
             order by f.created_at desc, f.id)
      from friendships f
      join profiles p on p.id = f.requester_id
      where f.status = 'pending' and f.addressee_id = v_me), '[]'::jsonb),
    'pending_out', coalesce((
      select jsonb_agg(jsonb_build_object(
               'friendship_id', f.id, 'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', f.created_at)
             order by f.created_at desc, f.id)
      from friendships f
      join profiles p on p.id = f.addressee_id
      where f.status = 'pending' and f.requester_id = v_me), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', p.id, 'display_name', p.display_name,
               'avatar_url', p.avatar_url, 'created_at', b.created_at)
             order by b.created_at desc, p.id)
      from user_blocks b
      join profiles p on p.id = b.blocked_id
      where b.blocker_id = v_me), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------- add codes

-- Ten characters from an alphabet without 0, O, 1, I and L, so a code read
-- aloud or typed from a screen survives: about 49 bits.
create table public.friend_codes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  code text not null unique check (code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$'),
  created_at timestamptz not null default now()
);
alter table public.friend_codes enable row level security;
revoke all on public.friend_codes from public, anon, authenticated;

create function public.friend_code_new()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(10);
  v_code text := '';
begin
  for i in 0 .. 9 loop
    v_code := v_code || substr(v_alphabet, 1 + get_byte(v_bytes, i) % 31, 1);
  end loop;
  return v_code;
end;
$$;

-- Spaces, dashes and case do not matter when a code is typed.
create function public.friend_code_normalize(p_code text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Stores a fresh code for the caller, replacing any old one. A clash with
-- another user's code draws again.
create function public.friend_code_store(p_user uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  for attempt in 1 .. 8 loop
    begin
      insert into friend_codes as fc (user_id, code, created_at)
      values (p_user, friend_code_new(), clock())
      on conflict (user_id) do update set code = excluded.code, created_at = excluded.created_at
      returning fc.code into v_code;
      return v_code;
    exception when unique_violation then
      null;
    end;
  end loop;
  raise exception 'invalid';
end;
$$;

-- The caller's code, made on first ask.
create function public.friend_code_get()
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_code text;
begin
  if not exists (select 1 from profiles p where p.id = v_me) then
    raise exception 'not_found';
  end if;
  select fc.code into v_code from friend_codes fc where fc.user_id = v_me;
  if v_code is not null then
    return v_code;
  end if;
  perform lock_users(v_me, v_me);
  select fc.code into v_code from friend_codes fc where fc.user_id = v_me;
  return coalesce(v_code, friend_code_store(v_me));
end;
$$;

-- A new code for the caller; the old one stops working at once.
create function public.friend_code_rotate()
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  if not exists (select 1 from profiles p where p.id = v_me) then
    raise exception 'not_found';
  end if;
  perform rate_limit(v_me, 'friend_code_rotate', 10, interval '1 hour');
  perform lock_users(v_me, v_me);
  return friend_code_store(v_me);
end;
$$;

-- The owner of a code, or null. Null for an unknown or replaced code and for a
-- pair with a block in either direction alike.
create function public.friend_code_owner(p_me uuid, p_code text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select fc.user_id
  from friend_codes fc
  where fc.code = friend_code_normalize(p_code)
    and not is_blocked_between(p_me, fc.user_id);
$$;

-- Who a code belongs to, for the confirmation before a request is sent:
-- `{user_id, display_name, avatar_url, relation}` with relation one of
-- self | friend | request_sent | request_received | none, or null.
create function public.friend_code_resolve(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_user uuid;
begin
  perform rate_limit(v_me, 'friend_code', 30, interval '1 hour');
  v_user := friend_code_owner(v_me, p_code);
  if v_user is null then
    return null;
  end if;
  return (
    select jsonb_build_object(
      'user_id', p.id, 'display_name', p.display_name, 'avatar_url', p.avatar_url,
      'relation', case
        when p.id = v_me then 'self'
        when exists (select 1 from friendships f
                     where f.status = 'accepted'
                       and ((f.requester_id = v_me and f.addressee_id = p.id)
                         or (f.requester_id = p.id and f.addressee_id = v_me))) then 'friend'
        when exists (select 1 from friendships f
                     where f.status = 'pending' and f.requester_id = v_me and f.addressee_id = p.id)
          then 'request_sent'
        when exists (select 1 from friendships f
                     where f.status = 'pending' and f.requester_id = p.id and f.addressee_id = v_me)
          then 'request_received'
        else 'none'
      end)
    from profiles p
    where p.id = v_user);
end;
$$;

-- Sends a friend request to a code's owner, through `friend_request` (which
-- accepts theirs if they already asked). The friendship row as JSON, or null
-- for a code that names nobody the caller can ask, their own included.
create function public.friend_request_by_code(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_user uuid;
begin
  perform rate_limit(v_me, 'friend_code', 30, interval '1 hour');
  v_user := friend_code_owner(v_me, p_code);
  if v_user is null or v_user = v_me then
    return null;
  end if;
  return to_jsonb(friend_request(v_user));
end;
$$;

-- ------------------------------------------------------- execute privileges

-- New functions are executable by PUBLIC by default; close them and open the
-- three RPCs (plus the one that reads a code back).
revoke execute on function
  public.stats_number(jsonb),
  public.lifetime_stats(uuid),
  public.friend_code_new(),
  public.friend_code_normalize(text),
  public.friend_code_store(uuid),
  public.friend_code_get(),
  public.friend_code_rotate(),
  public.friend_code_owner(uuid, text),
  public.friend_code_resolve(text),
  public.friend_request_by_code(text)
from public, anon, authenticated;
grant execute on function
  public.stats_number(jsonb),
  public.lifetime_stats(uuid),
  public.friend_code_new(),
  public.friend_code_normalize(text),
  public.friend_code_store(uuid),
  public.friend_code_get(),
  public.friend_code_rotate(),
  public.friend_code_owner(uuid, text),
  public.friend_code_resolve(text),
  public.friend_request_by_code(text)
to service_role;
grant execute on function
  public.friend_code_get(),
  public.friend_code_rotate(),
  public.friend_code_resolve(text),
  public.friend_request_by_code(text)
to authenticated;
