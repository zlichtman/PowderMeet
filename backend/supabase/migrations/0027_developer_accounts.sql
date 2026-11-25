-- 0027 Developer accounts. specs/04-SCHEMA.md sections 2, 3, 6 and 10.
--
-- The app's Dev page used to open for every TestFlight tester. The server now
-- keeps the list of accounts that may see it; the app asks `is_developer()`.
-- Rows are added by the owner in the dashboard (service role), never by a
-- migration and never by a client.

create table public.developer_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.developer_accounts enable row level security;
revoke all on public.developer_accounts from public, anon, authenticated;

create function public.is_developer()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.developer_accounts where user_id = (select auth.uid())
  );
$$;

revoke execute on function public.is_developer() from public, anon, authenticated;
grant execute on function public.is_developer() to service_role;
grant execute on function public.is_developer() to authenticated;
