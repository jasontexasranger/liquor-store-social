-- ============================================================================
-- EDLP (Everyday Low Price) items
-- ============================================================================
-- A per-store standing price list, separate from monthly features on
-- purpose: features are month-bucketed (feature_periods.period is "first of
-- the month"), and EDLP pricing runs all year with no natural month to file
-- it under. Rather than force a fake period onto feature_periods, this gets
-- its own pair of tables, kept structurally close to features/store_picks so
-- it can reuse the same push-to-website (client-built JSON snapshot) and
-- push-to-signage (existing price-ad templates + optisigns pushPlaylist)
-- machinery without touching either of those.
--
-- The normal flow: someone uploads a photo of the store's own EDLP report
-- (the app sends it to Claude for extraction), reviews/corrects the rows the
-- AI pulled out, and saves — which replaces that store's list outright,
-- since a new upload represents "here is the current full report," not an
-- addition to the old one.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.edlp_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id     TEXT NOT NULL,
  position     INT  NOT NULL DEFAULT 0,

  item_id      TEXT,     -- the report's own SKU/item number, if it has one
  name         TEXT NOT NULL,
  size         TEXT,
  reg_price    NUMERIC(10,2),
  sale_price   NUMERIC(10,2),   -- the actual everyday-low price

  on_website   BOOLEAN NOT NULL DEFAULT true,

  created_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS edlp_items_store_idx ON public.edlp_items (store_id, position);
CREATE INDEX IF NOT EXISTS edlp_items_name_idx  ON public.edlp_items (lower(name));

DROP TRIGGER IF EXISTS edlp_items_touch ON public.edlp_items;
CREATE TRIGGER edlp_items_touch
  BEFORE UPDATE ON public.edlp_items
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- One row per store: what the last upload was and how many rows it produced,
-- so the page can show "last updated Sep 9, 2026 from this file" without
-- keeping every historical upload around.
CREATE TABLE IF NOT EXISTS public.edlp_uploads (
  store_id     TEXT PRIMARY KEY,
  image_url    TEXT,
  item_count   INT NOT NULL DEFAULT 0,
  uploaded_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  uploaded_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS — same shape as features: everyone signed in can read every store's
-- EDLP (managers benefit from seeing what other stores run), writing is
-- limited to admins or that store's own manager.
ALTER TABLE public.edlp_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.edlp_uploads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS edlp_items_read    ON public.edlp_items;
DROP POLICY IF EXISTS edlp_items_write   ON public.edlp_items;
DROP POLICY IF EXISTS edlp_uploads_read  ON public.edlp_uploads;
DROP POLICY IF EXISTS edlp_uploads_write ON public.edlp_uploads;

CREATE POLICY edlp_items_read ON public.edlp_items
  FOR SELECT TO authenticated USING (true);

CREATE POLICY edlp_items_write ON public.edlp_items
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

CREATE POLICY edlp_uploads_read ON public.edlp_uploads
  FOR SELECT TO authenticated USING (true);

CREATE POLICY edlp_uploads_write ON public.edlp_uploads
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT store_id, name, size, reg_price, sale_price FROM public.edlp_items ORDER BY store_id, position;
-- SELECT * FROM public.edlp_uploads;
