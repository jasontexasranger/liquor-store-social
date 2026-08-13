-- ============================================================================
-- Google Reviews
-- ============================================================================
-- Daily-synced Google rating + review count per store, plus each store's
-- most recent reviews — visible to everyone (not admin-gated), because the
-- point is a friendly leaderboard every manager sees, not a private report.
--
-- Source is the Places API (New), never scraping — scraping Google Maps
-- pages is against Google's terms and the markup shifts without warning.
-- The trade-off: Places API only exposes a store's 5 most recent reviews,
-- not full history. That's fine here — this isn't trying to replace the
-- one-time manual report, just keep a live rating/count leaderboard current.
--
-- store_review_snapshots is append-only (one row per store per sync) so a
-- "yesterday vs. today" trend arrow is possible later without a schema
-- change. store_review_recent is replace-on-sync — Google only ever gives
-- us the current top 5, so keeping old ones around would be misleading.
-- ============================================================================

-- Where to find each store on Google. Filled in once via the edge function's
-- setupPlaceIds action (admin only) — NULL until then, and sync simply
-- skips any store without one set.
ALTER TABLE public.meta_accounts
  ADD COLUMN IF NOT EXISTS google_place_id TEXT;

CREATE TABLE IF NOT EXISTS public.store_review_snapshots (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id      TEXT NOT NULL,
  rating        NUMERIC(2,1) NOT NULL,
  review_count  INTEGER NOT NULL,
  fetched_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS store_review_snapshots_store_time_idx
  ON public.store_review_snapshots (store_id, fetched_at DESC);

CREATE TABLE IF NOT EXISTS public.store_review_recent (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id       TEXT NOT NULL,
  author_name    TEXT,
  rating         INTEGER NOT NULL,
  relative_time  TEXT,               -- Google's own phrasing, e.g. "a month ago"
  review_time    BIGINT,             -- unix seconds, for sorting
  review_text    TEXT,
  fetched_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS store_review_recent_store_idx
  ON public.store_review_recent (store_id, review_time DESC);

ALTER TABLE public.store_review_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_review_recent    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_review_snapshots_read ON public.store_review_snapshots;
DROP POLICY IF EXISTS store_review_recent_read    ON public.store_review_recent;

-- Read-only to every signed-in user, on purpose — this is a shared
-- leaderboard, not store-scoped data. All writes go through the edge
-- function's service-role client (daily cron or an admin's "Sync now"),
-- so there is deliberately no INSERT/UPDATE/DELETE policy here at all.
CREATE POLICY store_review_snapshots_read ON public.store_review_snapshots
  FOR SELECT TO authenticated USING (true);

CREATE POLICY store_review_recent_read ON public.store_review_recent
  FOR SELECT TO authenticated USING (true);

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT store_id, google_place_id FROM public.meta_accounts ORDER BY store_id;
-- SELECT DISTINCT ON (store_id) store_id, rating, review_count, fetched_at
--   FROM public.store_review_snapshots ORDER BY store_id, fetched_at DESC;
-- SELECT store_id, author_name, rating, relative_time, review_text
--   FROM public.store_review_recent ORDER BY store_id, review_time DESC;

-- ── Daily sync — set up once, after GOOGLE_PLACES_API_KEY and CRON_SECRET
-- are both set in Edge Function secrets ──────────────────────────────────
-- SELECT cron.schedule(
--   'lrs-google-reviews-sync',
--   '17 6 * * *',   -- 6:17am UTC daily — off the hour, avoids the herd
--   $$
--   SELECT net.http_post(
--     url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/google-reviews',
--     headers := jsonb_build_object(
--       'Content-Type',  'application/json',
--       'x-cron-secret', 'YOUR_CRON_SECRET_BELOW'
--     ),
--     body    := jsonb_build_object('action', 'sync')
--   );
--   $$
-- );
-- View jobs:   SELECT * FROM cron.job;
-- Remove job:  SELECT cron.unschedule('lrs-google-reviews-sync');
