-- Drop long-dormant profile columns.
--
-- These columns were left in `public.profiles` after their UI was removed
-- and the solver stopped consulting them:
--
--   home_resort_id          (UI removed)
--   meet_preference         (UI removed; solver never read it)
--   aspect_preference       (solver does not consult; absent on this DB)
--   prefer_night_skiing     (solver does not consult; absent on this DB)
--   allow_down_lift         (zero Swift code references; introspection
--                            on 2026-05-02 found 0 of 3 profiles with it
--                            set true — orphan column)
--
-- The Swift `UserProfile` model already omits all of them. Pre-flight
-- audit (functions / RLS policies / views) found zero references, and
-- a row scan returned 0 non-default values across the live profiles
-- table, so removal is data-loss-free.
--
-- Idempotent: each `drop column if exists` is a no-op when the column is
-- already absent.

begin;

alter table public.profiles drop column if exists home_resort_id;
alter table public.profiles drop column if exists meet_preference;
alter table public.profiles drop column if exists aspect_preference;
alter table public.profiles drop column if exists prefer_night_skiing;
alter table public.profiles drop column if exists allow_down_lift;

commit;
