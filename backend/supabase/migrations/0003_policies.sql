-- 0003 Authorization: helpers used by policies, row level security, select
-- grants, read views and storage. specs/04-SCHEMA.md sections 1, 3 and 8.
--
-- Clients read through policies and write through RPCs. No policy and no grant
-- in this file lets `authenticated` or `anon` insert, update or delete a row in
-- `public`.

-- ---------------------------------------------------------------- helpers

-- Server time. Every expiry and TTL reads this, never the phone's clock (I-24).
-- A session that did not arrive through the API (pgTAP, psql) may pin the time
-- with `set powdermeet.clock`; API sessions always get now().
create function public.clock()
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_override text;
begin
  if session_user = 'authenticator' then
    return now();
  end if;
  v_override := nullif(current_setting('powdermeet.clock', true), '');
  if v_override is null then
    return now();
  end if;
  return v_override::timestamptz;
end;
$$;

-- True when a and b are accepted friends and neither has blocked the other.
-- A client may only ask about a pair it belongs to, so the function cannot be
-- used to map other people's friendships.
create function public.is_accepted_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select a is not null and b is not null and a <> b
    and ((select auth.uid()) in (a, b)
         or coalesce((select auth.role()), 'server') not in ('authenticated', 'anon'))
    and exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = a and f.addressee_id = b) or (f.requester_id = b and f.addressee_id = a)))
    and not exists (
      select 1 from public.user_blocks ub
      where (ub.blocker_id = a and ub.blocked_id = b) or (ub.blocker_id = b and ub.blocked_id = a));
$$;

-- ---------------------------------------------------- row level security

alter table public.resorts enable row level security;
alter table public.resort_bundles enable row level security;
alter table public.resort_active_bundle enable row level security;
alter table public.resort_bundle_publications enable row level security;
alter table public.resort_status enable row level security;
alter table public.resort_conditions enable row level security;
alter table public.profiles enable row level security;
alter table public.user_blocks enable row level security;
alter table public.friendships enable row level security;
alter table public.meets enable row level security;
alter table public.meet_progress enable row level security;
alter table public.presence enable row level security;
alter table public.descents enable row level security;
alter table public.descent_matches enable row level security;
alter table public.pace_observations enable row level security;
alter table public.pace_models enable row level security;
alter table public.device_tokens enable row level security;
alter table public.push_outbox enable row level security;
alter table public.jobs enable row level security;
alter table public.client_events enable row level security;
alter table public.app_config enable row level security;
alter table public.rate_limits enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- ------------------------------------------------- resort catalog (public)

create policy resorts_read on public.resorts
  for select to anon, authenticated
  using (published);

create policy resort_bundles_read on public.resort_bundles
  for select to anon, authenticated
  using (exists (select 1 from public.resorts r where r.id = resort_id and r.published));

create policy resort_active_bundle_read on public.resort_active_bundle
  for select to anon, authenticated
  using (exists (select 1 from public.resorts r where r.id = resort_id and r.published));

create policy resort_bundle_publications_read on public.resort_bundle_publications
  for select to anon, authenticated
  using (exists (select 1 from public.resorts r where r.id = resort_id and r.published));

create policy resort_status_read on public.resort_status
  for select to anon, authenticated
  using (exists (select 1 from public.resorts r where r.id = resort_id and r.published));

create policy resort_conditions_read on public.resort_conditions
  for select to anon, authenticated
  using (exists (select 1 from public.resorts r where r.id = resort_id and r.published));

create policy app_config_read on public.app_config
  for select to anon, authenticated
  using (true);

grant select on public.resorts, public.resort_bundles, public.resort_active_bundle,
  public.resort_bundle_publications, public.resort_status, public.resort_conditions,
  public.app_config
  to anon, authenticated;

-- ------------------------------------------------------- people and social

-- Self and accepted friends only. A pending request does not open the row:
-- anyone can create a pending request, so it must not reveal ability or the
-- resort someone is at. Pending names and avatars come from social_snapshot().
create policy profiles_read on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or public.is_accepted_friend((select auth.uid()), id));

-- Contact hashes are never readable through the API, not even by friends: a
-- phone hash is reversible by brute force. Height and weight are the owner's
-- alone and come back only through profile_private(). Clients must name
-- columns; `select *` on profiles is denied.
grant select (id, display_name, avatar_url, ability, max_difficulty, baseline_speeds,
              equipment, avoid, max_pitch_deg, current_resort_id, created_at, updated_at)
  on public.profiles to authenticated;

