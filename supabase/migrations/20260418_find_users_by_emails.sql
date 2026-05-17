-- Email-based contact-suggestions lookup. Mirrors find_users_by_phones.
-- Already applied to the remote DB via Supabase MCP on 2026-04-18 — this file
-- exists so `supabase db pull`/`db push` stays coherent with server state.
--
-- Case-insensitive match: Supabase Auth normally lowercases emails, but the
-- caller's array may carry mixed case from Contacts, so we fold both sides.

create or replace function public.find_users_by_emails(emails text[])
returns setof profiles
language sql
security definer
set search_path to 'public', 'auth'
as $function$
  select p.* from profiles p
  join auth.users u on u.id = p.id
  where lower(u.email) = any(select lower(e) from unnest(emails) e)
$function$;
