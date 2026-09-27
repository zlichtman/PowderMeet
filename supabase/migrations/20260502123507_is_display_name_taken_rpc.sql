-- Pre-signup duplicate check. Anon-callable so the SignUp form can
-- warn the user before submitting (better UX than a Postgres
-- 23505 surfacing as an opaque error after auth.signUp succeeds
-- and the trigger-created row clashes).
create or replace function public.is_display_name_taken(p_name text)
returns bool
language sql
security definer
set search_path = public
as $$
    select case
        when coalesce(trim(p_name), '') = '' then false
        else exists(
            select 1 from public.profiles
            where lower(display_name) = lower(trim(p_name))
        )
    end;
$$;

grant execute on function public.is_display_name_taken(text) to anon, authenticated;;
