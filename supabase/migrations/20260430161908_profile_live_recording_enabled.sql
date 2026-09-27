alter table public.profiles
  add column if not exists live_recording_enabled boolean not null default true;;
