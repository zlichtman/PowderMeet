-- 0008 Resort catalog metadata. No bundles: a resort appears in the app only
-- after the pipeline publishes one and sets `published` (specs/05-PIPELINE.md).
-- The pipeline owns these rows from then on and may add more.

insert into public.resorts (id, name, timezone, bbox, center, camera, pass_products, status_provider, status_mode)
values
  ('whistler-blackcomb', 'Whistler Blackcomb', 'America/Vancouver',
   '[-123.02, 50.03, -122.88, 50.15]', '[-122.95, 50.09]',
   '{"bearing": 180, "pitch": 74, "zoom": 12.0, "center": [-122.95, 50.07]}',
   '{epic}', 'epic', 'live'),
  ('vail', 'Vail', 'America/Denver',
   '[-106.43, 39.575, -106.31, 39.665]', '[-106.37, 39.62]',
   '{"bearing": 0, "pitch": 62, "zoom": 12.5}', '{epic}', 'epic', 'live'),
  ('beaver-creek', 'Beaver Creek', 'America/Denver',
   '[-106.565, 39.57, -106.475, 39.63]', '[-106.52, 39.60]',
   '{"bearing": 350, "pitch": 62, "zoom": 13.0}', '{epic}', 'epic', 'live'),
  ('breckenridge', 'Breckenridge', 'America/Denver',
   '[-106.12, 39.44, -106.02, 39.52]', '[-106.07, 39.48]',
   '{"bearing": 5, "pitch": 62, "zoom": 12.8}', '{epic}', 'epic', 'live'),
  ('keystone', 'Keystone', 'America/Denver',
   '[-105.98, 39.545, -105.90, 39.615]', '[-105.94, 39.58]',
   '{"bearing": 0, "pitch": 62, "zoom": 13.0}', '{epic}', 'epic', 'live'),
  ('park-city', 'Park City', 'America/Denver',
   '[-111.575, 40.60, -111.445, 40.70]', '[-111.51, 40.65]',
   '{"bearing": 5, "pitch": 62, "zoom": 12.0}', '{epic}', 'epic', 'live'),
  ('heavenly', 'Heavenly', 'America/Los_Angeles',
   '[-119.965, 38.89, -119.875, 38.97]', '[-119.92, 38.93]',
   '{"bearing": 0, "pitch": 62, "zoom": 12.8}', '{epic}', 'epic', 'live'),
  ('stowe', 'Stowe', 'America/New_York',
   '[-72.81, 44.50, -72.75, 44.56]', '[-72.78, 44.53]',
   '{"bearing": 350, "pitch": 62, "zoom": 13.2}', '{epic}', 'epic', 'live')
on conflict (id) do nothing;

insert into public.app_config (key, value)
values ('min_app_build', '1')
on conflict (key) do nothing;
