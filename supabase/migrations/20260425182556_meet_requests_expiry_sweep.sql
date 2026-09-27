-- Server-side sweep: mark `pending` meet_requests as `expired` once expires_at passes.

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

revoke all on function public.expire_stale_meet_requests() from public;
revoke all on function public.expire_stale_meet_requests() from authenticated;
grant execute on function public.expire_stale_meet_requests() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('pm-meet-requests-expire')
      where exists (
        select 1 from cron.job where jobname = 'pm-meet-requests-expire'
      );
    perform cron.schedule(
      'pm-meet-requests-expire',
      '* * * * *',
      $cron$select public.expire_stale_meet_requests();$cron$
    );
  else
    raise notice 'pg_cron not installed - call public.expire_stale_meet_requests() manually or schedule externally.';
  end if;
end $$;;
