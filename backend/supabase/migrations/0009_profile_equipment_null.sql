-- 0002's equipment check rejected a null value (its coalesce(..., false) terms
-- are false for null), so no profile without gear could be created, which is
-- every new sign-up. Null means "not set" and is allowed.
alter table public.profiles drop constraint profiles_equipment_check;
alter table public.profiles add constraint profiles_equipment_check check (
  equipment is null or (
    jsonb_typeof(equipment) = 'object'
    and equipment - array['discipline', 'type', 'length_cm', 'waist_mm'] = '{}'::jsonb
    and coalesce(equipment ->> 'discipline' in ('ski', 'snowboard'), false)
    and coalesce(equipment ->> 'type' in ('all_mountain', 'carving', 'freeride', 'park'), false)
    and case
      when not equipment ? 'length_cm' then true
      when jsonb_typeof(equipment -> 'length_cm') = 'number'
        then (equipment ->> 'length_cm')::numeric between 60 and 220
          and (equipment ->> 'length_cm')::numeric % 1 = 0
      else false
    end
    and case
      when not equipment ? 'waist_mm' then true
      when equipment ->> 'discipline' = 'ski' and jsonb_typeof(equipment -> 'waist_mm') = 'number'
        then (equipment ->> 'waist_mm')::numeric between 55 and 140
          and (equipment ->> 'waist_mm')::numeric % 1 = 0
      else false
    end
  )
);
