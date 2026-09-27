-- live_presence_user_idx duplicates live_presence_pkey (both unique btree on user_id).
-- The primary-key index already serves any user_id lookup; the secondary index
-- only burns write amplification on every upsert. Drop it.
drop index if exists public.live_presence_user_idx;;
