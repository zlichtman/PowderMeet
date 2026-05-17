-- Tighten the avatars bucket SELECT policy.
--
-- The previous `avatars_select_public` policy was role=`public` with
-- only `bucket_id = 'avatars'`, which let any anon caller LIST every
-- object in the bucket — enumerating user IDs. Public URL GETs are
-- handled by the storage CDN's bypass (the bucket has `public = true`),
-- so dropping the broad SELECT does NOT break avatar fetching.
--
-- New policy: only authenticated users can SELECT objects in their
-- own folder. Mirrors the INSERT/UPDATE/DELETE pattern already in
-- place (`avatars_insert_own_folder`, etc.). Anon LIST is now blocked.
drop policy if exists avatars_select_public on storage.objects;
drop policy if exists avatars_select_own_folder on storage.objects;
create policy avatars_select_own_folder on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );
