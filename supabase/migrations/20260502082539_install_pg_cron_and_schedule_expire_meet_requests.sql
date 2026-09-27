-- pg_cron is on this plan after all (default version 1.6.4 listed by
-- list_extensions). Install it and schedule the existing
-- expire_stale_meet_requests sweep so meet_requests don't pile up
-- past their TTL.
create extension if not exists pg_cron;

-- Idempotent unschedule then re-schedule so re-running the migration
-- doesn't double up.
do $$
begin
    perform cron.unschedule('expire-stale-meet-requests');
exception when others then
    null;  -- no existing job → fine
end;
$$;

select cron.schedule(
    'expire-stale-meet-requests',
    '*/2 * * * *',
    $cron$select public.expire_stale_meet_requests();$cron$
);;
