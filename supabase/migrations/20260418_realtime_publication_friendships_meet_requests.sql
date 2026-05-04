-- Add `friendships` and `meet_requests` to the `supabase_realtime` publication.
--
-- **Critical fix.** Without these rows in the publication, every
-- `postgres_changes` subscription on these tables is a silent no-op:
-- the Swift `postgresChange()` call succeeds, the socket is subscribed,
-- and yet no event ever arrives. Users experience this as "friend
-- requests never notify," "accepted state never updates," "meet
-- requests don't deliver until I restart the app." Historically the
-- repo only migrated `live_presence` into the publication; the other
-- two tables were assumed to be in it but may or may not have been
-- added through the Dashboard.
--
-- Idempotent: re-running this migration is a no-op. The `DO` block
-- checks `pg_publication_tables` before issuing `ALTER PUBLICATION`,
-- so it tolerates both "already a member" and "never added" states.
--
-- See repo `CLAUDE.md` — Key architectural invariants (Realtime channels).
--
-- To verify after apply:
--   select tablename from pg_publication_tables
--    where pubname = 'supabase_realtime' order by tablename;
-- Expected to include at least: friendships, live_presence, meet_requests.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename  = 'friendships'
  ) then
    execute 'alter publication supabase_realtime add table public.friendships';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename  = 'meet_requests'
  ) then
    execute 'alter publication supabase_realtime add table public.meet_requests';
  end if;
end $$;

-- Ensure the tables emit full old+new row data for UPDATE/DELETE events so
-- client filters on columns like `status` / `receiver_id` see the previous
-- value. Without REPLICA IDENTITY FULL, Postgres only ships changed columns
-- plus the primary key — the client's filter predicate (e.g. `eq('status',
-- 'pending')`) can miss events when the filter column isn't in the diff.
alter table public.friendships   replica identity full;
alter table public.meet_requests replica identity full;
