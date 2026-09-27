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

alter table public.friendships   replica identity full;
alter table public.meet_requests replica identity full;
;