create policy user_blocks_read on public.user_blocks
  for select to authenticated
  using (blocker_id = (select auth.uid()));
grant select on public.user_blocks to authenticated;

create policy friendships_read on public.friendships
  for select to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));
grant select on public.friendships to authenticated;

-- ------------------------------------------------------------------ meets

create policy meets_read on public.meets
  for select to authenticated
  using ((select auth.uid()) in (proposer_id, invitee_id));
grant select on public.meets to authenticated;

create policy meet_progress_read on public.meet_progress
  for select to authenticated
  using (exists (
    select 1 from public.meets m
    where m.meet_id = meet_progress.meet_id
      and (select auth.uid()) in (m.proposer_id, m.invitee_id)));
grant select on public.meet_progress to authenticated;

-- --------------------------------------------------------------- presence

-- The 15 minute TTL runs on received_at (server time), not the sender's
-- captured_at, so a phone with a wrong clock cannot stretch its own visibility.
create policy presence_read on public.presence
  for select to authenticated
  using (user_id = (select auth.uid())
         or (public.is_accepted_friend((select auth.uid()), user_id)
             and received_at > public.clock() - interval '15 minutes'));
grant select on public.presence to authenticated;

-- --------------------------------------------------------- activity, pace

create policy descents_read on public.descents
  for select to authenticated
  using (owner_id = (select auth.uid()));
grant select on public.descents to authenticated;

create policy descent_matches_read on public.descent_matches
  for select to authenticated
  using (exists (
    select 1 from public.descents d
    where d.descent_id = descent_matches.descent_id and d.owner_id = (select auth.uid())));
grant select on public.descent_matches to authenticated;

create policy pace_observations_read on public.pace_observations
  for select to authenticated
  using (owner_id = (select auth.uid()));
grant select on public.pace_observations to authenticated;

create policy pace_models_read on public.pace_models
  for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_accepted_friend((select auth.uid()), owner_id));
grant select on public.pace_models to authenticated;

-- device_tokens, push_outbox, jobs, rate_limits and client_events have no
-- policy and no grant: service role only.

-- ------------------------------------------------------------------ views
-- All views run with the caller's rights, so the policies above still apply.

create view public.published_resorts with (security_invoker = true) as
  select r.id, r.name, r.timezone, r.bbox, r.center, r.camera, r.pass_products,
         r.status_provider, r.status_mode, r.review_minutes,
         ab.bundle_id, ab.published_at
  from public.resorts r
  left join public.resort_active_bundle ab on ab.resort_id = r.id
  where r.published;

create view public.resort_status_current with (security_invoker = true) as
  select distinct on (s.resort_id) s.*
  from public.resort_status s
  order by s.resort_id, s.observed_at desc, s.id desc;

create view public.resort_conditions_current with (security_invoker = true) as
  select distinct on (c.resort_id) c.*
  from public.resort_conditions c
  order by c.resort_id, c.observed_at desc, c.id desc;

create view public.pace_models_friend_read with (security_invoker = true) as
  select pm.owner_id, pm.computed_at, pm.difficulty_factor, pm.edge_factor, pm.stops_per_km, pm.n_descents
  from public.pace_models pm;

create view public.friends_view with (security_invoker = true) as
  select p.id as user_id, p.display_name, p.avatar_url
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester_id = (select auth.uid()) then f.addressee_id else f.requester_id end
  where f.status = 'accepted'
    and (select auth.uid()) in (f.requester_id, f.addressee_id);

revoke all on public.published_resorts, public.resort_status_current, public.resort_conditions_current,
  public.pace_models_friend_read, public.friends_view
  from anon, authenticated;
grant select on public.published_resorts, public.resort_status_current, public.resort_conditions_current
  to anon, authenticated;
grant select on public.pace_models_friend_read, public.friends_view to authenticated;

-- ---------------------------------------------------------------- storage

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('resort-bundles', 'resort-bundles', true, 67108864, null),
  ('resort-reports', 'resort-reports', true, 67108864, null),
  ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Public buckets are read through the public object URL, which needs no
-- policy. Bundles and reports are written by the service role only. A user may
-- write, replace and remove objects under `avatars/<own user id>/` and nothing
-- else.
create policy avatars_owner_select on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy avatars_owner_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy avatars_owner_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy avatars_owner_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
