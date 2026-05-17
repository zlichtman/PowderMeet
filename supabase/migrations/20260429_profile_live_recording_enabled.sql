-- Live-recording feature gate.
--
-- Boolean column on `profiles` that lets the user toggle the in-app
-- LiveRunRecorder. When true (default), CoreLocation fixes are
-- segmented into runs in-process and persisted to `imported_runs`
-- with source = 'live'. When false, the recorder ignores incoming
-- fixes — same downstream contract as a Slopes import being skipped.
--
-- Defaulting to true is deliberate: live recording is the core value
-- prop of the live-skiing loop. Users who want full control over
-- what data lands in the algorithm flip it off in Profile › ACTIVITY.
-- The Swift `UserProfile` decoder also defaults this field to true so
-- a stale-cached profile JSON without the column behaves identically.

alter table public.profiles
  add column if not exists live_recording_enabled boolean not null default true;
