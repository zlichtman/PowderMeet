-- pg_cron is available on this Supabase plan (default version 1.6.4
-- per list_extensions on 2026-05-02). Install it and schedule the
-- existing expire_stale_meet_requests sweep so meet_requests don't
-- pile up past their TTL.

create extension if not exists pg_cron;

-- Idempotent: unschedule any existing job with the same name before
-- re-scheduling, so re-running the migration doesn't double up.
do $$
begin
    perform cron.unschedule('expire-stale-meet-requests');
exception when others then
    null;
end;
$$;

select cron.schedule(
    'expire-stale-meet-requests',
    '*/2 * * * *',
    $cron$select public.expire_stale_meet_requests();$cron$
);
