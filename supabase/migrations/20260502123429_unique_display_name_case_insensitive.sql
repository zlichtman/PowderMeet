-- Enforce unique display names (case-insensitive) on profiles.
-- Empty placeholders are excluded so the trigger-created
-- "create row first, fill in display name later" path stays free
-- of false collisions.

create unique index if not exists profiles_display_name_lower_idx
    on public.profiles (lower(display_name))
    where display_name <> '';

-- Update handle_new_user so a conflict at trigger time doesn't
-- 500 the entire auth signup. The supplied name is only used if
-- nobody else already has it (case-insensitive); otherwise the
-- profile lands with an empty display_name and the app's existing
-- name-edit UI on the Profile tab lets the user pick something.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
    raw_name text := coalesce(new.raw_user_meta_data ->> 'display_name', '');
    final_name text := '';
begin
    if raw_name <> '' and not exists (
        select 1 from public.profiles
        where lower(display_name) = lower(raw_name)
    ) then
        final_name := raw_name;
    end if;
    insert into public.profiles (id, display_name)
    values (new.id, final_name);
    return new;
end;
$$;;
