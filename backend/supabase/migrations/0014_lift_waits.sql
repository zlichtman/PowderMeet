-- 0014: live lift waits on resort_status (specs/02-DOMAIN.md section 3).
--
-- Additive: existing rows get an empty object, which the solver reads as "no
-- live wait known" and prices every lift as before. The status worker writes
-- the minutes its provider reports for lifts that are open or on hold.

alter table public.resort_status
  add column wait_minutes jsonb not null default '{}'::jsonb
    check (jsonb_typeof(wait_minutes) = 'object');

-- The view's `s.*` was expanded when it was created, so it is replaced to carry
-- the new column (appended last, which `create or replace view` allows). Its
-- grants and security_invoker setting are kept.
create or replace view public.resort_status_current with (security_invoker = true) as
  select distinct on (s.resort_id) s.*
  from public.resort_status s
  order by s.resort_id, s.observed_at desc, s.id desc;
