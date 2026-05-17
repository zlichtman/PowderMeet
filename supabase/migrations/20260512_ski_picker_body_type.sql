-- Ski catalog: searchable list of brand/model entries shown in the
-- MY SKIS picker on the Activity → CALIBRATION tab. Brand-only would
-- be too coarse; model lets the future per-skier algorithm distinguish
-- "Atomic Bent 110" (powder) from "Atomic Redster" (carver) on the
-- same brand. waist_width_mm is captured for that algorithm pass — a
-- 110mm waist is a different terrain preference than a 75mm waist.
create table if not exists public.skis_catalog (
  id uuid primary key default gen_random_uuid(),
  brand text not null,
  model text not null,
  category text,                 -- 'all-mountain' | 'powder' | 'park' | 'race' | 'touring'
  waist_width_mm int,
  created_at timestamptz default now()
);

create index if not exists skis_catalog_search_idx
  on public.skis_catalog using gin (to_tsvector('english', brand || ' ' || model));
create index if not exists skis_catalog_brand_idx on public.skis_catalog (brand);

alter table public.skis_catalog enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'skis_catalog'
      and policyname = 'skis_catalog_authenticated_read'
  ) then
    create policy "skis_catalog_authenticated_read"
      on public.skis_catalog for select to authenticated using (true);
  end if;
end$$;

-- Profile additions: body metrics (HealthKit-prefilled, user-editable)
-- and chosen ski. preferred_ski_id is FK to catalog with on-delete-set-
-- null so catalog cleanup never orphans a profile row.
alter table public.profiles
  add column if not exists height_cm double precision,
  add column if not exists weight_kg double precision,
  add column if not exists preferred_ski_id uuid references public.skis_catalog(id) on delete set null;

-- Curated seed covering major brands and category spread. Picker
-- friction-free first launch depends on a non-empty catalog.
-- (A 'PowderMeet House' row was originally seeded here as an
-- explicit-default option; removed in 20260514 — house default is
-- the implicit NULL state and shouldn't appear as a pick.)
insert into public.skis_catalog (brand, model, category, waist_width_mm) values
  ('Atomic',      'Bent 110',          'powder',       110),
  ('Atomic',      'Bent 100',          'all-mountain', 100),
  ('Atomic',      'Bent 90',           'all-mountain',  90),
  ('Atomic',      'Maverick 95 Ti',    'all-mountain',  95),
  ('Atomic',      'Redster G9 RVSK S', 'race',          68),
  ('Black Crows', 'Atris',             'powder',       108),
  ('Black Crows', 'Camox',             'all-mountain',  97),
  ('Black Crows', 'Daemon',            'all-mountain', 100),
  ('Black Crows', 'Anima',             'powder',       115),
  ('Faction',     'Prodigy 3',         'all-mountain', 100),
  ('Faction',     'Mana 4',            'powder',       112),
  ('Faction',     'Dancer 3',          'all-mountain',  96),
  ('Rossignol',   'Soul 7 HD',         'powder',       106),
  ('Rossignol',   'Sender 104 Ti',     'all-mountain', 104),
  ('Rossignol',   'Experience 86 Ti',  'all-mountain',  86),
  ('Rossignol',   'Black Ops Sender',  'all-mountain', 102),
  ('K2',          'Mindbender 99Ti',   'all-mountain',  99),
  ('K2',          'Mindbender 108Ti',  'powder',       108),
  ('K2',          'Disruption 82Ti',   'all-mountain',  82),
  ('Salomon',     'QST 106',           'powder',       106),
  ('Salomon',     'QST 98',            'all-mountain',  98),
  ('Salomon',     'Stance 96',         'all-mountain',  96),
  ('Salomon',     'S/Force Bold',      'all-mountain',  82),
  ('Volkl',       'M6 Mantra',         'all-mountain',  96),
  ('Volkl',       'Blaze 106',         'powder',       106),
  ('Volkl',       'Kendo 88',          'all-mountain',  88),
  ('Volkl',       'Revolt 95',         'park',          95),
  ('Nordica',     'Enforcer 100',      'all-mountain', 100),
  ('Nordica',     'Enforcer 110',      'powder',       110),
  ('Nordica',     'Santa Ana 98',      'all-mountain',  98),
  ('Head',        'Kore 99',           'all-mountain',  99),
  ('Head',        'Kore 105',          'powder',       105),
  ('Head',        'Supershape e-Magnum','all-mountain', 76),
  ('Blizzard',    'Bonafide 97',       'all-mountain',  97),
  ('Blizzard',    'Rustler 10',        'all-mountain', 102),
  ('Blizzard',    'Hustle 10',         'all-mountain', 102),
  ('Blizzard',    'Black Pearl 88',    'all-mountain',  88),
  ('DPS',         'Pagoda 100 RP',     'all-mountain', 100),
  ('DPS',         'Pagoda Tour 112',   'touring',      112),
  ('DPS',         'Wailer A112',       'powder',       112),
  ('Armada',      'ARV 100',           'park',         100),
  ('Armada',      'ARV 116 JJ',        'powder',       116),
  ('Armada',      'Declivity 102 Ti',  'all-mountain', 102),
  ('Line',        'Sakana',            'all-mountain', 105),
  ('Line',        'Blade Optic 96',    'all-mountain',  96),
  ('Line',        'Pandora 99',        'all-mountain',  99),
  ('Stockli',     'Stormrider 102',    'all-mountain', 102),
  ('Stockli',     'Stormrider 88',     'all-mountain',  88),
  ('Stockli',     'Laser AX',          'all-mountain',  78),
  ('ON3P',        'Wrenegade 108',     'all-mountain', 108),
  ('ON3P',        'Woodsman 108',      'powder',       108),
  ('Dynastar',    'M-Pro 99',          'all-mountain',  99),
  ('Dynastar',    'M-Free 108',        'powder',       108),
  ('Fischer',     'Ranger 102',        'all-mountain', 102),
  ('Fischer',     'RC4',                'race',         68),
  ('Elan',        'Ripstick 96',       'all-mountain',  96),
  ('Elan',        'Ripstick 106',      'powder',       106),
  ('Moment',      'Wildcat',           'powder',       116),
  ('Moment',      'Deathwish',         'all-mountain', 112),
  ('J Skis',      'Masterblaster',     'all-mountain',  98),
  ('J Skis',      'Friend',            'all-mountain', 100),
  ('Icelantic',   'Nomad 105',         'all-mountain', 105),
  ('Icelantic',   'Pioneer 109',       'powder',       109),
  ('Voile',       'HyperVector BC',    'touring',      103),
  ('Black Diamond','Helio Carbon 95',  'touring',       95)
on conflict do nothing;
