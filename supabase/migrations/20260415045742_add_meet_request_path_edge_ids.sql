ALTER TABLE public.meet_requests
  ADD COLUMN IF NOT EXISTS sender_path_edge_ids text[],
  ADD COLUMN IF NOT EXISTS receiver_path_edge_ids text[];

COMMENT ON COLUMN public.meet_requests.sender_path_edge_ids
  IS 'Ordered list of graph edge IDs forming the sender''s path to the meeting node, computed at solve time so the receiver can reconstruct it without re-solving.';
COMMENT ON COLUMN public.meet_requests.receiver_path_edge_ids
  IS 'Ordered list of graph edge IDs forming the receiver''s path to the meeting node. Same rationale as sender_path_edge_ids.';;
