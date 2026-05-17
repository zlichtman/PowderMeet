-- Hourly cron: hits the refresh-live-status edge function so per-resort
-- live blobs stay current without manual triggers.
--
-- Schedule: minute 5 every hour. The :5 offset (vs :0) gives breathing
-- room past the top of the hour for any other hourly batch jobs.
--
-- Auth: anon JWT in Authorization header is enough to satisfy the
-- function's `verify_jwt = true` requirement. The function does its
-- own writes via SUPABASE_SERVICE_ROLE_KEY (set in function env),
-- so the request JWT is just a gate-pass.
--
-- Already registered in production via Supabase MCP. This file mirrors
-- the live state so version control stays in sync.
--
-- The anon JWT below is the legacy anon key returned from
-- get-publishable-keys. It is the same JWT distributed to every iOS
-- client and is not a secret in the cryptographic sense.

select cron.schedule(
  'refresh_live_status_hourly',
  '5 * * * *',
  $$
    select net.http_post(
      url := 'https://qtzjxquzyrwavhvqarvg.supabase.co/functions/v1/refresh-live-status',
      headers := jsonb_build_object(
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF0emp4cXV6eXJ3YXZodnFhcnZnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5OTUxMjYsImV4cCI6MjA4ODU3MTEyNn0.adPonS8qEXvd0-tkWoKos9Cq2C8C7HEZL5iTht-FXAs',
        'Content-Type', 'application/json'
      ),
      body := '{}'::jsonb
    );
  $$
);
