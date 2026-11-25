-- Conditions per route (06-SOLVER section 2): the height the forecast is for and
-- the last day's temperatures, so the phone can work out the weather at each
-- run's own height and whether the snow thawed and refroze. The per-hour
-- additions (wind direction, dew point, low cloud, temperatures aloft, snow
-- depth, 72-hour snow) are optional keys inside `current` and `hourly`.

alter table public.resort_conditions
  add column elevation_m real,
  add column recent jsonb not null default '[]'::jsonb;

-- `c.*` was expanded when the view was made; recreating it picks up the columns.
create or replace view public.resort_conditions_current with (security_invoker = true) as
  select distinct on (c.resort_id) c.*
  from public.resort_conditions c
  order by c.resort_id, c.observed_at desc, c.id desc;
