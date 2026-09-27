do $$
declare
    rec record;
begin
    for rec in
        select pol.polname as polname
        from pg_policy pol
        join pg_class cls on cls.oid = pol.polrelid
        join pg_namespace nsp on nsp.oid = cls.relnamespace
        where nsp.nspname = 'storage'
          and cls.relname = 'objects'
          and (
                pg_get_expr(pol.polqual, pol.polrelid) ilike '%avatars%'
             or pg_get_expr(pol.polwithcheck, pol.polrelid) ilike '%avatars%'
             or pol.polname ilike '%avatar%'
          )
    loop
        execute format('drop policy if exists %I on storage.objects', rec.polname);
    end loop;
end $$;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = excluded.public;

create policy "avatars_insert_own_folder"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_update_own_folder"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_delete_own_folder"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_select_public"
  on storage.objects
  for select
  to public
  using (bucket_id = 'avatars');;
