-- Display names: one normalisation, 2 to 24 characters, unique ignoring case,
-- and a short block list of slurs (specs/04-SCHEMA.md sections 2, 4 and 6).
--
-- Additive and data-preserving: no column changes and the existing CHECK
-- (1..40) stays, so a row written before this migration is never rejected or
-- rewritten. The rules apply when a name is written: by `profile_update`, and by
-- the sign-up trigger, which now picks a free placeholder ("Skier 123456") that
-- onboarding makes the user replace. The one exception is two existing rows
-- whose names differ only in case, which the unique index cannot accept: the
-- newer one is given a placeholder (none exist on the hosted project).
--
-- The client applies the same normalisation (`DisplayName` in PowderMeetAPI);
-- the cases in tests/database/080_display_names.test.sql are mirrored there.

-- ------------------------------------------------------------ normalisation

-- NFKC (folds full-width and other compatibility forms), every kind of space
-- to one ASCII space, control and invisible characters removed (zero-width
-- spaces and joiners, bidi controls, soft hyphen, Hangul fillers, variation
-- selectors, the braille blank, tag characters), runs of spaces collapsed, and
-- the ends trimmed. Length is counted in code points, as char_length does.
create function public.display_name_normalize(p_name text)
returns text
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(
    regexp_replace(
      regexp_replace(normalize(p_name, NFKC),
        '[[:space:]\u0085   -     　]', ' ', 'g'),
      '[\u0001-\u001F\u007F-\u009F­͏؜ᅟᅠ឴឵᠋-᠏​-‏‪-‮⁠-⁯⠀ㅤ︀-️﻿ﾠ￰-￻\U000E0000-\U000E007F]',
      '', 'g'),
    ' {2,}', ' ', 'g'))
$$;

-- ------------------------------------------------------------- block list

-- Server-side only: no client role can read or change it. `word` entries match
-- a whole word (optionally plural), so "spic" does not catch "Spicer";
-- `substring` entries match anywhere once punctuation and spacing are removed,
-- so "n.i.g.g.e.r" is caught. Entries are stored lower case, letters only.
create table public.display_name_blocked_words (
  word text primary key check (word ~ '^[a-z]{3,}$'),
  match text not null check (match in ('word', 'substring'))
);
alter table public.display_name_blocked_words enable row level security;
revoke all on public.display_name_blocked_words from public, anon, authenticated;

insert into public.display_name_blocked_words (word, match) values
  ('nigger', 'substring'), ('nigga', 'substring'), ('faggot', 'substring'),
  ('wetback', 'substring'), ('raghead', 'substring'), ('towelhead', 'substring'),
  ('hitler', 'substring'),
  ('kike', 'word'), ('chink', 'word'), ('spic', 'word'), ('gook', 'word'),
  ('coon', 'word'), ('paki', 'word'), ('beaner', 'word'), ('tranny', 'word'),
  ('retard', 'word'), ('retarded', 'word'), ('fag', 'word'), ('nazi', 'word'),
  ('kkk', 'word')
on conflict (word) do nothing;

-- True when a (normalised) name contains a blocked word. Folding: lower case,
-- then the common digit and symbol stand-ins for letters (0→o, 1→i, 3→e, 4→a,
-- 5→s, 7→t, @→a, $→s, !→i, |→i).
create function public.display_name_blocked(p_name text)
returns boolean
language sql
stable
strict
security definer
set search_path = public
as $$
  with folded as (
    select translate(lower(p_name), '013457@$!|', 'oieastasii') as f
  )
  select exists (
    select 1
    from display_name_blocked_words w, folded
    where (w.match = 'substring' and regexp_replace(folded.f, '[^a-z]', '', 'g') like '%' || w.word || '%')
       or (w.match = 'word' and (w.word = any (regexp_split_to_array(folded.f, '[^a-z]+'))
                                 or w.word || 's' = any (regexp_split_to_array(folded.f, '[^a-z]+'))))
  );
$$;

