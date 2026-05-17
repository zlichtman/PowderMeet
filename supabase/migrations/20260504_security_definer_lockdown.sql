-- Revoke client EXECUTE on SECURITY DEFINER functions that should
-- only run via triggers or pg_cron — closes the advisor warning
-- "callable by anon / authenticated" without changing functional
-- behavior. Triggers fire via the event system (no client EXECUTE
-- needed); pg_cron jobs run as their owner. service_role retains
-- EXECUTE for server-side use.
--
-- Functions deliberately KEPT public-callable (genuine RPCs):
--   - delete_user_account()                — authenticated
--   - find_users_by_emails(text[])         — authenticated
--   - find_users_by_phones(text[])         — authenticated
--   - is_display_name_taken(text)          — anon + authenticated
--                                            (called pre-signup)
--   - recompute_profile_edge_speeds(uuid)  — authenticated
--   - recompute_profile_stats(uuid)        — authenticated
--   - send_friend_request(uuid)            — authenticated

-- Triggers on auth.users / friendships / meet_requests / live_presence:
revoke execute on function public.handle_new_user()                      from public, anon, authenticated;
revoke execute on function public.notify_friend_accepted()               from public, anon, authenticated;
revoke execute on function public.notify_friend_request_insert()         from public, anon, authenticated;
revoke execute on function public.notify_meet_accepted()                 from public, anon, authenticated;
revoke execute on function public.notify_meet_request_insert()           from public, anon, authenticated;
revoke execute on function public.live_presence_resolve_resort()         from public, anon, authenticated;
revoke execute on function public.rls_auto_enable()                      from public, anon, authenticated;

-- Internal helpers + cron jobs:
revoke execute on function public.send_push(uuid, text, jsonb)           from public, anon, authenticated;
revoke execute on function public.live_presence_compute()                from public, anon, authenticated;
revoke execute on function public.live_presence_cleanup()                from public, anon, authenticated;
revoke execute on function public.expire_stale_meet_requests()           from public, anon, authenticated;
