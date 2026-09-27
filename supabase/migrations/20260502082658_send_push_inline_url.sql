-- Hardcode the send-push edge function URL + anon key into send_push().
-- The DB-level GUC approach (alter database postgres set …) requires
-- superuser, which we don't have on managed Supabase. The anon key is
-- designed to ship publicly (it's in the iOS bundle already), so
-- embedding it in pg_proc is safe.

create or replace function public.send_push(
    user_id uuid,
    kind    text,
    payload jsonb
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_url text := 'https://qtzjxquzyrwavhvqarvg.supabase.co/functions/v1/send-push';
    v_anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF0emp4cXV6eXJ3YXZodnFhcnZnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5OTUxMjYsImV4cCI6MjA4ODU3MTEyNn0.adPonS8qEXvd0-tkWoKos9Cq2C8C7HEZL5iTht-FXAs';
begin
    perform extensions.http_post(
        url := v_url,
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_anon_key
        ),
        body := jsonb_build_object(
            'user_id', user_id,
            'kind',    kind,
            'payload', payload
        )
    );
exception when others then
    raise warning 'send_push failed for kind=% user=%: %', kind, user_id, sqlerrm;
end;
$$;;
