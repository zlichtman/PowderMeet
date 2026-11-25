-- 0020 Resort search by other names, and clearing presence (specs/04-SCHEMA.md
-- sections 2, 3 and 6).
--
-- Additive. `resorts.aliases` holds the other names a resort is searched by
-- ("St. Anton" for Arlberg, "Snow Summit" for Big Bear). The pipeline writes
-- it on publish from `pipeline/resorts.yaml`; the rows here seed it for every resort, published or not, since an unpublished
-- resort never passes through publish. `resort_catalog` gains the column, last,
-- so the view can be replaced in place.
--
-- `presence_clear()` deletes the caller's own presence row: on sign-out, on
-- leaving a resort and, best-effort, when the app is terminated. Friends then
-- stop receiving the row from `presence_snapshot` and `social_snapshot`'s
-- `last_seen` at once; a dot already on their map ages out on its own (live
-- 75 s, then stale), since a delete sends no event. Owner only, not
-- rate-limited: it touches one row of the caller's and nothing else.

-- ------------------------------------------------------------------ aliases

alter table public.resorts
  add column aliases text[] not null default '{}';

update public.resorts r
set aliases = v.aliases
from (values
  ('alyeska', array['Alyeska Resort']),
  ('arlberg', array['Ski Arlberg', 'St. Anton']),
  ('big-bear', array['Bear Mountain', 'Snow Summit']),
  ('butternut', array['Ski Butternut']),
  ('cervino', array['Breuil-Cervinia']),
  ('cranmore', array['Cranmore Mountain Resort']),
  ('furano', array['Furano Ski Resort']),
  ('hintertuxer', array['Hintertux Glacier']),
  ('ischgl', array['Silvretta Arena']),
  ('jiigatake', array['Jigatake Snow Resort']),
  ('kashimayari', array['Kashimayari Snow Resort']),
  ('kitzsteinhorn', array['Zell am See-Kaprun']),
  ('les-3-vallees', array['Courchevel', 'Méribel', 'Val Thorens']),
  ('mt-bachelor', array['Mount Bachelor']),
  ('myoko-suginohara', array['Myoko Suginohara Ski Resort']),
  ('nekoma', array['NEKOMA']),
  ('pico', array['Pico Mountain']),
  ('rusutsu', array['Rusutsu Resort']),
  ('skicircus-saalbach', array['Saalbach Hinterglemm']),
  ('skirama-dolomiti', array['Madonna di Campiglio']),
  ('sun-valley', array['Bald Mountain', 'Dollar Mountain']),
  ('taos', array['Taos Ski Valley']),
  ('the-highlands', array['Boyne Highlands']),
  ('tsugaike', array['Tsugaike Mountain Resort'])
) as v(id, aliases)
where r.id = v.id;

-- Same view as 0012 with `aliases` appended. It still runs with its owner's
-- rights (the one read that must see unpublished rows) and carries catalog
-- metadata only.
create or replace view public.resort_catalog with (security_invoker = false) as
  select r.id, r.name, r.timezone, r.bbox, r.center, r.camera, r.pass_products,
         r.status_provider, r.status_mode, r.review_minutes, r.region, r.country,
         ab.bundle_id, ab.published_at, b.built_at, r.aliases
  from public.resorts r
  left join public.resort_active_bundle ab on ab.resort_id = r.id and r.published
  left join public.resort_bundles b on b.bundle_id = ab.bundle_id;

revoke all on public.resort_catalog from anon, authenticated;
grant select on public.resort_catalog to anon, authenticated;

-- ----------------------------------------------------------- presence_clear

create function public.presence_clear()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
begin
  delete from presence pr where pr.user_id = v_me;
end;
$$;

revoke execute on function public.presence_clear() from public, anon, authenticated;
grant execute on function public.presence_clear() to service_role;
grant execute on function public.presence_clear() to authenticated;
