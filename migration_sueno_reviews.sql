-- ============================================================================
-- Sueño Reviews feed — cached mirror of reviews.thesuenocompany.com
-- ============================================================================
-- The reviews site publishes four static JSON files built from Google Business
-- Profile (reviews) and Windsor.ai (profile performance). They are NOT an API:
-- no versioned endpoint, no pagination, no CORS headers. A fetch from
-- lrs.thesuenocompany.com fails outright, which is why this is synced
-- server-side by the sueno-reviews edge function rather than read in the
-- browser.
--
-- Why cache it rather than proxy it per page load:
--
--   1. The source is a FIXED 12-MONTH WINDOW (Oct 2025–Sep 2026 today). When
--      that window rolls forward, October 2025 stops being published. Proxying
--      means silently losing the oldest month every month; caching means we
--      keep it. This is the whole reason for the table-per-concern layout
--      below instead of one JSONB blob.
--   2. A static build can be redeployed, renamed, or restructured without
--      warning. If it is, the last good sync is still here and the sync log
--      says plainly when it stopped working.
--
-- RELATION TO store_review_snapshots / store_review_recent (Places API):
-- these DO NOT replace each other and neither is redundant.
--
--   Places gives a LIFETIME rating and review count (Hideaway: 4.5★ / 266)
--   and nothing else. The reviews site has no lifetime figures at all — its
--   per-store average is computed over reviews that landed inside the report
--   window (Hideaway: 4.28★ over 18). Those two numbers measure different
--   things and must never be shown as the same metric.
--
--   What the reviews site has that Places cannot provide: the full review
--   text for a year rather than Google's top 5, OUR POSTED REPLIES, twelve
--   months of profile-performance metrics, theme/issue annotation, and named
--   staff praise.
--
-- So: the leaderboard rating stays on Places; everything below is additive.
--
-- Store IDs are normalised to ours by the edge function ('hideaway-liquor'
-- → 'hideaway'), verified against the addresses already hard-coded in the
-- google-reviews function. A fifth profile (Fort Mac) is published as
-- "awaiting_access" with a null account and is skipped, not stored — it has
-- no store in meta_accounts and no data to mirror.
-- ============================================================================

-- ── Reviews ────────────────────────────────────────────────────────────────
-- Keyed on Google's own review ID, so a re-sync updates a review in place.
-- That matters for two fields that genuinely change after publication: the
-- review text (a customer can edit) and reply (we can post or reword one).
CREATE TABLE IF NOT EXISTS public.sueno_reviews (
  id                TEXT PRIMARY KEY,          -- Google's review ID
  store_id          TEXT NOT NULL,
  author            TEXT,
  rating            INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  review_text       TEXT,                      -- NULL for rating-only reviews
  review_date       DATE NOT NULL,
  source_created_at TIMESTAMPTZ,
  source_updated_at TIMESTAMPTZ,
  reply             TEXT,
  reply_updated_at  TIMESTAMPTZ,
  synced_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sueno_reviews_store_date_idx
  ON public.sueno_reviews (store_id, review_date DESC);
-- Partial index: "reviews that actually say something" is the common filter,
-- and about half of them are rating-only.
CREATE INDEX IF NOT EXISTS sueno_reviews_with_text_idx
  ON public.sueno_reviews (store_id, review_date DESC)
  WHERE review_text IS NOT NULL;
-- "Which reviews are still waiting on a reply" — the one genuinely actionable
-- question this table can answer on its own.
CREATE INDEX IF NOT EXISTS sueno_reviews_unanswered_idx
  ON public.sueno_reviews (store_id, review_date DESC)
  WHERE reply IS NULL;

COMMENT ON TABLE public.sueno_reviews IS
  'Google reviews mirrored from reviews.thesuenocompany.com, including our posted replies. Window-limited by the source; rows persist here after the source window rolls past them.';
COMMENT ON COLUMN public.sueno_reviews.review_text IS
  'NULL means a rating-only review. Do not infer a reason from absent text.';

-- ── Profile performance ────────────────────────────────────────────────────
-- One row per store per month. Source: Google Business Profile via Windsor.ai.
--
-- days_returned vs expected_days is kept deliberately: a month that returned
-- 28 of 31 days is not comparable to a complete one, and without these two
-- columns there is no way to tell a genuine dip from a short pull.
CREATE TABLE IF NOT EXISTS public.sueno_review_visibility (
  store_id                   TEXT NOT NULL,
  month                      TEXT NOT NULL,     -- 'YYYY-MM'
  days_returned              INTEGER,
  expected_days              INTEGER,
  impressions_desktop_maps   INTEGER,
  impressions_desktop_search INTEGER,
  impressions_mobile_maps    INTEGER,
  impressions_mobile_search  INTEGER,
  search_impressions         INTEGER,
  maps_impressions           INTEGER,
  total_impressions          INTEGER,
  call_clicks                INTEGER,
  website_clicks             INTEGER,
  direction_requests         INTEGER,
  menu_clicks                INTEGER,
  source_retrieved_at        TIMESTAMPTZ,
  synced_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, month)
);
CREATE INDEX IF NOT EXISTS sueno_review_visibility_month_idx
  ON public.sueno_review_visibility (month DESC);

