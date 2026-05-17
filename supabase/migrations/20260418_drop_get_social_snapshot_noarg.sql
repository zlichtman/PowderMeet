-- Drop the legacy no-arg overload of get_social_snapshot.
--
-- The earlier Phase 1 migration (20260418_get_social_snapshot.sql) created
-- `get_social_snapshot(p_resort_id text default null)`. An older no-arg
-- overload from a prior hotfix remained in the DB, so PostgREST could not
-- disambiguate callers and returned PGRST203:
--
--   Could not choose the best candidate function between:
--     public.get_social_snapshot(),
--     public.get_social_snapshot(p_resort_id => text)
--
-- The single-param version with a default covers the zero-arg case, so the
-- old overload is strictly redundant.

drop function if exists public.get_social_snapshot();
