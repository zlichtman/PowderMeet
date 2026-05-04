-- Phone-based contact-suggestions lookup. Mirrors find_users_by_emails.
--
-- Both sides reduce phone numbers to digits only before comparing, so a
-- user signing up with "+1 604 555 1234" matches a contact entry of
-- "(604) 555-1234". The client doesn't know which form the matched
-- account used at sign-up — so PowderMeet/Utilities/PhoneNormalizer.swift
-- emits BOTH the national-only and country-code-prepended candidates
-- per contact, and this function tests against the digit-stripped
-- auth.users.phone column. Either form lining up = a match.
--
-- `security definer` because the join needs auth.users (RLS-protected
-- from regular roles); search_path pinned to prevent search-path
-- shadow attacks. Mirrors find_users_by_emails(text[]).
--
-- DISTINCT ON (p.id) collapses the case where multiple of the caller's
-- candidates land on the same auth.users row (e.g. they had the same
-- contact stored twice with different formatting) so the client gets at
-- most one suggestion per matched user.

create or replace function public.find_users_by_phones(phones text[])
returns setof profiles
language sql
security definer
set search_path to 'public', 'auth'
as $function$
  select distinct on (p.id) p.*
  from profiles p
  join auth.users u on u.id = p.id
  where u.phone is not null
    and regexp_replace(u.phone, '\D', '', 'g') = any(phones)
$function$;

-- Future scaling note: if user count grows past ~50k, add a functional
-- index on auth.users for this comparison:
--
--   create index if not exists users_phone_digits_idx
--     on auth.users ((regexp_replace(phone, '\D', '', 'g')))
--     where phone is not null;
--
-- Indexing auth.users typically requires elevated privileges on
-- Supabase plans, so leaving it out of the migration. The current
-- table-scan-then-filter is fine for the user counts we expect pre-launch.
