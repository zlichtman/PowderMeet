-- Lock search_path for SECURITY DEFINER functions (prevents role-mutable search path attacks)
ALTER FUNCTION public.find_users_by_phones(text[]) SET search_path = public, auth;
ALTER FUNCTION public.delete_user_account() SET search_path = public, auth;
ALTER FUNCTION public.handle_new_user() SET search_path = public, auth;
ALTER FUNCTION public.update_updated_at() SET search_path = public;

-- Remove broad public SELECT on avatars bucket (app uses getPublicURL which
-- bypasses RLS; SELECT policy only enabled unwanted listing).
DROP POLICY IF EXISTS "Avatars are publicly readable" ON storage.objects;
;
