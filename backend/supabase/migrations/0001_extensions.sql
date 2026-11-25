-- 0001 Extensions, default privileges and the RLS safety net.
-- specs/04-SCHEMA.md sections 1 and 11.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- Nothing in `public` is reachable by a client role unless a later migration
-- grants it by name. Supabase's defaults grant everything to anon and
-- authenticated; turn that off for objects created from here on.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- Every table created in `public` gets row level security switched on, so a
-- table added without a policy is closed rather than open. 0003 also enables
-- RLS on each table by name; this covers tables added later.
create or replace function public.rls_auto_enable()
returns event_trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  cmd record;
begin
  for cmd in
    select *
    from pg_event_trigger_ddl_commands()
    where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      and object_type in ('table', 'partitioned table')
  loop
    if cmd.schema_name = 'public' then
      begin
        execute format('alter table if exists %s enable row level security', cmd.object_identity);
      exception when others then
        raise log 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      end;
    end if;
  end loop;
end;
$$;

revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- Hosted projects may already carry this event trigger as platform state, and
-- a role without the privilege to create one must not fail the migration:
-- 0003 enables RLS explicitly and the pgTAP suite checks every table.
do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'rls_auto_enable') then
    create event trigger rls_auto_enable
      on ddl_command_end
      execute function public.rls_auto_enable();
  end if;
exception when others then
  raise notice 'rls_auto_enable event trigger not created: %', sqlerrm;
end;
$$;
