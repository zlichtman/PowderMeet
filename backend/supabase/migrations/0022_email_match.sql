-- 0022 The server keeps every user's email hash, so contacts can find them.
-- specs/04-SCHEMA.md section 9.
--
-- Until now `profiles.email_hash` was set only when the client published it,
-- so almost nobody could be found by a friend's contact lookup. From here on
-- the server derives it from the auth email: SHA-256 hex of the address
-- trimmed and lowercased, exactly what the app computes for each address in
-- the phone's contacts. An Apple private relay address is in nobody's address
-- book, so it gets no hash. The client can no longer write the column.
--
-- One hash belongs to one profile (the column is unique). When two accounts
-- share an address, the account that had it first keeps the hash and the
-- later one stays null; nothing here ever fails a sign-up.

-- ------------------------------------------------------------- the hash

-- SHA-256 hex of the normalized address, or null for no address, a value with
-- no "@", or an Apple private relay address. `sha256` is the PG 11+ builtin.
create function public.email_hash_of(p_email text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when v = '' or position('@' in v) = 0 or v like '%@privaterelay.appleid.com' then null
    else encode(sha256(convert_to(v, 'UTF8')), 'hex')
  end
  from (select lower(btrim(p_email, E' \t\r\n')) as v) s
$$;

-- ------------------------------------------------- keeping it up to date

-- Runs after every auth.users insert and every change of its email. On
-- insert, `profiles_from_auth` (also AFTER INSERT) must already have created
-- the profile: same-event triggers fire in name order, and this trigger's
-- name sorts after it. It must never fail the auth write, so a clash with
-- another account's hash leaves this one null and any other error is logged.
create function public.profiles_email_hash_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_hash text := email_hash_of(new.email);
begin
  begin
    if v_hash is not null
       and exists (select 1 from profiles p where p.email_hash = v_hash and p.id <> new.id) then
      v_hash := null;
    end if;
    update profiles p set email_hash = v_hash
    where p.id = new.id and p.email_hash is distinct from v_hash;
  exception
    when unique_violation then
      begin
        update profiles p set email_hash = null where p.id = new.id;
      exception when others then
        raise log 'profiles_email_hash_from_auth: % for %', sqlerrm, new.id;
      end;
    when others then
      raise log 'profiles_email_hash_from_auth: % for %', sqlerrm, new.id;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------- backfill

-- Every hash is recomputed from the auth email, client-published ones
-- included. All are cleared first: one UPDATE that moved hashes between rows
-- could trip the (non-deferrable) unique index part way through. The oldest
-- account wins a shared address.
update public.profiles set email_hash = null where email_hash is not null;

update public.profiles p set email_hash = w.hash
from (
  select distinct on (h.hash) h.id, h.hash
  from (
    select u.id, u.created_at, public.email_hash_of(u.email) as hash
    from auth.users u
    join public.profiles pr on pr.id = u.id
  ) h
  where h.hash is not null
  order by h.hash, h.created_at, h.id
) w
where p.id = w.id;

-- After the backfill, so it does not fire for rows the backfill set.
create trigger profiles_from_auth_email_hash
  after insert or update of email on auth.users
  for each row execute function public.profiles_email_hash_from_auth();

-- ------------------------------------------------------------ profile_update

-- 0013's function without `email_hash`: the server owns that column now. A
-- key older builds still send is dropped silently, so their patch still
-- applies. `phone_hash` stays accepted for builds that still send
-- it; this client matches by email only.
create or replace function public.profile_update(p_patch jsonb)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_key text;
  v_row profiles;
  v_name text;
  v_problem text;
  v_constraint text;
  v_allowed constant text[] := array['display_name', 'avatar_url', 'ability', 'max_difficulty',
    'baseline_speeds', 'equipment', 'avoid', 'max_pitch_deg', 'height_cm', 'weight_kg',
    'phone_hash', 'current_resort_id'];
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'invalid';
  end if;
  p_patch := p_patch - 'email_hash';
  for v_key in select jsonb_object_keys(p_patch) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'invalid';
    end if;
  end loop;
  if p_patch ? 'display_name' then
    if jsonb_typeof(p_patch -> 'display_name') <> 'string' then
      raise exception 'invalid';
    end if;
    v_problem := display_name_problem(p_patch ->> 'display_name', v_me);
    if v_problem is not null then
      raise exception '%', v_problem;
    end if;
    v_name := display_name_normalize(p_patch ->> 'display_name');
  end if;
  if (p_patch ->> 'avatar_url') is not null
     and (p_patch ->> 'avatar_url') !~ ('^' || v_me::text || '/[A-Za-z0-9._-]{1,80}$') then
    raise exception 'invalid';
  end if;
  if (p_patch ->> 'current_resort_id') is not null
     and not exists (select 1 from resorts r where r.id = p_patch ->> 'current_resort_id' and r.published) then
    raise exception 'resort_not_published';
  end if;

  begin
    update profiles p set
      display_name = case when p_patch ? 'display_name' then v_name else p.display_name end,
      avatar_url = case when p_patch ? 'avatar_url' then p_patch ->> 'avatar_url' else p.avatar_url end,
      ability = case when p_patch ? 'ability' then p_patch ->> 'ability' else p.ability end,
      max_difficulty = case when p_patch ? 'max_difficulty' then p_patch ->> 'max_difficulty' else p.max_difficulty end,
      baseline_speeds = case when p_patch ? 'baseline_speeds' then p_patch -> 'baseline_speeds' else p.baseline_speeds end,
      equipment = case when p_patch ? 'equipment' then nullif(p_patch -> 'equipment', 'null'::jsonb) else p.equipment end,
      avoid = case when p_patch ? 'avoid'
        then array(select distinct a from jsonb_array_elements_text(p_patch -> 'avoid') a order by a)
        else p.avoid end,
      max_pitch_deg = case when p_patch ? 'max_pitch_deg' then (p_patch ->> 'max_pitch_deg')::smallint else p.max_pitch_deg end,
      height_cm = case when p_patch ? 'height_cm' then (p_patch ->> 'height_cm')::smallint else p.height_cm end,
      weight_kg = case when p_patch ? 'weight_kg' then (p_patch ->> 'weight_kg')::smallint else p.weight_kg end,
      phone_hash = case when p_patch ? 'phone_hash' then p_patch ->> 'phone_hash' else p.phone_hash end,
      current_resort_id = case when p_patch ? 'current_resort_id' then p_patch ->> 'current_resort_id' else p.current_resort_id end,
      updated_at = clock()
    where p.id = v_me
    returning p.* into v_row;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'profiles_display_name_lower' then
        raise exception 'name_taken';
      end if;
      raise exception 'invalid';
    -- data_exception: a value of the wrong JSON type or out of a column's range.
    when check_violation or not_null_violation or data_exception then
      raise exception 'invalid';
  end;
  if v_row.id is null then
    raise exception 'not_found';
  end if;
  return v_row;
end;
$$;

-- ------------------------------------------------------- execute privileges

revoke execute on function
  public.email_hash_of(text),
  public.profiles_email_hash_from_auth()
from public, anon, authenticated;
grant execute on function
  public.email_hash_of(text),
  public.profiles_email_hash_from_auth()
to service_role;
