-- ============================================================================
-- Per-item run dates on signage playlists
-- ============================================================================
-- OptiSigns playlist items cannot carry dates (PlaylistItemInput is duration,
-- speed and transition only — verified against the live schema), so the dates
-- live here and a sweep enforces them: items are removed from the live
-- playlist when their window ends and added back when it starts. The sweep
-- runs whenever the Signage page loads, immediately after any date edit, and
-- daily by cron for the weeks nobody opens the app.
--
-- state: 'active'  — item is (or should be) in the playlist right now
--        'pending' — outside its window; the sweep took it out and will put
--                    it back on the start date
-- Rows delete themselves when the window is fully over, or when someone
-- removes the item from the playlist by hand (a hand edit wins).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.signage_item_dates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id    TEXT,                    -- NULL = the main OptiSigns account
  playlist_id TEXT NOT NULL,           -- OptiSigns playlist _id
  asset_id    TEXT NOT NULL,           -- OptiSigns asset _id
  filename    TEXT,                    -- shown while the item is off the list
  starts_on   DATE,                    -- NULL = already running
  ends_on     DATE,                    -- NULL = never expires
  state       TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','pending')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (playlist_id, asset_id),
  CHECK (starts_on IS NULL OR ends_on IS NULL OR ends_on >= starts_on)
);

-- Written and read only by the edge function with the service role; the
-- signage console is admin-gated there.
ALTER TABLE public.signage_item_dates ENABLE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';
