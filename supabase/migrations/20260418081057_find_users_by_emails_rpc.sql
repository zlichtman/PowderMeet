create or replace function public.find_users_by_emails(emails text[])
returns setof profiles
language sql
security definer
set search_path to 'public', 'auth'
as $function$
  select p.* from profiles p
  join auth.users u on u.id = p.id
  where lower(u.email) = any(select lower(e) from unnest(emails) e)
$function$;;