COMMENT ON TABLE public.sueno_review_visibility IS
  'Monthly Google Business Profile performance per store. Impressions are daily per-surface/device counts, NOT distinct people. Clicks and direction requests do not establish calls connected, visits, or sales.';
COMMENT ON COLUMN public.sueno_review_visibility.days_returned IS
  'Daily records the source actually returned. Compare to expected_days before reading any month-over-month change as real.';

-- ── Theme annotation ───────────────────────────────────────────────────────
-- Interpretive classification of a review's TEXT, per theme. Sentiment here
-- describes what the text says about that theme and is independent of the
-- star rating — a 5★ review can carry a negative note about selection.
CREATE TABLE IF NOT EXISTS public.sueno_review_themes (
  review_id TEXT NOT NULL,
  theme     TEXT NOT NULL,                      -- service | food | atmosphere | value
  sentiment TEXT NOT NULL CHECK (sentiment IN ('positive','negative','mixed','neutral')),
  synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (review_id, theme)
);

COMMENT ON TABLE public.sueno_review_themes IS
  'Per-theme sentiment of a review''s text. Interpretive, not a representative survey. Sentiment describes the text about the theme, never the star rating.';

-- ── Recurring issues ───────────────────────────────────────────────────────
-- Coded so the same complaint across stores and months is countable. These
-- are customer reports to look into, not verified operating facts.
CREATE TABLE IF NOT EXISTS public.sueno_review_issues (
  review_id  TEXT NOT NULL,
  issue_code TEXT NOT NULL,
  synced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (review_id, issue_code)
);

