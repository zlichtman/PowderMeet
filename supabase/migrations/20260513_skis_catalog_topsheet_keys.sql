-- Per-row asset key for the bundled topsheet PNG. Resolved at runtime
-- against `Assets.xcassets` (image set name == asset key). NULL means
-- no licensed image is bundled for this row yet — runtime falls back
-- to the procedural BrandStyle pattern.
alter table public.skis_catalog
  add column if not exists topsheet_asset_key text;

create index if not exists skis_catalog_topsheet_idx
  on public.skis_catalog (topsheet_asset_key)
  where topsheet_asset_key is not null;
