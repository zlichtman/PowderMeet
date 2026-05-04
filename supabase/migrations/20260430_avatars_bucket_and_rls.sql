-- Avatars storage bucket + RLS.
--
-- Until now the bucket and its policies were hand-configured in Supabase
-- Studio, which lost the INSERT policy (or never had one with the right
-- predicate) — onboarding hit "new row violates row-level security policy"
-- on the very first avatar upload. This migration codifies the intended
-- shape so it survives project re-creation.
--
-- Policy: each authenticated user owns the folder named after their
-- auth.uid() inside the public `avatars` bucket. They can INSERT / UPDATE /
-- DELETE objects in their own folder; everyone (including anon) can SELECT.

-- 1. Bucket — public read, idempotent.
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

-- 2. Drop any pre-existing policies with these names so the migration is
--    re-runnable. Studio-created policies often use different names; if
--    yours do, drop them manually once via the dashboard.
DROP POLICY IF EXISTS "avatars_insert_own_folder" ON storage.objects;
DROP POLICY IF EXISTS "avatars_update_own_folder" ON storage.objects;
DROP POLICY IF EXISTS "avatars_delete_own_folder" ON storage.objects;
DROP POLICY IF EXISTS "avatars_select_public"     ON storage.objects;

-- 3. Per-action policies. `(storage.foldername(name))[1]` extracts the
--    first path segment — for `<uid>/avatar.jpg` that's `<uid>`. We compare
--    to `auth.uid()::text` (UUID rendered lowercase canonical) so the
--    Swift-side `userId.uuidString.lowercased()` matches.
CREATE POLICY "avatars_insert_own_folder"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "avatars_update_own_folder"
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "avatars_delete_own_folder"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Public read so AsyncImage can fetch without a JWT — bucket is `public`,
-- but storage.objects RLS still applies to SELECT regardless of bucket flag.
CREATE POLICY "avatars_select_public"
  ON storage.objects
  FOR SELECT
  TO public
  USING (bucket_id = 'avatars');
