-- Phase 1.1 — Add missing indexes on foreign keys.
-- Supabase Performance Advisor flagged these as causing full table scans at scale.

CREATE INDEX IF NOT EXISTS idx_meet_requests_sender_status
  ON public.meet_requests (sender_id, status);

CREATE INDEX IF NOT EXISTS idx_meet_requests_receiver_status
  ON public.meet_requests (receiver_id, status);

CREATE INDEX IF NOT EXISTS idx_friendships_addressee_status
  ON public.friendships (addressee_id, status);

-- Phase 1.8 — Drop unused index flagged by advisor.
DROP INDEX IF EXISTS public.idx_resort_snapshots_resort_date;

COMMENT ON INDEX public.idx_meet_requests_sender_status
  IS 'Supports MeetRequestService.loadSent() by (sender_id, status="pending"). Prevents seq scan at 10k+ users.';
COMMENT ON INDEX public.idx_meet_requests_receiver_status
  IS 'Supports MeetRequestService.loadIncoming() by (receiver_id, status="pending"). Prevents seq scan at 10k+ users.';
COMMENT ON INDEX public.idx_friendships_addressee_status
  IS 'Supports FriendService pending-requests lookup by (addressee_id, status="pending").';;
