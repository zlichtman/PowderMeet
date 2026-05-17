-- Server-authoritative resort_id on live_presence (see CLAUDE.md — Realtime
-- / live_presence invariants).
--
-- Problem
-- -------
-- Until now the client shipped `resort_id` directly on every `live_presence`
-- upsert. Any client could write a row claiming "I'm at vail" while sitting
-- at beaver-creek, which breaks:
--   • the resort-filtered presence read in `get_social_snapshot`
--   • the resort filter in `hydrateFromTable`
--   • every UX that assumes resort_id is geographically truthful
-- (e.g. "friends at the same mountain" list).
--
-- Fix
-- ----
-- Keep the column, but derive it server-side from (lat, lon) against a
-- `resorts_bbox` table seeded from `ResortCatalog.swift` — the same 159
-- entries the client draws from. A BEFORE INSERT / UPDATE trigger runs the
-- lookup and **overwrites** whatever the client sent. If no bbox matches
-- (e.g. user is off-mountain, driving between resorts) we fall back to the
-- client-supplied value rather than blocking the write, so ride-in/ride-out
-- liveness still works. The table has a primary key on `resort_id` so
-- upserts keep it in sync with the Swift catalog via re-running this file.
--
-- Trigger order note
-- ------------------
-- `live_presence_compute_trg` (20260417_live_presence.sql) already runs
-- BEFORE INSERT/UPDATE to compute `geohash6` + stamp `last_seen`. The new
-- trigger declared here is named `live_presence_aa_resolve_resort_trg` so
-- it fires **first** alphabetically — Postgres orders same-timing triggers
-- by name. `compute_trg` runs second and sees the resolved resort_id.
--
-- Idempotency
-- -----------
-- All DDL is `create or replace` / `create table if not exists`, and the
-- seed uses `on conflict (resort_id) do update` so re-running this file
-- after the Swift catalog changes picks up any bbox edits.

create table if not exists public.resorts_bbox (
  resort_id text primary key,
  name      text not null,
  min_lat   double precision not null,
  max_lat   double precision not null,
  min_lon   double precision not null,
  max_lon   double precision not null,
  updated_at timestamptz not null default now(),
  check (min_lat <= max_lat),
  check (min_lon <= max_lon)
);

-- Read-only to anyone. No RLS needed; catalog is public reference data.
grant select on public.resorts_bbox to anon, authenticated;

-- Spatial query index: (min_lat, max_lat, min_lon, max_lon) all participate
-- in the point-in-bbox predicate, so a plain composite on lat bounds is
-- typically enough given <200 rows. If this grows, switch to PostGIS GIST.
create index if not exists resorts_bbox_lat_idx
  on public.resorts_bbox (min_lat, max_lat);

create or replace function public.resolve_resort_id(
  p_lat double precision,
  p_lon double precision
) returns text
language sql
stable
security invoker
set search_path = public
as $$
  select resort_id
    from public.resorts_bbox
   where p_lat between min_lat and max_lat
     and p_lon between min_lon and max_lon
   order by
     -- Tie-break: prefer the smallest bbox (e.g. Aspen Highlands vs a larger
     -- overlapping region). Area ~= (Δlat * Δlon) — good enough for ranking.
     ((max_lat - min_lat) * (max_lon - min_lon)) asc
   limit 1
$$;

grant execute on function public.resolve_resort_id(double precision, double precision)
  to anon, authenticated;

-- BEFORE trigger: overwrite client-supplied resort_id with the server's
-- spatial resolution. Fall back to the client value when no bbox matches.
create or replace function public.live_presence_resolve_resort()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  resolved text;
begin
  resolved := public.resolve_resort_id(new.lat, new.lon);
  if resolved is not null then
    new.resort_id := resolved;
  end if;
  -- If resolved IS NULL we keep new.resort_id as the client sent it (or
  -- whatever existed on the old row for an update). `resort_id NOT NULL`
  -- still holds because the column constraint rejects a bare null.
  return new;
end;
$$;

drop trigger if exists live_presence_aa_resolve_resort_trg on public.live_presence;
create trigger live_presence_aa_resolve_resort_trg
  before insert or update of lat, lon, resort_id on public.live_presence
  for each row execute function public.live_presence_resolve_resort();

-- ─────────────────────────── Seed (159 rows) ───────────────────────────
-- Generated from `PowderMeet/Models/ResortCatalog.swift` via
-- `tools/` extraction. To refresh after catalog edits: re-run this file.

