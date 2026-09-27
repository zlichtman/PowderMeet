-- Reconstruct the schema that predated this repository's migration history.
--
-- This migration deliberately sorts before every existing migration. It is
-- also safe to apply late with `supabase db push --include-all`: production
-- already has these objects, so guarded DDL leaves them untouched while a new
-- project receives the exact prerequisites the incremental history expects.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_url text,
  skill_level text not null default 'intermediate',
  speed_green double precision default 7.0,
  speed_blue double precision default 5.0,
  speed_black double precision default 3.0,
  speed_double_black double precision,
  speed_terrain_park double precision default 4.0,
  condition_moguls double precision not null default 0.5,
  condition_ungroomed double precision not null default 0.6,
  condition_icy double precision not null default 0.5,
  condition_gladed double precision not null default 0.4,
  onboarding_completed boolean not null default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  current_resort_id text
);

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending',
  created_at timestamptz default now(),
  constraint friendships_requester_id_addressee_id_key
    unique (requester_id, addressee_id),
  constraint friendships_status_check
    check (status in ('pending', 'accepted'))
);

create table if not exists public.meet_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid references auth.users(id) on delete cascade,
  receiver_id uuid references auth.users(id) on delete cascade,
  resort_id text not null,
  meeting_node_id text not null,
  meeting_node_elevation double precision not null default 0,
  status text not null default 'pending',
  created_at timestamptz default now(),
  expires_at timestamptz,
  meeting_node_display_name text,
  sender_position_node_id text,
  receiver_position_node_id text,
  sender_eta_seconds double precision,
  receiver_eta_seconds double precision,
  constraint meet_requests_status_check
    check (status in ('pending', 'accepted', 'declined', 'expired'))
);

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.meet_requests enable row level security;

do $foundation$
begin
  if to_regprocedure('public.update_updated_at()') is null then
    execute $function$
      create function public.update_updated_at()
      returns trigger
      language plpgsql
      set search_path = public
      as $body$
      begin
        new.updated_at = now();
        return new;
      end;
      $body$
    $function$;
  end if;

  if to_regprocedure('public.handle_new_user()') is null then
    execute $function$
      create function public.handle_new_user()
      returns trigger
      language plpgsql
      security definer
      set search_path = public, auth
      as $body$
      declare
        raw_name text := coalesce(new.raw_user_meta_data ->> 'display_name', '');
        final_name text := '';
      begin
        if raw_name <> '' and not exists (
          select 1
          from public.profiles
          where lower(display_name) = lower(raw_name)
        ) then
          final_name := raw_name;
        end if;

        insert into public.profiles (id, display_name)
        values (new.id, final_name);
        return new;
      end;
      $body$
    $function$;
  end if;

  if to_regprocedure('public.find_users_by_phones(text[])') is null then
    execute $function$
      create function public.find_users_by_phones(phones text[])
      returns setof public.profiles
      language sql
      security definer
      set search_path = public, auth
      as $body$
        select distinct on (p.id) p.*
        from public.profiles p
        join auth.users u on u.id = p.id
        where u.phone is not null
          and regexp_replace(u.phone, '\D', '', 'g') = any(phones)
      $body$
    $function$;
  end if;

  if to_regprocedure('public.delete_user_account()') is null then
    execute $function$
      create function public.delete_user_account()
      returns void
      language plpgsql
      security definer
      set search_path = public, auth
      as $body$
      declare
        uid uuid := auth.uid();
      begin
        delete from public.friendships
        where requester_id = uid or addressee_id = uid;

        delete from public.meet_requests
        where sender_id = uid or receiver_id = uid;

        delete from public.profiles where id = uid;
        delete from auth.users where id = uid;
      end;
      $body$
    $function$;
  end if;

  -- Supabase production projects may install this helper out of band. The
  -- checked-in security history revokes its client permission, so fresh local
  -- replays need the same function even when the platform event trigger is
  -- absent.
  if to_regprocedure('public.rls_auto_enable()') is null then
    execute $function$
      create function public.rls_auto_enable()
      returns event_trigger
      language plpgsql
      security definer
      set search_path = pg_catalog
      as $body$
      declare
        cmd record;
      begin
        for cmd in
          select *
          from pg_event_trigger_ddl_commands()
          where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
            and object_type in ('table', 'partitioned table')
        loop
          if cmd.schema_name is not null
             and cmd.schema_name = 'public'
             and cmd.schema_name not in ('pg_catalog', 'information_schema')
             and cmd.schema_name not like 'pg_toast%'
             and cmd.schema_name not like 'pg_temp%' then
            begin
              execute format(
                'alter table if exists %s enable row level security',
                cmd.object_identity
              );
              raise log 'rls_auto_enable: enabled RLS on %',
                cmd.object_identity;
            exception when others then
              raise log 'rls_auto_enable: failed to enable RLS on %',
                cmd.object_identity;
            end;
          else
            raise log
              'rls_auto_enable: skip % (either system schema or not in enforced list: %.)',
              cmd.object_identity,
              cmd.schema_name;
          end if;
        end loop;
      end;
      $body$
    $function$;
  end if;
