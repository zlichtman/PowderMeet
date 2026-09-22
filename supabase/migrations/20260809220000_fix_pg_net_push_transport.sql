-- pg_net owns its request functions in the `net` schema even when the
-- extension itself is registered under `extensions`. The previous helper
-- called extensions.http_post(), caught the resulting undefined-function
-- error, and silently dropped friend/meet push delivery.

do $migration$
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise exception 'pg_net net.http_post(text,jsonb,jsonb,jsonb,integer) is missing';
  end if;
end
$migration$;

create or replace function public.send_push(
  user_id uuid,
  kind text,
  payload jsonb
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_url text := 'https://qtzjxquzyrwavhvqarvg.supabase.co/functions/v1/send-push';
  -- The anon key is a public client credential, already shipped in the app.
  v_anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF0emp4cXV6eXJ3YXZodnFhcnZnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5OTUxMjYsImV4cCI6MjA4ODU3MTEyNn0.adPonS8qEXvd0-tkWoKos9Cq2C8C7HEZL5iTht-FXAs';
begin
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key
    ),
    body := jsonb_build_object(
      'user_id', user_id,
      'kind', kind,
      'payload', payload
    )
  );
exception when others then
  raise warning 'send_push failed for kind=% user=%: %', kind, user_id, sqlerrm;
end;
$$;

revoke execute on function public.send_push(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.send_push(uuid, text, jsonb) to service_role;
