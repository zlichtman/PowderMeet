-- Remove the 'PowderMeet House' row from skis_catalog. House default
-- is the implicit fallback when profiles.preferred_ski_id is null —
-- it should not appear as a pickable option in the picker. Any user
-- who happened to pick this row gets their preferred_ski_id reset to
-- null first so the FK doesn't bite.

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