end
$foundation$;

-- Production has this event trigger as platform-created state. Capturing it
-- here closes the final clean-replay gap: every later public table receives
-- RLS even if its historical migration only creates a policy.
do $foundation$
begin
  if not exists (
    select 1
    from pg_event_trigger
    where evtname = 'rls_auto_enable'
      or evtfoid = 'public.rls_auto_enable()'::regprocedure
  ) then
    create event trigger rls_auto_enable
      on ddl_command_end
      execute function public.rls_auto_enable();
  end if;
end
$foundation$;

do $foundation$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.profiles'::regclass
      and not tgisinternal
      and (
        tgname = 'profiles_updated_at'
        or tgfoid = 'public.update_updated_at()'::regprocedure
      )
  ) then
    execute 'create trigger profiles_updated_at
      before update on public.profiles
      for each row execute function public.update_updated_at()';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'auth.users'::regclass
      and not tgisinternal
      and (
        tgname = 'on_auth_user_created'
        or tgfoid = 'public.handle_new_user()'::regprocedure
      )
  ) then
    execute 'create trigger on_auth_user_created
      after insert on auth.users
      for each row execute function public.handle_new_user()';
  end if;
end
$foundation$;

do $foundation$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
      and policyname = 'Profiles are viewable by authenticated users'
  ) then
    execute 'create policy "Profiles are viewable by authenticated users"
      on public.profiles for select to authenticated using (true)';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
      and policyname = 'Users can insert own profile'
  ) then
    execute 'create policy "Users can insert own profile"
      on public.profiles for insert to authenticated
      with check ((select auth.uid()) = id)';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
      and policyname = 'Users can update own profile'
  ) then
    execute 'create policy "Users can update own profile"
      on public.profiles for update to authenticated
      using ((select auth.uid()) = id)';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'friendships'
      and policyname = 'Users can view own friendships'
  ) then
    execute 'create policy "Users can view own friendships"
      on public.friendships for select to authenticated
      using ((select auth.uid()) in (requester_id, addressee_id))';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'friendships'
      and policyname = 'Users can insert friendships'
  ) then
    execute 'create policy "Users can insert friendships"
      on public.friendships for insert to authenticated
      with check ((select auth.uid()) = requester_id)';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'friendships'
      and policyname = 'Users can accept friend requests'
  ) then
    execute 'create policy "Users can accept friend requests"
      on public.friendships for update to authenticated
      using ((select auth.uid()) = addressee_id)';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'friendships'
      and policyname = 'Users can delete own friendships'
  ) then
    execute 'create policy "Users can delete own friendships"
      on public.friendships for delete to authenticated
      using ((select auth.uid()) in (requester_id, addressee_id))';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'meet_requests'
      and policyname = 'Users can read own meet requests'
  ) then
    execute 'create policy "Users can read own meet requests"
      on public.meet_requests for select
      using ((select auth.uid()) in (sender_id, receiver_id))';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'meet_requests'
      and policyname in (
        'Users can respond to meet requests',
        'Users can update own meet requests'
      )
  ) then
    execute 'create policy "Users can respond to meet requests"
      on public.meet_requests for update
      using ((select auth.uid()) = receiver_id)';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'meet_requests'
      and policyname = 'Users can send meet requests'
  ) then
    execute 'create policy "Users can send meet requests"
      on public.meet_requests for insert
      with check ((select auth.uid()) = sender_id)';
  end if;
end
$foundation$;

grant all on table public.profiles to anon, authenticated, service_role;
grant all on table public.friendships to anon, authenticated, service_role;
grant all on table public.meet_requests to anon, authenticated, service_role;

-- The bucket insert is idempotent and intentionally does not overwrite an
-- existing project's visibility/configuration. Later migrations install the
-- final object policies.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;
