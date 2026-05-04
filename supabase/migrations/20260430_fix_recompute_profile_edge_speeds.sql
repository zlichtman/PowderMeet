-- Fix `recompute_profile_edge_speeds`: missing GROUP BY.
--
-- The original definition (in 20260430_profile_edge_speeds.sql) selected
-- `resort_id, edge_id, count(*), avg(speed_ms), ...` from imported_runs
-- with no `GROUP BY`. Postgres rejects this at runtime —
--
--   ERROR: column "imported_runs.edge_id" must appear in the GROUP BY
--   clause or be used in an aggregate function
--
-- — so the RPC has been broken since the table was added; every import
-- silently failed the post-step that rebuilds per-edge skill memory.
-- The client side just `print`-logged the failure, so the user saw
-- nothing.
--
-- The new ActivityImporter banner surfaces this RPC's success/failure
-- explicitly, which is how we noticed. Same body as before, plus the
-- correct `GROUP BY resort_id, edge_id` so each (resort, edge) becomes
-- its own row.
--
-- The conditions_fp column stays at the literal `'default'` for now
-- (matches the original); a future migration can fold real condition
-- buckets in once they're stamped at import-time.

create or replace function public.recompute_profile_edge_speeds(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  delete from public.profile_edge_speeds where profile_id = uid;
  insert into public.profile_edge_speeds (
    profile_id, resort_id, edge_id, conditions_fp,
    observation_count,
    rolling_speed_ms, rolling_peak_ms, rolling_duration_s,
    last_observed_at
  )
  select
    uid,
    coalesce(resort_id, 'unknown'),
    edge_id,
    'default' as conditions_fp,
    count(*)::int,
    avg(speed_ms),
    max(coalesce(peak_speed_ms, speed_ms)),
    avg(duration_s),
    max(run_at)
  from public.imported_runs
  where profile_id = uid
    and edge_id is not null
  group by resort_id, edge_id;
end;
$function$;
