update public.profiles
   set preferred_ski_id = null
 where preferred_ski_id in (
   select id
     from public.skis_catalog
    where brand = 'PowderMeet'
      and model = 'House'
 );

delete from public.skis_catalog
 where brand = 'PowderMeet'
   and model = 'House';
;