-- What is wrong with a name for this user, as the error code profile_update
-- raises, or null when it can be used: `invalid` (under 2 or over 24 characters
-- after normalising), `name_not_allowed`, `name_taken` (by anyone else,
-- ignoring case). Takes the raw name and normalises it.
create function public.display_name_problem(p_name text, p_user uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text := display_name_normalize(coalesce(p_name, ''));
begin
  if char_length(v_name) not between 2 and 24 then
    return 'invalid';
  end if;
  if display_name_blocked(v_name) then
    return 'name_not_allowed';
  end if;
  if exists (select 1 from profiles p
             where lower(p.display_name) = lower(v_name) and p.id is distinct from p_user) then
    return 'name_taken';
  end if;
  return null;
end;
$$;

-- A free placeholder for a new account. Onboarding never shows it: the name
-- step starts empty (or with the name Apple gave) and saving requires a valid
-- name. Six random digits make a clash rare; after ten clashes the user id
-- decides, which cannot clash.
create function public.display_name_placeholder(p_user uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  for i in 1..10 loop
    v_name := 'Skier ' || lpad(floor(random() * 1000000)::int::text, 6, '0');
    if not exists (select 1 from profiles p where lower(p.display_name) = lower(v_name)) then
      return v_name;
    end if;
  end loop;
  return 'Skier ' || left(replace(p_user::text, '-', ''), 12);
end;
$$;

-- ------------------------------------------------------ unique, ignoring case

-- Existing rows that differ only in case: keep the oldest, give the rest a
-- placeholder, so the index below can be built. A no-op on the hosted project.
do $$
declare
  v_row record;
begin
  for v_row in
    select p.id from (
      select id, row_number() over (partition by lower(display_name) order by created_at, id) as n
      from public.profiles
    ) p where p.n > 1
  loop
    update public.profiles set display_name = public.display_name_placeholder(v_row.id)
    where id = v_row.id;
  end loop;
end;
$$;

create unique index profiles_display_name_lower on public.profiles (lower(display_name));

-- ------------------------------------------------------ sign-up placeholder

-- Replaces 0005's version, which fell back to "Skier" for everyone. A name in
-- the sign-up metadata is kept when it passes the rules; otherwise the user
-- gets a free placeholder. This runs inside every auth.users insert, Apple
-- sign-ups included, so it must never fail: a clash with a concurrent sign-up
-- falls back to a name derived from the user id.
create or replace function public.profiles_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raw text := coalesce(new.raw_user_meta_data ->> 'display_name',
                         new.raw_user_meta_data ->> 'full_name',
                         new.raw_user_meta_data ->> 'name', '');
  v_name text;
begin
  begin
    if display_name_problem(v_raw, new.id) is null then
      v_name := display_name_normalize(v_raw);
    else
      v_name := display_name_placeholder(new.id);
    end if;
    insert into profiles (id, display_name) values (new.id, v_name)
    on conflict (id) do nothing;
  exception when others then
    insert into profiles (id, display_name)
    values (new.id, 'Skier ' || left(replace(new.id::text, '-', ''), 12))
    on conflict (id) do nothing;
  end;
  return new;
end;
$$;

-- ------------------------------------------------------------ profile_update

-- 0004's function with the display-name rules added: the name is normalised
-- before it is stored, and a bad one raises `invalid`, `name_not_allowed` or
-- `name_taken` instead of being stored. A clash that slips past the check
-- (two users saving the same name at once) is caught by the unique index and
-- reported as `name_taken` too.
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
    'email_hash', 'phone_hash', 'current_resort_id'];
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'invalid';
  end if;
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
      email_hash = case when p_patch ? 'email_hash' then p_patch ->> 'email_hash' else p.email_hash end,
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

-- ------------------------------------------------- display_name_available

-- Live checking while the user types: 'available', or the code profile_update
-- would raise for this name ('invalid', 'name_not_allowed', 'name_taken'). The
-- caller's own name counts as available. Rate-limited like find_users, since
-- it says whether a name is in use.
create function public.display_name_available(p_name text)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  perform rate_limit(v_me, 'display_name_available', 60, interval '1 minute');
  return coalesce(display_name_problem(p_name, v_me), 'available');
end;
$$;

-- ------------------------------------------------------ execute privileges

-- New functions are executable by PUBLIC by default; close them as 0005 does
-- and open only the RPC.
revoke execute on function
  public.display_name_normalize(text),
  public.display_name_blocked(text),
  public.display_name_problem(text, uuid),
  public.display_name_placeholder(uuid),
  public.display_name_available(text)
from public, anon, authenticated;
grant execute on function
  public.display_name_normalize(text),
  public.display_name_blocked(text),
  public.display_name_problem(text, uuid),
  public.display_name_placeholder(uuid),
  public.display_name_available(text)
to service_role;
grant execute on function public.display_name_available(text) to authenticated;