-- The source ships human-readable text for each code. Mirrored so the UI can
-- label an issue without hardcoding a list that drifts out of date when the
-- reviews site adds a code.
CREATE TABLE IF NOT EXISTS public.sueno_review_issue_labels (
  issue_code  TEXT PRIMARY KEY,
  description TEXT NOT NULL,
  synced_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sueno_review_issues IS
  'Coded recurring complaints. Customer reports to investigate, not established operating facts.';

-- ── Named staff mentions ───────────────────────────────────────────────────
-- Two sources feed this: the per-review staffPraise in the themes file and a
-- separate staff-mentions file that also carries neutral/critical mentions.
-- The `source` column keeps them distinguishable, because only one of the two
-- is safe to put on a celebration board.
--
-- Original spellings are preserved as-is. A name is how a customer wrote it,
-- not a matched employee record, and this is explicitly not a staff
-- performance assessment.
CREATE TABLE IF NOT EXISTS public.sueno_review_staff (
  id         BIGSERIAL PRIMARY KEY,
  review_id  TEXT NOT NULL,
  name       TEXT NOT NULL,
  sentiment  TEXT,                              -- NULL when the source gives none
  quote      TEXT,
  source     TEXT NOT NULL CHECK (source IN ('staff_mentions','theme_praise')),
  synced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (review_id, name, source)
);
CREATE INDEX IF NOT EXISTS sueno_review_staff_name_idx
  ON public.sueno_review_staff (lower(name));

COMMENT ON TABLE public.sueno_review_staff IS
  'Staff names as customers wrote them. Spellings preserved; not matched to employee records and not a performance assessment. Only source=''staff_mentions'' with sentiment=''positive'' is safe for recognition displays.';

-- ── Sync log ───────────────────────────────────────────────────────────────
-- Append-only. The point is that a feed quietly going stale is the most
-- likely failure here, and a silent one: the tables keep serving last-good
-- data and look fine. This makes "when did it last work" answerable.
CREATE TABLE IF NOT EXISTS public.sueno_review_sync (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ran_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  ok                 BOOLEAN NOT NULL,
  reviews_seen       INTEGER,
  visibility_rows    INTEGER,
  theme_rows         INTEGER,
  staff_rows         INTEGER,
  source_checked_at  TIMESTAMPTZ,               -- the source's own lastCheckedAt
  skipped_stores     TEXT[],
  error              TEXT,
  detail             JSONB
);
CREATE INDEX IF NOT EXISTS sueno_review_sync_time_idx
  ON public.sueno_review_sync (ran_at DESC);

COMMENT ON TABLE public.sueno_review_sync IS
  'Append-only sync history. source_checked_at is the reviews site''s own freshness stamp — if it stops advancing, the upstream build stopped, not our sync.';

-- ── RLS ────────────────────────────────────────────────────────────────────
-- Read-only to every signed-in user, matching store_review_snapshots: this is
-- shared company reporting, not store-scoped data, and a manager seeing how
-- the other stores are doing is the point.
--
-- There is deliberately NO insert/update/delete policy on any table here. The
-- edge function writes with the service role, which bypasses RLS. Adding a
-- write policy would let a signed-in user forge review rows, and a forged
-- review is indistinguishable from a real one once it is in the table.
ALTER TABLE public.sueno_reviews              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sueno_review_visibility    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sueno_review_themes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sueno_review_issues        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sueno_review_issue_labels  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sueno_review_staff         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sueno_review_sync          ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sueno_reviews_read             ON public.sueno_reviews;
DROP POLICY IF EXISTS sueno_review_visibility_read   ON public.sueno_review_visibility;
DROP POLICY IF EXISTS sueno_review_themes_read       ON public.sueno_review_themes;
DROP POLICY IF EXISTS sueno_review_issues_read       ON public.sueno_review_issues;
DROP POLICY IF EXISTS sueno_review_issue_labels_read ON public.sueno_review_issue_labels;
DROP POLICY IF EXISTS sueno_review_staff_read        ON public.sueno_review_staff;
DROP POLICY IF EXISTS sueno_review_sync_read         ON public.sueno_review_sync;

CREATE POLICY sueno_reviews_read             ON public.sueno_reviews
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sueno_review_visibility_read   ON public.sueno_review_visibility
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sueno_review_themes_read       ON public.sueno_review_themes
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sueno_review_issues_read       ON public.sueno_review_issues
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sueno_review_issue_labels_read ON public.sueno_review_issue_labels
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sueno_review_staff_read        ON public.sueno_review_staff
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sueno_review_sync_read         ON public.sueno_review_sync
  FOR SELECT TO authenticated USING (true);

-- ── Convenience view: recurring concerns ───────────────────────────────────
-- "Two or more distinct written reviews raising the same coded issue" is the
-- threshold the reviews site itself uses to call something recurring, kept
-- here so the UI and the source agree rather than each inventing a cutoff.
CREATE OR REPLACE VIEW public.sueno_recurring_issues AS
SELECT
  r.store_id,
  i.issue_code,
  COALESCE(l.description, i.issue_code) AS description,
  count(DISTINCT i.review_id)           AS mentions,
  min(r.review_date)                    AS first_seen,
  max(r.review_date)                    AS last_seen
FROM public.sueno_review_issues i
JOIN public.sueno_reviews r ON r.id = i.review_id
LEFT JOIN public.sueno_review_issue_labels l ON l.issue_code = i.issue_code
GROUP BY r.store_id, i.issue_code, l.description
HAVING count(DISTINCT i.review_id) >= 2;

COMMENT ON VIEW public.sueno_recurring_issues IS
  'Coded issues raised by 2+ distinct reviews at a store. Matches the reviews site''s own recurring-concern threshold.';

NOTIFY pgrst, 'reload schema';

-- Verify -------------------------------------------------------------------
-- Expected after the first sync, against the source as of 2026-10-05:
--   38 reviews (Hideaway 18, Downtown 10, Brothers 7, Cobblestone 3)
--   48 visibility rows (4 stores x 12 months, 2025-10 .. 2026-09)
--   19 annotated reviews, 4 issue labels
--
-- SELECT store_id, count(*) AS reviews,
--        round(avg(rating), 2) AS window_avg,
--        count(review_text)    AS with_text,
--        count(reply)          AS replied
--   FROM public.sueno_reviews GROUP BY store_id ORDER BY reviews DESC;
--
-- SELECT store_id, month, total_impressions, website_clicks, direction_requests,
--        days_returned || '/' || expected_days AS coverage
--   FROM public.sueno_review_visibility
--  WHERE month = (SELECT max(month) FROM public.sueno_review_visibility)
--  ORDER BY total_impressions DESC;
--
-- SELECT * FROM public.sueno_recurring_issues ORDER BY mentions DESC;
--
-- Still unanswered, oldest first — the actionable list:
-- SELECT store_id, review_date, rating, left(review_text, 60)
--   FROM public.sueno_reviews
--  WHERE reply IS NULL AND review_text IS NOT NULL
--  ORDER BY review_date;
--
-- Freshness. If source_checked_at stops advancing, the upstream build stopped:
-- SELECT ran_at, ok, reviews_seen, visibility_rows, source_checked_at, error
--   FROM public.sueno_review_sync ORDER BY ran_at DESC LIMIT 5;

-- ── Daily sync — set up once, after CRON_SECRET is confirmed set ──────────
-- Deliberately 6:40am UTC: after google-reviews at 6:17 so the two don't
-- contend, and the upstream site rebuilds well before then.
-- SELECT cron.schedule(
--   'lrs-sueno-reviews-sync',
--   '40 6 * * *',
--   $$
--   SELECT net.http_post(
--     url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/sueno-reviews',
--     headers := jsonb_build_object(
--                  'Content-Type',   'application/json',
--                  'x-cron-secret',  current_setting('app.cron_secret', true)
--                ),
--     body    := jsonb_build_object('action', 'sync')
--   );
--   $$
-- );
