-- 0021 No stored photo outlives its use (specs/04-SCHEMA.md sections 2, 6, 7 and 8).
--
-- The client removes a replaced or removed photo through the Storage API, and
-- removed its files before calling `account_delete`. When that removal fails
-- (offline, app killed) nothing retried it, and `account_delete` then deleted
-- the avatar rows from `storage.objects` with SQL, which removes the row but
-- not the stored file: the bytes were orphaned for good and invisible to the
-- Storage API.
--
-- Now the database only names orphans and an edge worker removes them through
-- the Storage API (row and bytes). `avatar_orphans` lists every avatar object
-- whose owner's profile is gone, and every object older than an hour that is
-- not its owner's current `avatar_url` (the hour covers an upload still waiting
-- for its `profile_update`). An `avatar_sweep` job carries no owner, so it
-- survives the profile it was queued for; `account_delete` queues one and pings
-- `avatar-sweep`, and cron queues one hourly as the retry net.

-- ------------------------------------------------------------- job kind

alter table public.jobs drop constraint jobs_kind_check;
alter table public.jobs add constraint jobs_kind_check
  check (kind in ('status_refresh', 'conditions_refresh', 'push_drain', 'expiry_sweep', 'pace_recompute',
                  'avatar_sweep'));

-- -------------------------------------------------------------- orphans

-- Deleted owners first, so a backlog of stale files never holds a deleted
-- user's photo past the limit. The owner is matched as text: a folder name that
-- is not a user id is simply an orphan, never an error.
create function public.avatar_orphans(p_limit int default 100)
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select o.name
  from storage.objects o
  left join profiles p on p.id::text = (storage.foldername(o.name))[1]
  where o.bucket_id = 'avatars'
    and (p.id is null
         or (o.name is distinct from p.avatar_url and o.created_at < clock() - interval '1 hour'))
  order by (p.id is null) desc, o.created_at, o.name
  limit greatest(least(coalesce(p_limit, 100), 1000), 1);
$$;

-- Queues one sweep unless one is already waiting, and pings the worker.
create function public.avatar_sweep_enqueue()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into jobs (kind, run_after)
  select 'avatar_sweep', clock()
  where not exists (select 1 from jobs j where j.kind = 'avatar_sweep' and j.leased_until is null);
  perform worker_ping('avatar-sweep', 1);
end;
$$;

-- ------------------------------------------------------- account_delete

-- As in 0004, without touching `storage.objects`. The sweep queued here always
-- gets its own job: one already running may have listed orphans before this
-- delete commits.
create or replace function public.account_delete()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  -- Tell partners first, while the profile still exists for the notification.
  update meets m
  set status = 'invalidated', end_reason = 'partner_left', ended_at = clock()
  where m.status in ('proposed', 'active') and v_me in (m.proposer_id, m.invitee_id);

  delete from friendships f where v_me in (f.requester_id, f.addressee_id);
  delete from user_blocks ub where v_me in (ub.blocker_id, ub.blocked_id);
  delete from presence pr where pr.user_id = v_me;
  delete from descents d where d.owner_id = v_me;
  delete from pace_models pm where pm.owner_id = v_me;
  delete from device_tokens dt where dt.user_id = v_me;
  delete from push_outbox po where po.user_id = v_me;

  -- Avatar files left behind (the client's own removal failed) are removed by
  -- the `avatar-sweep` worker through the Storage API once the profile is gone.
  -- The job has no owner, so it does not cascade away with the profile; the
  -- ping is sent after this transaction commits.
  insert into jobs (kind, run_after) values ('avatar_sweep', clock());
  perform worker_ping('avatar-sweep', 1);

  -- The rest (meets, progress, events, rate limits, jobs) cascades.
  delete from profiles p where p.id = v_me;
  delete from auth.users u where u.id = v_me;
end;
$$;

-- ------------------------------------------------------- execute privileges

revoke execute on function public.avatar_orphans(int), public.avatar_sweep_enqueue()
  from public, anon, authenticated;
grant execute on function public.avatar_orphans(int), public.avatar_sweep_enqueue() to service_role;

-- ------------------------------------------------------------------- cron

select cron.schedule('enqueue_avatar_sweep', '40 * * * *', $$select public.avatar_sweep_enqueue()$$);
-- A sweep whose ping was lost, or that failed and is due again.
select cron.schedule('avatar_worker_ping', '* * * * *',
  $$select public.worker_ping_pending('avatar_sweep', 'avatar-sweep')$$);
