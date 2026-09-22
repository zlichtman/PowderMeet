-- Phase 1.2 — Cache auth.uid() in RLS policies.
-- Replacing auth.uid() with (select auth.uid()) so Postgres caches the call per query
-- instead of re-evaluating it per row. 5-10x faster RLS on large result sets.

-- friendships
DROP POLICY IF EXISTS "Users can accept friend requests" ON public.friendships;
CREATE POLICY "Users can accept friend requests"
  ON public.friendships
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = addressee_id);

DROP POLICY IF EXISTS "Users can delete own friendships" ON public.friendships;
CREATE POLICY "Users can delete own friendships"
  ON public.friendships
  FOR DELETE
  TO authenticated
  USING ((select auth.uid()) IN (requester_id, addressee_id));

DROP POLICY IF EXISTS "Users can insert friendships" ON public.friendships;
CREATE POLICY "Users can insert friendships"
  ON public.friendships
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = requester_id);

DROP POLICY IF EXISTS "Users can view own friendships" ON public.friendships;
CREATE POLICY "Users can view own friendships"
  ON public.friendships
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) IN (requester_id, addressee_id));

-- meet_requests
DROP POLICY IF EXISTS "Users can read own meet requests" ON public.meet_requests;
CREATE POLICY "Users can read own meet requests"
  ON public.meet_requests
  FOR SELECT
  TO public
  USING ((select auth.uid()) IN (sender_id, receiver_id));

DROP POLICY IF EXISTS "Users can respond to meet requests" ON public.meet_requests;
CREATE POLICY "Users can respond to meet requests"
  ON public.meet_requests
  FOR UPDATE
  TO public
  USING ((select auth.uid()) = receiver_id);

DROP POLICY IF EXISTS "Users can send meet requests" ON public.meet_requests;
CREATE POLICY "Users can send meet requests"
  ON public.meet_requests
  FOR INSERT
  TO public
  WITH CHECK ((select auth.uid()) = sender_id);

-- profiles
DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile"
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile"
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = id);;
