-- Replace the avatar storage policies with a complete CRUD set.
-- Adds DELETE (so upsert can replace existing files) and an explicit
-- public-read policy. Keeps INSERT/UPDATE gated to the user's own folder.

drop policy if exists "Users can upload own avatar" on storage.objects;
drop policy if exists "Users can update own avatar" on storage.objects;
drop policy if exists "Users can delete own avatar" on storage.objects;
drop policy if exists "Anyone can read avatars"     on storage.objects;

create policy "Anyone can read avatars"
  on storage.objects for select
  using (bucket_id = 'avatars');

create policy "Users can upload own avatar"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

create policy "Users can update own avatar"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and (storage.foldername(name))[1] = (auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

create policy "Users can delete own avatar"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and (storage.foldername(name))[1] = (auth.uid())::text
  );;
