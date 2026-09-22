-- APNs device tokens + push fan-out triggers.

-- 1. device_tokens table
create table if not exists public.device_tokens (
    profile_id  uuid        not null references auth.users(id) on delete cascade,
    token       text        not null,
    platform    text        not null default 'ios',
    updated_at  timestamptz not null default now(),
    primary key (profile_id, token)
);

create index if not exists device_tokens_profile_idx
    on public.device_tokens (profile_id);

alter table public.device_tokens enable row level security;

drop policy if exists "device_tokens_owner_select" on public.device_tokens;
create policy "device_tokens_owner_select"
    on public.device_tokens for select
    using (auth.uid() = profile_id);

drop policy if exists "device_tokens_owner_upsert" on public.device_tokens;
create policy "device_tokens_owner_upsert"
    on public.device_tokens for insert
    with check (auth.uid() = profile_id);

drop policy if exists "device_tokens_owner_update" on public.device_tokens;
create policy "device_tokens_owner_update"
    on public.device_tokens for update
    using (auth.uid() = profile_id)
    with check (auth.uid() = profile_id);

drop policy if exists "device_tokens_owner_delete" on public.device_tokens;
create policy "device_tokens_owner_delete"
    on public.device_tokens for delete
    using (auth.uid() = profile_id);

-- 2. send_push helper (uses pg_net for HTTP POST; see migration notes)
create extension if not exists pg_net with schema extensions;

create or replace function public.send_push(
    user_id uuid,
    kind    text,
    payload jsonb
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_url text := current_setting('app.send_push_url', true);
    v_anon_key text := current_setting('app.send_push_anon_key', true);
begin
    if v_url is null or v_url = '' then
        return;
    end if;

    perform extensions.http_post(
        url := v_url,
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || coalesce(v_anon_key, '')
        ),
        body := jsonb_build_object(
            'user_id', user_id,
            'kind',    kind,
            'payload', payload
        )
    );
exception when others then
    raise warning 'send_push failed for kind=% user=%: %', kind, user_id, sqlerrm;
end;
$$;

-- 3. Triggers
create or replace function public.notify_friend_request_insert()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
    if NEW.status = 'pending' then
        perform public.send_push(
            NEW.addressee_id,
            'friend_request',
            jsonb_build_object('requester_id', NEW.requester_id)
        );
    end if;
    return NEW;
end;
$$;

drop trigger if exists trg_notify_friend_request_insert on public.friendships;
create trigger trg_notify_friend_request_insert
    after insert on public.friendships
    for each row execute function public.notify_friend_request_insert();

create or replace function public.notify_friend_accepted()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
    if NEW.status = 'accepted' and (OLD.status is distinct from 'accepted') then
        perform public.send_push(
            NEW.requester_id,
            'friend_added',
            jsonb_build_object('addressee_id', NEW.addressee_id)
        );
    end if;
    return NEW;
end;
$$;

drop trigger if exists trg_notify_friend_accepted on public.friendships;
create trigger trg_notify_friend_accepted
    after update on public.friendships
    for each row execute function public.notify_friend_accepted();

create or replace function public.notify_meet_request_insert()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
    if NEW.status = 'pending' then
        perform public.send_push(
            NEW.receiver_id,
            'meet_request',
            jsonb_build_object('sender_id', NEW.sender_id, 'meeting_node_id', NEW.meeting_node_id)
        );
    end if;
    return NEW;
end;
$$;

drop trigger if exists trg_notify_meet_request_insert on public.meet_requests;
create trigger trg_notify_meet_request_insert
    after insert on public.meet_requests
    for each row execute function public.notify_meet_request_insert();

create or replace function public.notify_meet_accepted()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
    if NEW.status = 'accepted' and (OLD.status is distinct from 'accepted') then
        perform public.send_push(
            NEW.sender_id,
            'meet_started',
            jsonb_build_object('receiver_id', NEW.receiver_id)
        );
    end if;
    return NEW;
end;
$$;

drop trigger if exists trg_notify_meet_accepted on public.meet_requests;
create trigger trg_notify_meet_accepted
    after update on public.meet_requests
    for each row execute function public.notify_meet_accepted();;
