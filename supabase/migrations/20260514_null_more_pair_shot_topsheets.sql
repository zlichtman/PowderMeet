-- Two more slugs whose source product photos are unsuitable for the
-- pipeline:
--   - atomic-bent-90: source is a tip-only crop showing two skis from
--     mid-body up; pipeline produced a half-ski rendering ("cut weird")
--   - atomic-maverick-95-ti: horizontal pair-shot whose two skis
--     touch in alpha space after rembg, so de-pair picks the joined blob
-- Until single-ski photos are re-sourced, fall through to the dark
-- fallback pill rather than ship visibly broken artwork.

update public.skis_catalog
   set topsheet_asset_key = null
 where (brand = 'Atomic' and model = 'Bent 90')
    or (brand = 'Atomic' and model = 'Maverick 95 Ti');
