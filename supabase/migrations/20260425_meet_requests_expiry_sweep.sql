-- Server-side sweep: mark `pending` meet_requests as `expired` once their
-- `expires_at` passes.
--
-- Today the client filters expired rows locally in
-- `MeetRequestService.loadIncoming()`. That works for the current app, but:
--
--   - Clients with stale code (or future revisions that change the filter)
--     keep showing rows past their TTL.
--   - Realtime subscribers keep receiving INSERT/UPDATE events for rows that
--     are already, by app semantics, dead.
--   - The `meet_requests_status_check` CHECK now formally recognizes
--     `expired` as a status, so no client should be storing it from the
--     pending side anyway.
--
-- A pg_cron job that flips status to `expired` every minute closes that gap
-- for free. RLS is unchanged — the row is still owned by the same parties,
-- just with status='expired' which the client filter already excludes.
--
-- Falls back gracefully on environments without pg_cron: the cron call is
-- guarded so the migration succeeds either way; the function is still
-- available for manual invocation or replication via Edge Function.

begin;

-- ── 1. The sweep function ─────────────────────────────────────────────────

create or replace function public.expire_stale_meet_requests()
returns integer
language sql
security definer
set search_path = public
as $$
  with bumped as (
    update public.meet_requests
       set status = 'expired'
     where status = 'pending'
       and expires_at is not null
       and expires_at < now()
     returning 1
  )
  select count(*)::int from bumped;
$$;

-- Allow `service_role` (the role pg_cron uses) to run it. Authenticated
-- users have no business calling this directly — the function bumps rows
-- they don't own.
revoke all on function public.expire_stale_meet_requests() from public;
revoke all on function public.expire_stale_meet_requests() from authenticated;
grant execute on function public.expire_stale_meet_requests() to service_role;

-- ── 2. Schedule via pg_cron when available ────────────────────────────────
--
-- Supabase ships pg_cron on most plans but not all. Guard so the migration
-- succeeds either way — operators on the unguarded plan can call the
-- function manually or replicate via Vercel Cron / Edge Function.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- Re-create idempotently. cron.schedule is overload-friendly: this
    -- returns the job id but we ignore it.
    perform cron.unschedule('pm-meet-requests-expire')
      where exists (
        select 1 from cron.job where jobname = 'pm-meet-requests-expire'
      );
    perform cron.schedule(
      'pm-meet-requests-expire',
      '* * * * *',  -- every minute
      $cron$select public.expire_stale_meet_requests();$cron$
    );
  else
    raise notice 'pg_cron not installed — call public.expire_stale_meet_requests() manually or schedule externally.';
  end if;
end $$;

commit;
