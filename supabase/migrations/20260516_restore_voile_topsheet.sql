-- Voile HyperVector BC's topsheet has been re-sourced (skimo.co
-- master photo pre-cropped to topsheet pair, then run through the
-- normal pipeline). Restore the asset key so the picker no longer
-- falls back to the dark pill for this row.
update public.skis_catalog
   set topsheet_asset_key = 'voile-hypervector-bc'
 where brand = 'Voile' and model = 'HyperVector BC';
