update public.skis_catalog
   set topsheet_asset_key = null
 where (brand = 'Atomic' and model = 'Bent 90')
    or (brand = 'Atomic' and model = 'Maverick 95 Ti');
;
