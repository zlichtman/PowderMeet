-- Restore the selectable house ski using the existing bundled topsheet.
-- Leave equipment dimensions unspecified rather than inventing performance data.
insert into public.skis_catalog (brand, model, category, waist_width_mm, topsheet_asset_key)
select 'PowderMeet', 'House', null, null, 'powdermeet-default'
where not exists (select 1 from public.skis_catalog where brand = 'PowderMeet' and model = 'House');

update public.skis_catalog
set topsheet_asset_key = 'powdermeet-default'
where brand = 'PowderMeet' and model = 'House';
