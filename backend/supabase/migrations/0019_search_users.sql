-- Finding people by name (specs/04-SCHEMA.md sections 6 and 9).
--
-- Additive: two functions, no table changes. `search_users` replaces add codes
-- and QR as the way to find someone who is not in the address book: the
-- caller types part of a name and gets back at most 20 people, each with only
-- their id, display name, photo path and how they relate to the caller. No
-- location, resort, ability, stats, email or anything else.
--
-- Never listed: the caller, anyone with a block in either direction (so a
-- blocked user cannot tell they were blocked from search, and a blocker never
-- sees the person they blocked), and accounts still on the sign-up placeholder
-- name (not onboarded yet; the name is random and means nothing). The query is
-- normalised the way names are (`display_name_normalize`), compared ignoring
-- case, with LIKE wildcards in it taken literally. Rate-limited like
-- `display_name_available`, since each call says which names exist.

-- ------------------------------------------------------------- placeholder

-- True for a name only the sign-up trigger gives: "Skier NNNNNN"
-- (`display_name_placeholder`), "Skier " and twelve hex digits of the user id
-- (its fallbacks in 0013), and the bare "Skier" 0005 gave everyone.
create function public.display_name_is_placeholder(p_name text)
returns boolean
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select p_name = 'Skier' or p_name ~ '^Skier ([0-9]{6}|[0-9a-f]{12})$'
$$;

-- ------------------------------------------------------------- search_users

-- Prefix matches first, then names that contain the query elsewhere, each in
-- name order. A query under 2 or over 24 characters once normalised (no name
-- is shorter or longer) returns nothing and is not counted.
create function public.search_users(p_query text)
returns table (user_id uuid, display_name text, avatar_url text, relation text)
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_me uuid := require_uid();
  v_query text := lower(display_name_normalize(coalesce(p_query, '')));
  v_pattern text;
begin
  if char_length(v_query) not between 2 and 24 then
    return;
  end if;
  perform rate_limit(v_me, 'search_users', 60, interval '1 minute');
  -- Backslash first, so the escapes added for % and _ are not doubled.
  v_pattern := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select p.id, p.display_name, p.avatar_url,
      case
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
      end
    from profiles p
    where p.id <> v_me
      and not display_name_is_placeholder(p.display_name)
      and lower(display_name_normalize(p.display_name)) like '%' || v_pattern || '%' escape '\'
      and not is_blocked_between(v_me, p.id)
    order by
      case when lower(display_name_normalize(p.display_name)) like v_pattern || '%' escape '\' then 0 else 1 end,
      lower(p.display_name), p.id
    limit 20;
end;
$$;

-- ------------------------------------------------------- execute privileges

revoke execute on function
  public.display_name_is_placeholder(text),
  public.search_users(text)
from public, anon, authenticated;
grant execute on function
  public.display_name_is_placeholder(text),
  public.search_users(text)
to service_role;
grant execute on function public.search_users(text) to authenticated;