insert into public.resorts_bbox (resort_id, name, min_lat, max_lat, min_lon, max_lon) values
  ('vail', 'Vail', 39.575000, 39.665000, -106.430000, -106.310000),
  ('beaver-creek', 'Beaver Creek', 39.570000, 39.630000, -106.565000, -106.475000),
  ('breckenridge', 'Breckenridge', 39.440000, 39.520000, -106.120000, -106.020000),
  ('keystone', 'Keystone', 39.545000, 39.615000, -105.980000, -105.900000),
  ('crested-butte', 'Crested Butte', 38.840000, 38.900000, -106.995000, -106.925000),
  ('telluride', 'Telluride', 37.910000, 37.970000, -107.850000, -107.770000),
  ('park-city', 'Park City', 40.600000, 40.700000, -111.575000, -111.445000),
  ('heavenly', 'Heavenly', 38.890000, 38.970000, -119.965000, -119.875000),
  ('kirkwood', 'Kirkwood', 38.650000, 38.710000, -120.105000, -120.035000),
  ('stevens-pass', 'Stevens Pass', 47.725000, 47.775000, -121.120000, -121.060000),
  ('mt-bachelor', 'Mt. Bachelor', 43.940000, 44.020000, -121.740000, -121.640000),
  ('stowe', 'Stowe', 44.500000, 44.560000, -72.810000, -72.750000),
  ('okemo', 'Okemo', 43.375000, 43.425000, -72.750000, -72.690000),
  ('mount-snow', 'Mount Snow', 42.935000, 42.985000, -72.925000, -72.875000),
  ('attitash', 'Attitash Mountain', 44.055000, 44.105000, -71.255000, -71.205000),
  ('wildcat', 'Wildcat Mountain', 44.240000, 44.280000, -71.225000, -71.175000),
  ('crotched', 'Crotched Mountain', 43.040000, 43.080000, -71.895000, -71.845000),
  ('mount-sunapee', 'Mount Sunapee', 43.355000, 43.405000, -72.085000, -72.035000),
  ('hunter', 'Hunter Mountain', 42.175000, 42.225000, -74.240000, -74.180000),
  ('seven-springs', 'Seven Springs', 39.995000, 40.045000, -79.330000, -79.270000),
  ('laurel-mountain', 'Laurel Mountain', 39.980000, 40.020000, -79.245000, -79.195000),
  ('liberty', 'Liberty Mountain Resort', 39.740000, 39.780000, -77.405000, -77.355000),
  ('hidden-valley-pa', 'Hidden Valley (Pennsylvania)', 40.060000, 40.100000, -79.275000, -79.225000),
  ('jack-frost', 'Jack Frost', 41.060000, 41.100000, -75.700000, -75.660000),
  ('big-boulder', 'Big Boulder', 41.030000, 41.070000, -75.660000, -75.620000),
  ('roundtop', 'Roundtop Mountain Resort', 40.090000, 40.130000, -76.955000, -76.905000),
  ('whitetail', 'Whitetail Resort', 39.720000, 39.760000, -77.955000, -77.905000),
  ('afton-alps', 'Afton Alps', 44.840000, 44.880000, -92.815000, -92.765000),
  ('mt-brighton', 'Mt Brighton', 42.510000, 42.550000, -83.835000, -83.785000),
  ('wilmot', 'Wilmot', 42.490000, 42.530000, -88.205000, -88.155000),
  ('alpine-valley-ohio', 'Alpine Valley', 41.520000, 41.560000, -81.315000, -81.265000),
  ('boston-mills-brandywine', 'Boston Mills & Brandywine', 41.255000, 41.305000, -81.590000, -81.530000),
  ('mad-river-mountain', 'Mad River Mountain', 40.290000, 40.330000, -83.705000, -83.655000),
  ('hidden-valley-mo', 'Hidden Valley (Missouri)', 38.475000, 38.505000, -90.710000, -90.670000),
  ('snow-creek', 'Snow Creek', 39.380000, 39.420000, -94.885000, -94.835000),
  ('paoli-peaks', 'Paoli Peaks', 38.545000, 38.575000, -86.490000, -86.450000),
  ('whistler', 'Whistler Blackcomb', 50.030000, 50.150000, -123.020000, -122.880000),
  ('fernie', 'Fernie Alpine Resort', 49.470000, 49.530000, -115.125000, -115.055000),
  ('kicking-horse', 'Kicking Horse', 51.265000, 51.335000, -117.090000, -117.010000),
  ('kimberley', 'Kimberley Alpine Resort', 49.655000, 49.705000, -116.030000, -115.970000),
  ('grouse-mountain', 'Grouse Mountain', 49.350000, 49.390000, -123.105000, -123.055000),
  ('nakiska', 'Nakiska', 50.925000, 50.975000, -115.110000, -115.050000),
  ('norquay', 'Norquay', 51.200000, 51.240000, -115.625000, -115.575000),
  ('stoneham', 'Stoneham Mountain Resort', 47.005000, 47.055000, -71.420000, -71.360000),
  ('hakuba-goryu', 'Hakuba Goryu', 36.680000, 36.720000, 137.825000, 137.875000),
  ('hakuba-happo-one', 'Hakuba Happo-One', 36.675000, 36.725000, 137.805000, 137.855000),
  ('hakuba-iwatake', 'Hakuba Iwatake', 36.705000, 36.735000, 137.820000, 137.860000),
  ('hakuba-norikura', 'Hakuba Norikura Onsen', 36.715000, 36.745000, 137.810000, 137.850000),
  ('hakuba-sanosaka', 'Hakuba Sanosaka Snow Resort', 36.675000, 36.705000, 137.820000, 137.860000),
  ('hakuba47', 'Hakuba47 Winter Sports Park', 36.690000, 36.730000, 137.815000, 137.865000),
  ('jiigatake', 'Jiigatake', 36.695000, 36.725000, 137.840000, 137.880000),
  ('kashimayari', 'Kashimayari', 36.695000, 36.725000, 137.850000, 137.890000),
  ('tsugaike', 'Tsugaike Kogen', 36.760000, 36.800000, 137.860000, 137.900000),
  ('rusutsu', 'Rusutsu', 42.730000, 42.790000, 140.525000, 140.595000),
  ('furano', 'Furano', 43.315000, 43.365000, 142.340000, 142.400000),
  ('myoko-suginohara', 'Myoko Suginohara', 36.850000, 36.890000, 138.835000, 138.885000),
  ('nekoma', 'Nekoma Mountain', 37.700000, 37.740000, 139.935000, 139.985000),
  ('perisher', 'Perisher', -36.435000, -36.365000, 148.370000, 148.450000),
  ('falls-creek', 'Falls Creek', -36.895000, -36.845000, 147.250000, 147.310000),
  ('hotham', 'Hotham', -37.005000, -36.955000, 147.140000, 147.200000),
  ('mt-buller', 'Mt Buller', -37.175000, -37.125000, 146.410000, 146.470000),
  ('mona-yongpyong', 'Mona Yongpyong', 37.620000, 37.660000, 128.655000, 128.705000),
  ('andermatt', 'Andermatt-Sedrun-Disentis', 46.590000, 46.670000, 8.515000, 8.665000),
  ('crans-montana', 'Crans-Montana', 46.280000, 46.340000, 7.440000, 7.520000),
  ('arlberg', 'Arlberg', 47.090000, 47.170000, 10.185000, 10.335000),
  ('skicircus-saalbach', 'Skicircus Saalbach', 47.350000, 47.430000, 12.580000, 12.700000),
  ('kitzsteinhorn', 'Kitzsteinhorn', 47.165000, 47.215000, 12.650000, 12.710000),
  ('hintertuxer', 'Hintertuxer Gletscher', 47.025000, 47.075000, 11.635000, 11.705000),
  ('mayrhofen', 'Mayrhofen', 47.110000, 47.170000, 11.830000, 11.910000),
  ('silvretta-montafon', 'Silvretta Montafon', 46.950000, 47.010000, 9.940000, 10.020000),
  ('soelden', 'Sölden', 46.935000, 47.005000, 10.950000, 11.030000),
  ('les-3-vallees', 'Les 3 Vallées', 45.270000, 45.390000, 6.500000, 6.660000),
  ('skirama-dolomiti', 'Skirama Dolomiti', 46.180000, 46.280000, 10.800000, 10.940000),
  ('monterosa', 'Monterosa Ski', 45.840000, 45.900000, 7.810000, 7.890000),
  ('aspen-mountain', 'Aspen Mountain', 39.155000, 39.205000, -106.845000, -106.795000),
  ('aspen-highlands', 'Aspen Highlands', 39.155000, 39.205000, -106.885000, -106.835000),
  ('buttermilk', 'Buttermilk', 39.175000, 39.225000, -106.885000, -106.835000),
  ('snowmass', 'Snowmass', 39.175000, 39.245000, -106.990000, -106.910000),
  ('steamboat', 'Steamboat', 40.420000, 40.500000, -106.850000, -106.750000),
  ('winter-park', 'Winter Park', 39.845000, 39.915000, -105.810000, -105.730000),
  ('copper-mountain', 'Copper Mountain', 39.470000, 39.530000, -106.185000, -106.115000),
  ('arapahoe-basin', 'Arapahoe Basin', 39.620000, 39.660000, -105.890000, -105.850000),
  ('eldora', 'Eldora Mountain', 39.920000, 39.960000, -105.605000, -105.555000),
  ('deer-valley', 'Deer Valley', 40.585000, 40.655000, -111.520000, -111.440000),
  ('solitude', 'Solitude', 40.595000, 40.645000, -111.620000, -111.560000),
  ('alta', 'Alta', 40.570000, 40.610000, -111.665000, -111.615000),
  ('snowbird', 'Snowbird', 40.555000, 40.605000, -111.690000, -111.630000),
  ('brighton', 'Brighton', 40.580000, 40.620000, -111.605000, -111.555000),
  ('snowbasin', 'Snowbasin', 41.180000, 41.240000, -111.895000, -111.825000),
  ('northstar', 'Northstar', 39.250000, 39.310000, -120.155000, -120.085000),
  ('palisades-tahoe', 'Palisades Tahoe', 39.160000, 39.240000, -120.290000, -120.190000),
  ('sierra-at-tahoe', 'Sierra-at-Tahoe', 38.775000, 38.825000, -120.110000, -120.050000),
  ('mammoth', 'Mammoth Mountain', 37.600000, 37.680000, -119.075000, -118.985000),
  ('june-mountain', 'June Mountain', 37.745000, 37.795000, -119.110000, -119.050000),
  ('big-bear', 'Big Bear Mountain Resort', 34.215000, 34.265000, -116.905000, -116.835000),
  ('snow-valley', 'Snow Valley', 34.200000, 34.240000, -117.065000, -117.015000),
  ('sun-valley', 'Sun Valley', 43.650000, 43.710000, -114.375000, -114.305000),
  ('schweitzer', 'Schweitzer', 48.340000, 48.400000, -116.655000, -116.585000),
  ('big-sky', 'Big Sky', 45.230000, 45.330000, -111.450000, -111.330000),
  ('jackson-hole', 'Jackson Hole', 43.555000, 43.625000, -110.870000, -110.790000),
  ('crystal-mountain', 'Crystal Mountain', 46.900000, 46.960000, -121.515000, -121.445000),
  ('summit-at-snoqualmie', 'The Summit at Snoqualmie', 47.390000, 47.450000, -121.450000, -121.370000),
  ('alyeska', 'Alyeska', 60.940000, 61.000000, -149.135000, -149.065000),
  ('taos', 'Taos', 36.560000, 36.620000, -105.485000, -105.415000),
  ('killington', 'Killington', 43.590000, 43.670000, -72.850000, -72.750000),
  ('pico', 'Pico', 43.640000, 43.680000, -72.865000, -72.815000),
  ('stratton', 'Stratton', 43.085000, 43.135000, -72.940000, -72.880000),
  ('sugarbush', 'Sugarbush', 44.110000, 44.170000, -72.925000, -72.855000),
  ('loon', 'Loon Mountain', 44.015000, 44.065000, -71.650000, -71.590000),
  ('cranmore', 'Cranmore', 44.050000, 44.090000, -71.115000, -71.065000),
  ('sugarloaf', 'Sugarloaf', 44.995000, 45.065000, -70.350000, -70.270000),
  ('sunday-river', 'Sunday River', 44.435000, 44.505000, -70.900000, -70.820000),
  ('jiminy-peak', 'Jiminy Peak', 42.490000, 42.530000, -73.305000, -73.255000),
  ('butternut', 'Butternut', 42.160000, 42.200000, -73.335000, -73.285000),
  ('boyne-mountain', 'Boyne Mountain', 45.140000, 45.180000, -84.945000, -84.895000),
  ('the-highlands', 'The Highlands', 45.445000, 45.495000, -84.940000, -84.880000),
  ('buck-hill', 'Buck Hill', 44.705000, 44.735000, -93.300000, -93.260000),
  ('wild-mountain', 'Wild Mountain', 45.435000, 45.465000, -92.740000, -92.700000),
  ('camelback', 'Camelback Resort', 41.030000, 41.070000, -75.375000, -75.325000),
  ('blue-mountain-pa', 'Blue Mountain Resort', 40.790000, 40.830000, -75.545000, -75.495000),
  ('snowshoe', 'Snowshoe', 38.380000, 38.440000, -80.025000, -79.955000),
  ('banff-sunshine', 'Banff Sunshine', 51.075000, 51.145000, -115.800000, -115.720000),
  ('lake-louise', 'Lake Louise', 51.405000, 51.475000, -116.200000, -116.120000),
  ('revelstoke', 'Revelstoke', 50.920000, 51.000000, -118.205000, -118.115000),
  ('red-mountain', 'RED Mountain', 49.070000, 49.130000, -117.875000, -117.805000),
  ('cypress', 'Cypress Mountain', 49.375000, 49.425000, -123.230000, -123.170000),
  ('panorama', 'Panorama', 50.435000, 50.485000, -116.270000, -116.210000),
  ('sun-peaks', 'Sun Peaks Resort', 50.850000, 50.910000, -119.925000, -119.855000),
  ('silverstar', 'SilverStar Mountain Resort', 50.350000, 50.410000, -119.095000, -119.025000),
  ('blue-mountain-on', 'Blue Mountain', 44.475000, 44.525000, -80.335000, -80.285000),
  ('tremblant', 'Tremblant', 46.180000, 46.240000, -74.620000, -74.560000),
  ('le-massif', 'Le Massif de Charlevoix', 47.250000, 47.310000, -70.570000, -70.510000),
  ('mont-sainte-anne', 'Mont-Sainte Anne', 47.040000, 47.100000, -70.930000, -70.870000),
  ('niseko', 'Niseko United', 42.825000, 42.895000, 140.650000, 140.730000),
  ('hakuba-cortina', 'Hakuba Cortina', 36.770000, 36.810000, 137.845000, 137.895000),
  ('lotte-arai', 'Lotte Arai Resort', 36.910000, 36.950000, 138.155000, 138.205000),
  ('appi', 'APPI Resort', 39.905000, 39.955000, 140.970000, 141.030000),
  ('shiga-kogen', 'Shiga Kogen', 36.760000, 36.820000, 138.485000, 138.555000),
  ('mt-t', 'Mt. T', 36.660000, 36.700000, 139.525000, 139.575000),
  ('zao-onsen', 'Zao Onsen', 38.145000, 38.195000, 140.370000, 140.430000),
  ('thredbo', 'Thredbo', -36.525000, -36.475000, 148.270000, 148.330000),
  ('coronet-peak', 'Coronet Peak', -45.055000, -45.005000, 168.700000, 168.760000),
  ('the-remarkables', 'The Remarkables', -45.065000, -45.015000, 168.780000, 168.840000),
  ('mt-hutt', 'Mt Hutt', -43.505000, -43.455000, 171.510000, 171.570000),
  ('yunding', 'Yunding Snow Park', 40.950000, 40.990000, 115.425000, 115.475000),
  ('valle-nevado', 'Valle Nevado', -33.390000, -33.330000, -70.295000, -70.225000),
  ('verbier', 'Verbier 4 Vallées', 46.060000, 46.140000, 7.170000, 7.290000),
  ('st-moritz', 'St. Moritz', 46.470000, 46.530000, 9.800000, 9.880000),
  ('zermatt', 'Zermatt', 45.990000, 46.050000, 7.710000, 7.790000),
  ('ischgl', 'Ischgl', 46.970000, 47.030000, 10.250000, 10.330000),
  ('kitzbuehel', 'Kitzbühel', 47.420000, 47.480000, 12.350000, 12.430000),
  ('chamonix', 'Chamonix Mont-Blanc', 45.880000, 45.960000, 6.820000, 6.920000),
  ('megeve', 'Megève', 45.830000, 45.890000, 6.580000, 6.660000),
  ('dolomiti-superski', 'Dolomiti Superski', 46.460000, 46.580000, 11.690000, 11.850000),
  ('cervino', 'Cervino Ski Paradise', 45.900000, 45.960000, 7.590000, 7.670000),
  ('courmayeur', 'Courmayeur Mont Blanc', 45.760000, 45.820000, 6.915000, 6.985000),
  ('la-thuile', 'La Thuile - Espace San Bernardo', 45.695000, 45.745000, 6.915000, 6.985000),
  ('pila', 'Pila', 45.700000, 45.740000, 7.295000, 7.345000),
  ('grandvalira', 'Grandvalira', 42.520000, 42.580000, 1.630000, 1.730000)
on conflict (resort_id) do update
  set name    = excluded.name,
      min_lat = excluded.min_lat,
      max_lat = excluded.max_lat,
      min_lon = excluded.min_lon,
      max_lon = excluded.max_lon,
      updated_at = now();
