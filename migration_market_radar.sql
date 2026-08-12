-- ============================================================================
-- Market Radar
-- ============================================================================
-- A weekly scan of visible advertising and promotion activity by liquor
-- brands in our region (Okanagan / Shuswap) — across the public ad
-- transparency libraries (Meta, Google, TikTok) plus local news, events, and
-- public social posts. Not a spend tracker: creative visibility is a strong
-- signal, exact spend is not knowable from these sources. Each brand gets a
-- simple low/medium/high activity label and a one-line suggested response
-- for a manager to act on, or not — this is advisory only, nothing here
-- publishes or schedules anything by itself.
--
-- One report per scan (weekly, or run early by an admin), holding many
-- brand entries. Only admins ever see this — it's market intelligence, not
-- something store-level accounts need.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.market_radar_reports (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  region       TEXT NOT NULL DEFAULT 'Okanagan / Shuswap',
  status       TEXT NOT NULL DEFAULT 'complete' CHECK (status IN ('running','complete','failed')),
  error_msg    TEXT,
  reviewed_at  TIMESTAMPTZ,
  reviewed_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.market_radar_entries (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id         UUID NOT NULL REFERENCES public.market_radar_reports(id) ON DELETE CASCADE,
  brand             TEXT NOT NULL,
  category          TEXT NOT NULL,    -- beer, wine, whisky, rum, gin, vodka, tequila, RTD/cooler, cider, liqueur, other
  activity          TEXT NOT NULL CHECK (activity IN ('low','medium','high')),
  channels          TEXT[] NOT NULL DEFAULT '{}',   -- e.g. Meta Ads, Google Ads, TikTok, local news, restaurant posts
  summary           TEXT NOT NULL,
  suggested_action  TEXT,
  sources           JSONB NOT NULL DEFAULT '[]'     -- [{title, url}]
);

CREATE INDEX IF NOT EXISTS market_radar_reports_run_at_idx ON public.market_radar_reports (run_at DESC);
CREATE INDEX IF NOT EXISTS market_radar_entries_report_idx ON public.market_radar_entries (report_id);

ALTER TABLE public.market_radar_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_radar_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS market_radar_reports_admin ON public.market_radar_reports;
DROP POLICY IF EXISTS market_radar_entries_admin ON public.market_radar_entries;

-- Admin-only in both directions. The scan itself always runs through the
-- edge function's service-role client (either on the weekly cron, which has
-- no user session at all, or triggered by an admin's "Run scan now" click),
-- so this policy only ever gates direct reads/writes from the browser.
CREATE POLICY market_radar_reports_admin ON public.market_radar_reports
  FOR ALL TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY market_radar_entries_admin ON public.market_radar_entries
  FOR ALL TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT id, run_at, status, reviewed_at FROM public.market_radar_reports ORDER BY run_at DESC LIMIT 5;
-- SELECT brand, category, activity, channels, suggested_action FROM public.market_radar_entries
--   WHERE report_id = (SELECT id FROM public.market_radar_reports ORDER BY run_at DESC LIMIT 1);
