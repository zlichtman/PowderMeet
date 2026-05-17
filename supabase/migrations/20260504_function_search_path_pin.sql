-- Silence the function_search_path_mutable advisor by pinning
-- search_path to public on the two trigger functions that flagged.
-- Both are non-SECURITY-DEFINER status-transition guards
-- (`enforce_meet_request_status_transition`,
-- `enforce_friendship_status_transition`); pinning the search path
-- makes them deterministic regardless of caller config and prevents
-- a future schema-shadowing attack.
alter function public.enforce_meet_request_status_transition() set search_path = public;
alter function public.enforce_friendship_status_transition() set search_path = public;
