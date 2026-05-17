-- APNs device tokens + push fan-out triggers.
--
-- Two pieces:
--   1. `device_tokens` table — one row per (user, device). RLS scopes
--      writes to the row's owner. Tokens rotate, so upserts target the
--      (profile_id, token) primary key and refresh `updated_at`.
--   2. AFTER triggers on `friend_requests`, `friendships`,
--      `meet_requests` that POST to the `send-push` edge function via
--      `pg_net.http_post`. The edge function takes care of APNs auth
--      and delivery; the trigger only needs to know the recipient
--      user_id + a small payload.
--
-- Manual setup required before pushes actually deliver:
--   - Apple Developer Program → Keys → create an APNs Auth Key (.p8).
--   - Store the .p8 + Key ID + Team ID + bundle id as Supabase secrets
--     (see supabase/functions/send-push/README.md).
--   - Set `app.send_push_url` to the deployed edge function URL.
--
-- Until those are configured, triggers fire harmlessly — the HTTP POST
-- to `send-push` will fail and the trigger logs the error but does NOT
-- block the underlying INSERT/UPDATE.

begin;

-- ── 1. device_tokens table ────────────────────────────────────────

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

-- ── 2. send_push helper ───────────────────────────────────────────
--
-- Wraps the pg_net call so trigger bodies stay short. The edge
-- function URL + anon key are embedded directly because managed
-- Supabase doesn't grant the SQL session permission to set
-- database-level GUCs (`alter database postgres set ...` fails with
-- 42501). The anon key is designed to ship publicly (it's already in
-- the iOS bundle), so embedding it here is no incremental exposure.
--
-- pg_net comes pre-installed on Supabase but lives in the `extensions`
-- schema — the search_path setting on this function is what makes
-- `extensions.http_post` resolve. SECURITY DEFINER lets triggers fire
-- it regardless of the row owner's RLS context.

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
    v_url text := 'https://qtzjxquzyrwavhvqarvg.supabase.co/functions/v1/send-push';
    v_anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF0emp4cXV6eXJ3YXZodnFhcnZnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5OTUxMjYsImV4cCI6MjA4ODU3MTEyNn0.adPonS8qEXvd0-tkWoKos9Cq2C8C7HEZL5iTht-FXAs';
begin
    perform extensions.http_post(
        url := v_url,
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_anon_key
        ),
        body := jsonb_build_object(
            'user_id', user_id,
            'kind',    kind,
            'payload', payload
        )
    );
exception when others then
    -- Never let a failed push abort the underlying mutation.
    raise warning 'send_push failed for kind=% user=%: %', kind, user_id, sqlerrm;
end;
$$;

-- ── 3. Triggers ───────────────────────────────────────────────────

-- friend_requests INSERT (status pending) → push the receiver.
create or replace function public.notify_friend_request_insert()
returns trigger language plpgsql security definer as $$
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

-- friendships UPDATE (status pending → accepted) → push the requester.
create or replace function public.notify_friend_accepted()
returns trigger language plpgsql security definer as $$
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

-- meet_requests INSERT (status pending) → push the receiver.
create or replace function public.notify_meet_request_insert()
returns trigger language plpgsql security definer as $$
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

-- meet_requests UPDATE (status pending → accepted) → push the sender.
create or replace function public.notify_meet_accepted()
returns trigger language plpgsql security definer as $$
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
    for each row execute function public.notify_meet_accepted();

commit;
