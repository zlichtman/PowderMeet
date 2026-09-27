
-- Table to track shared graph snapshots per resort per day
CREATE TABLE resort_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  resort_id TEXT NOT NULL,
  snapshot_date DATE NOT NULL DEFAULT CURRENT_DATE,
  osm_storage_path TEXT NOT NULL,
  elevation_storage_path TEXT NOT NULL,
  truth_version TEXT,
  curated_version TEXT,
  node_count INT,
  edge_count INT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(resort_id, snapshot_date)
);

-- RLS: anyone authenticated can read snapshots
ALTER TABLE resort_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated_read_snapshots" ON resort_snapshots
  FOR SELECT TO authenticated USING (true);

-- Service role can insert/update (edge function uses service role)
CREATE POLICY "service_insert_snapshots" ON resort_snapshots
  FOR INSERT TO service_role WITH CHECK (true);
CREATE POLICY "service_update_snapshots" ON resort_snapshots
  FOR UPDATE TO service_role USING (true);

-- Add graph_snapshot_date to meet_requests for cross-device graph sync
ALTER TABLE meet_requests ADD COLUMN IF NOT EXISTS graph_snapshot_date DATE;

-- Index for fast lookups
CREATE INDEX idx_resort_snapshots_resort_date ON resort_snapshots(resort_id, snapshot_date DESC);

-- Storage bucket for resort graph snapshots (created via API, not SQL)
-- Will be created in the edge function setup
INSERT INTO storage.buckets (id, name, public)
VALUES ('resort-graphs', 'resort-graphs', true)
ON CONFLICT (id) DO NOTHING;
;
