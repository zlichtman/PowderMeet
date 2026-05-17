-- Null the topsheet_asset_key for two slugs whose source product
-- photos are catalog-style multi-ski shots (4 vertical profiles each)
-- that the rembg + de-pair pipeline can't algorithmically separate
-- into a single ski. Without single-ski source photos, the rendered
-- topsheet shows 4 skis stacked, which reads as broken in the
-- picker preview. Setting the asset key to null falls through to
-- the neutral dark fallback pill — honest "no artwork" rather than
-- wrong artwork. Re-source as single-ski photos and re-import to
-- restore (run `tools/import_topsheets.py` after dropping new
-- raws into ~/topsheet-source/raw/).

update public.skis_catalog
   set topsheet_asset_key = null
 where (brand = 'Voile' and model = 'HyperVector BC')
    or (brand = 'Black Diamond' and model = 'Helio Carbon 95');
