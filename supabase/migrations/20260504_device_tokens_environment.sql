-- Per-device-token APNs environment.
--
-- Apple's modern APNs auth keys are env-scoped (Sandbox xor Production)
-- so a single key can't authenticate to both servers. Without this
-- column, the `send-push` edge function had to pick one environment
-- via `APNS_ENVIRONMENT` env var and broke pushes to the OTHER
-- environment. Now each `device_tokens` row records the environment
-- the device registered under, and the edge function picks the
-- matching key per recipient.
--
-- Existing rows default to 'sandbox' — that matches the current
-- deployment state where dev builds are the only thing pushing
-- tokens. When TestFlight builds register, the iOS client stamps
-- 'production' explicitly via #if DEBUG / else.

alter table public.device_tokens
  add column if not exists environment text not null default 'sandbox'
    check (environment in ('sandbox', 'production'));

create index if not exists device_tokens_profile_environment_idx
  on public.device_tokens (profile_id, environment);
