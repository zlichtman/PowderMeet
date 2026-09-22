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
$function$;;
