-- Reset avatar storage policies — defensive cleanup.
--
-- The first avatars-bucket migration (20260430_avatars_bucket_and_rls.sql)
-- assumed it could `DROP POLICY IF EXISTS` for four canonical names and
-- then `CREATE POLICY`. That works against a fresh project — but if the
-- bucket was first set up via Supabase Studio, Studio created policies
-- under its own auto-generated names ("Allow authenticated upload",
-- "Give anon users access to JPG images in folder 1234", etc.). Those
-- old policies still exist *alongside* ours after the first migration,
-- and any one of them with a stricter predicate (or a RESTRICTIVE
-- modifier) keeps blocking the upload — even though our PERMISSIVE
-- policy alone would allow it.
--
-- This migration walks every policy on `storage.objects` and drops any
-- that mention the `avatars` bucket in their definition, regardless of
-- name. Then it recreates the four canonical policies (same as the
-- original migration). End state: exactly four named policies for
-- INSERT/UPDATE/DELETE/SELECT on the avatars bucket, no surprise
-- holdovers.
--
-- Idempotent: re-running drops + recreates the same set.

-- Drop every existing storage.objects policy whose USING or WITH CHECK
-- references the avatars bucket. Studio-named, original-named, anything.
do $$
declare
    pol record;
begin
    for pol in
        select pol.polname
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
        execute format('drop policy if exists %I on storage.objects', pol.polname);
    end loop;
end $$;

-- Bucket — public read, idempotent.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = excluded.public;

-- Recreate the canonical four. Matches the original migration. Predicate:
-- each authenticated user owns the folder named after their auth.uid().
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

-- Public read so AsyncImage can fetch without a JWT — the `public` flag
-- on the bucket isn't enough; storage.objects RLS still applies to SELECT.
create policy "avatars_select_public"
  on storage.objects
  for select
  to public
  using (bucket_id = 'avatars');
