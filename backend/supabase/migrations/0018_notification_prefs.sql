-- 0018 Notification preferences (specs/04-SCHEMA.md sections 2, 3 and 6;
-- specs/11-SETUP-RELEASE.md section 5). Additive: one owner-only table, two
-- client RPCs, and `push_outbox_claim` with one more retirement rule. Nothing
-- existing is removed or rewritten. A user with no row gets every notification,
-- as before this migration, so the live accounts are unchanged.
--
-- The user mutes kinds; everything else stays on. The choice is decided where
-- the push worker claims its batch, like the stale and collapse rules: a muted
-- row is retired there with `last_error = 'muted'` and never reaches APNs, so
-- the worker needs no change and a mute applies to rows already queued.

-- --------------------------------------------------------- notification_prefs

-- The check is the notification set of 0002's push_outbox, so only a real kind
-- can be muted.
create table public.notification_prefs (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  muted_kinds text[] not null default '{}'
    check (array_position(muted_kinds, null) is null
           and muted_kinds <@ array['meet.proposed', 'meet.accepted', 'meet.declined', 'meet.partner_arrived',
                                    'meet.ended', 'meet.expired', 'friend.requested', 'friend.accepted']::text[]),
  updated_at timestamptz not null default now()
);

-- Service role only, like device_tokens: the owner reads and writes through
-- the RPCs below, and nobody else can see what someone muted.
alter table public.notification_prefs enable row level security;
revoke all on public.notification_prefs from public, anon, authenticated;

-- --------------------------------------------------------------- client RPCs

-- The caller's muted kinds, sorted; empty when every notification is on.
create function public.notification_prefs()
returns text[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_muted text[];
begin
  select np.muted_kinds into v_muted from notification_prefs np where np.user_id = v_me;
  return coalesce(v_muted, '{}'::text[]);
end;
$$;

-- Replaces the caller's muted kinds and returns them as stored: each kind once,
-- sorted. Null or empty turns every notification back on. A kind outside the
-- notification set (or a null element) is `invalid` and changes nothing.
create function public.notification_prefs_set(p_muted text[])
returns text[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_muted text[];
begin
  if array_position(p_muted, null) is not null then
    raise exception 'invalid';
  end if;
  select coalesce(array_agg(distinct k order by k), '{}'::text[]) into v_muted
  from unnest(coalesce(p_muted, '{}'::text[])) as k;
  begin
    insert into notification_prefs (user_id, muted_kinds, updated_at)
    values (v_me, v_muted, clock())
    on conflict (user_id) do update
      set muted_kinds = excluded.muted_kinds, updated_at = excluded.updated_at;
  exception when check_violation then
    raise exception 'invalid';
  end;
  return v_muted;
end;
$$;

-- ------------------------------------------------------- push_outbox_claim

-- As in 0004, with one rule first: a row whose kind its recipient has muted is
-- retired as 'muted'. A muted row carries an error, so it never counts as a
-- recent send for the 60-second collapse.
create or replace function public.push_outbox_claim(p_limit int default 25)
returns table (id bigint, user_id uuid, kind text, payload jsonb, tokens jsonb)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_now timestamptz := clock();
begin
  update push_outbox o
  set sent_at = v_now, last_error = 'muted'
  where o.sent_at is null
    and exists (
      select 1 from notification_prefs np
      where np.user_id = o.user_id and o.kind = any (np.muted_kinds));

  update push_outbox o
  set sent_at = v_now, last_error = 'stale'
  where o.sent_at is null and o.created_at < v_now - interval '15 minutes';

  update push_outbox o
  set sent_at = v_now, last_error = 'collapsed'
  where o.sent_at is null
    and o.payload ? 'meet_id'
    and exists (
      select 1 from push_outbox n
      where n.id <> o.id and n.user_id = o.user_id and n.kind = o.kind
        and n.payload ->> 'meet_id' = o.payload ->> 'meet_id'
        and ((n.sent_at is null and n.id > o.id)
          or (n.sent_at is not null and n.last_error is null
              and n.sent_at > v_now - interval '60 seconds')));

  return query
    with due as (
      select o.id
      from push_outbox o
      where o.sent_at is null and (o.leased_until is null or o.leased_until < v_now)
      order by o.id
      limit greatest(least(coalesce(p_limit, 25), 100), 1)
      for update skip locked
    ), claimed as (
      update push_outbox o
      set leased_until = v_now + interval '2 minutes', attempts = o.attempts + 1
      from due
      where o.id = due.id
      returning o.id, o.user_id, o.kind, o.payload
    )
    select c.id, c.user_id, c.kind, c.payload,
           coalesce((
             select jsonb_agg(jsonb_build_object('token', dt.token, 'environment', dt.environment))
             from device_tokens dt
             where dt.user_id = c.user_id), '[]'::jsonb)
    from claimed c
    order by c.id;
end;
$$;

-- ------------------------------------------------------ execute privileges

-- New functions are executable by PUBLIC by default; close them as 0005 does
-- and open only the two client RPCs. `create or replace` keeps the claim's
-- existing privileges (service role only).
revoke execute on function
  public.notification_prefs(),
  public.notification_prefs_set(text[])
from public, anon, authenticated;
grant execute on function
  public.notification_prefs(),
  public.notification_prefs_set(text[])
to service_role, authenticated;
