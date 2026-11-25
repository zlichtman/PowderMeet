-- The gear editor lets the skier pick a real ski from the app's bundled catalog
-- and choose how the pair is drawn. Both are display only: routing still reads
-- discipline, type, length_cm and waist_mm.
--   ski:  a catalog key such as 'atomic-bent-110'. The catalog ships in the app,
--         so the server checks the shape, not the key. Skis only.
--   skin: 'house' or a drawn pattern. Absent means the ski's own topsheet.
-- `profile_update` stores the equipment object whole and lets this check judge
-- it, so the function itself does not change. Null still means "not set".
alter table public.profiles drop constraint profiles_equipment_check;
alter table public.profiles add constraint profiles_equipment_check check (
  equipment is null or (
    jsonb_typeof(equipment) = 'object'
    and equipment - array['discipline', 'type', 'length_cm', 'waist_mm', 'ski', 'skin'] = '{}'::jsonb
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
    and case
      when not equipment ? 'ski' then true
      when equipment ->> 'discipline' = 'ski' and jsonb_typeof(equipment -> 'ski') = 'string'
        then equipment ->> 'ski' ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(equipment ->> 'ski') <= 64
      else false
    end
    and case
      when not equipment ? 'skin' then true
      when jsonb_typeof(equipment -> 'skin') = 'string'
        then equipment ->> 'skin' in ('house', 'solid', 'stripes', 'split', 'bands', 'fade', 'tip', 'tricolor')
      else false
    end
  )
);
