-- Restore topsheet_asset_key for 33 slugs whose artwork was just
-- sourced + processed:
--   * 3 of the 4 previously-nulled slugs (Atomic Bent 90, Atomic
--     Maverick 95 Ti, Black Diamond Helio Carbon 95). Voile
--     HyperVector BC stays null — its raw is still a multi-ski
--     catalog photo the de-pair pipeline can't isolate; needs a
--     proper single-ski photo re-source.
--   * 30 newly-added catalog variants (20260515_ski_catalog_
--     variants_pass) that shipped with null asset keys.

update public.skis_catalog set topsheet_asset_key = 'black-diamond-helio-carbon-95' where brand = 'Black Diamond' and model = 'Helio Carbon 95';
update public.skis_catalog set topsheet_asset_key = 'atomic-bent-90'                 where brand = 'Atomic'        and model = 'Bent 90';
update public.skis_catalog set topsheet_asset_key = 'atomic-maverick-95-ti'          where brand = 'Atomic'        and model = 'Maverick 95 Ti';
update public.skis_catalog set topsheet_asset_key = 'atomic-bent-85'                 where brand = 'Atomic'        and model = 'Bent 85';
update public.skis_catalog set topsheet_asset_key = 'atomic-bent-120'                where brand = 'Atomic'        and model = 'Bent 120';
update public.skis_catalog set topsheet_asset_key = 'atomic-maverick-88-ti'          where brand = 'Atomic'        and model = 'Maverick 88 Ti';
update public.skis_catalog set topsheet_asset_key = 'atomic-maverick-100-ti'         where brand = 'Atomic'        and model = 'Maverick 100 Ti';
update public.skis_catalog set topsheet_asset_key = 'salomon-qst-92'                 where brand = 'Salomon'       and model = 'QST 92';
update public.skis_catalog set topsheet_asset_key = 'salomon-qst-99'                 where brand = 'Salomon'       and model = 'QST 99';
update public.skis_catalog set topsheet_asset_key = 'salomon-stance-102'             where brand = 'Salomon'       and model = 'Stance 102';
update public.skis_catalog set topsheet_asset_key = 'rossignol-sender-94-ti'         where brand = 'Rossignol'     and model = 'Sender 94 Ti';
update public.skis_catalog set topsheet_asset_key = 'rossignol-sender-90-pro'        where brand = 'Rossignol'     and model = 'Sender 90 Pro';
update public.skis_catalog set topsheet_asset_key = 'rossignol-experience-82-basalt' where brand = 'Rossignol'     and model = 'Experience 82 Basalt';
update public.skis_catalog set topsheet_asset_key = 'k2-mindbender-89ti'             where brand = 'K2'            and model = 'Mindbender 89Ti';
update public.skis_catalog set topsheet_asset_key = 'k2-mindbender-96c'              where brand = 'K2'            and model = 'Mindbender 96C';
update public.skis_catalog set topsheet_asset_key = 'volkl-blaze-94'                 where brand = 'Volkl'         and model = 'Blaze 94';
update public.skis_catalog set topsheet_asset_key = 'nordica-enforcer-94'            where brand = 'Nordica'       and model = 'Enforcer 94';
update public.skis_catalog set topsheet_asset_key = 'nordica-enforcer-104'           where brand = 'Nordica'       and model = 'Enforcer 104';
update public.skis_catalog set topsheet_asset_key = 'nordica-santa-ana-93'           where brand = 'Nordica'       and model = 'Santa Ana 93';
update public.skis_catalog set topsheet_asset_key = 'head-kore-93'                   where brand = 'Head'          and model = 'Kore 93';
update public.skis_catalog set topsheet_asset_key = 'head-kore-87'                   where brand = 'Head'          and model = 'Kore 87';
update public.skis_catalog set topsheet_asset_key = 'blizzard-rustler-9'             where brand = 'Blizzard'      and model = 'Rustler 9';
update public.skis_catalog set topsheet_asset_key = 'blizzard-hustle-9'              where brand = 'Blizzard'      and model = 'Hustle 9';
update public.skis_catalog set topsheet_asset_key = 'blizzard-black-pearl-97'        where brand = 'Blizzard'      and model = 'Black Pearl 97';
update public.skis_catalog set topsheet_asset_key = 'armada-arv-94'                  where brand = 'Armada'        and model = 'ARV 94';
update public.skis_catalog set topsheet_asset_key = 'armada-arv-88'                  where brand = 'Armada'        and model = 'ARV 88';
update public.skis_catalog set topsheet_asset_key = 'faction-prodigy-2'              where brand = 'Faction'       and model = 'Prodigy 2';
update public.skis_catalog set topsheet_asset_key = 'faction-prodigy-4'              where brand = 'Faction'       and model = 'Prodigy 4';
update public.skis_catalog set topsheet_asset_key = 'faction-dancer-2'               where brand = 'Faction'       and model = 'Dancer 2';
update public.skis_catalog set topsheet_asset_key = 'elan-ripstick-88'               where brand = 'Elan'          and model = 'Ripstick 88';
update public.skis_catalog set topsheet_asset_key = 'line-pandora-94'                where brand = 'Line'          and model = 'Pandora 94';
update public.skis_catalog set topsheet_asset_key = 'fischer-ranger-96'              where brand = 'Fischer'       and model = 'Ranger 96';
update public.skis_catalog set topsheet_asset_key = 'dynastar-m-free-99'             where brand = 'Dynastar'      and model = 'M-Free 99';
