update public.skis_catalog
   set topsheet_asset_key = null
 where (brand = 'Voile' and model = 'HyperVector BC')
    or (brand = 'Black Diamond' and model = 'Helio Carbon 95');
;
