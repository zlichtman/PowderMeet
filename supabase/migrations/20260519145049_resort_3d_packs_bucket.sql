insert into storage.buckets (id, name, public, file_size_limit)
values ('resort-3d-packs', 'resort-3d-packs', false, 209715200)
on conflict (id) do nothing;
;
