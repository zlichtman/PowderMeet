-- 0007 Schedules. specs/04-SCHEMA.md section 7. Times are UTC.
--
-- Workers are edge functions called through pg_net with the `x-worker-secret`
-- header. The project URL and the secret are read from Vault at call time
-- (`project_url`, `worker_secret`); neither appears in any migration. Until
-- both exist the pings do nothing and the queues simply wait.

select cron.schedule('expire_meets', '* * * * *', $$select public.expire_meets()$$);
select cron.schedule('presence_cleanup', '*/10 * * * *', $$select public.presence_cleanup()$$);

select cron.schedule('enqueue_status_refresh', '*/15 * * * *', $$select public.enqueue_status_refresh()$$);
select cron.schedule('enqueue_conditions_refresh', '5 * * * *', $$select public.enqueue_conditions_refresh()$$);
select cron.schedule('scheduled_status_rows', '0 * * * *', $$select public.scheduled_status_rows()$$);

select cron.schedule('push_drain_ping', '* * * * *', $$select public.push_drain_ping()$$);
-- Every minute, up to 20 jobs each: sized for about 160 published resorts with
-- one job per worker invocation.
select cron.schedule('status_worker_ping', '* * * * *',
  $$select public.worker_ping_pending('status_refresh', 'status-refresh')$$);
select cron.schedule('conditions_worker_ping', '* * * * *',
  $$select public.worker_ping_pending('conditions_refresh', 'conditions-refresh')$$);

select cron.schedule('housekeeping', '20 9 * * *', $$select public.housekeeping()$$);
