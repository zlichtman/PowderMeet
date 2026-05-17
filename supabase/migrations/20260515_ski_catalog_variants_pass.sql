-- Variants pass on skis_catalog: fill in commonly-owned widths in
-- brand lines we already carry. Picker today shows e.g. Salomon QST
-- 98 / 106 but a typical resort skier on QSTs is just as likely to
-- be on a 92 or 99 — that ski didn't appear in search and the user
-- ended up picking 'House' or the wrong width. This migration adds
-- the highest-volume retail widths per existing brand line. Topsheet
-- artwork is sourced separately; topsheet_asset_key is left null and
-- SkiPairView falls back to the dark pill.
insert into public.skis_catalog (brand, model, category, waist_width_mm) values
  ('Atomic',      'Bent 85',                'all-mountain',  85),
  ('Atomic',      'Bent 120',               'powder',       120),
  ('Atomic',      'Maverick 88 Ti',         'all-mountain',  88),
  ('Atomic',      'Maverick 100 Ti',        'all-mountain', 100),
  ('Salomon',     'QST 92',                 'all-mountain',  92),
  ('Salomon',     'QST 99',                 'all-mountain',  99),
  ('Salomon',     'Stance 102',             'all-mountain', 102),
  ('Rossignol',   'Sender 94 Ti',           'all-mountain',  94),
  ('Rossignol',   'Sender 90 Pro',          'all-mountain',  90),
  ('Rossignol',   'Experience 82 Basalt',   'all-mountain',  82),
  ('K2',          'Mindbender 89Ti',        'all-mountain',  89),
  ('K2',          'Mindbender 96C',         'all-mountain',  96),
  ('Volkl',       'Blaze 94',               'all-mountain',  94),
  ('Nordica',     'Enforcer 94',            'all-mountain',  94),
  ('Nordica',     'Enforcer 104',           'all-mountain', 104),
  ('Nordica',     'Santa Ana 93',           'all-mountain',  93),
  ('Head',        'Kore 93',                'all-mountain',  93),
  ('Head',        'Kore 87',                'all-mountain',  87),
  ('Blizzard',    'Rustler 9',              'all-mountain',  94),
  ('Blizzard',    'Hustle 9',               'all-mountain',  94),
  ('Blizzard',    'Black Pearl 97',         'all-mountain',  97),
  ('Armada',      'ARV 94',                 'park',          94),
  ('Armada',      'ARV 88',                 'all-mountain',  88),
  ('Faction',     'Prodigy 2',              'all-mountain',  96),
  ('Faction',     'Prodigy 4',              'powder',       110),
  ('Faction',     'Dancer 2',               'all-mountain',  90),
  ('Elan',        'Ripstick 88',            'all-mountain',  88),
  ('Line',        'Pandora 94',             'all-mountain',  94),
  ('Fischer',     'Ranger 96',              'all-mountain',  96),
  ('Dynastar',    'M-Free 99',              'all-mountain',  99)
on conflict do nothing;
