-- ============================================================================
-- Monthly features — replaces the per-store Excel sheet
-- ============================================================================
-- Mirrors the existing spreadsheet columns so the switch is a like-for-like
-- replacement rather than a new process:
--
--   Name | Size | Reg Price | Sale Price | Savings | Qty Sold | Revenue | Notes
--
-- The SOCIAL / DIGITAL / ADS / RADIO tick columns from the sheet are
-- deliberately not carried over.
--
-- Savings defaults to the price difference rounded to the nearest $0.25,
-- which is what the current sheet actually does, but stays editable.
--
-- Qty Sold and Revenue stay empty until the period is reopened the following
-- month, which is how the sheet is used today.
-- ============================================================================

-- 1. Campaigns gain an optional store ----------------------------------------
-- "Everyday Low Price" runs chain-wide (store_id NULL); a one-store promo
-- doesn't. Campaigns already existed for the creative library, so features,
-- creatives and posts all share one campaign concept.
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS store_id TEXT;

COMMENT ON COLUMN public.campaigns.store_id IS
  'NULL = chain-wide. Otherwise the campaign belongs to that one store.';

-- The old unique index assumed chain-wide names only.
DROP INDEX IF EXISTS campaigns_name_unique;
CREATE UNIQUE INDEX IF NOT EXISTS campaigns_name_scope_unique
  ON public.campaigns (lower(name), coalesce(store_id, '*'));

-- 2. Feature periods — one per store per month -------------------------------
CREATE TABLE IF NOT EXISTS public.feature_periods (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id    TEXT NOT NULL,
  period      DATE NOT NULL,              -- first of the month, e.g. 2026-08-01
  status      TEXT NOT NULL DEFAULT 'draft'
              CHECK (status IN ('draft','active','closed')),
  notes       TEXT,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS feature_periods_store_month
  ON public.feature_periods (store_id, period);

-- 3. Feature rows ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.features (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  period_id    UUID NOT NULL REFERENCES public.feature_periods(id) ON DELETE CASCADE,
  position     INT  NOT NULL DEFAULT 0,

  -- what's on feature
  name         TEXT NOT NULL,
  size         TEXT,
  reg_price    NUMERIC(10,2),
  sale_price   NUMERIC(10,2),
  -- NOT generated. Checked against the existing sheet: savings there is the
  -- difference rounded to the nearest $0.25, not the raw subtraction
  -- ($27.00 - $23.99 shows as $3.00, not $3.01). It's a marketing figure, so
  -- it's stored and editable, defaulted to that rounding in the app.
  savings      NUMERIC(10,2),

  -- optional link into the product library; matched on name, never required
  product_id   UUID REFERENCES public.brand_images(id) ON DELETE SET NULL,
  campaign_id  UUID REFERENCES public.campaigns(id) ON DELETE SET NULL,

  -- filled in after month end
  qty_sold     INT,
  revenue      NUMERIC(12,2),

  notes        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ
);

-- Drop the channel ticks if an earlier version of this migration created them.
ALTER TABLE public.features
  DROP COLUMN IF EXISTS on_social,
  DROP COLUMN IF EXISTS on_digital,
  DROP COLUMN IF EXISTS on_ads,
  DROP COLUMN IF EXISTS on_radio;

CREATE INDEX IF NOT EXISTS features_period_idx   ON public.features (period_id, position);
CREATE INDEX IF NOT EXISTS features_campaign_idx ON public.features (campaign_id);
CREATE INDEX IF NOT EXISTS features_name_idx     ON public.features (lower(name));

-- 4. Keep updated_at honest --------------------------------------------------
DROP TRIGGER IF EXISTS feature_periods_touch ON public.feature_periods;
CREATE TRIGGER feature_periods_touch
  BEFORE UPDATE ON public.feature_periods
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS features_touch ON public.features;
CREATE TRIGGER features_touch
  BEFORE UPDATE ON public.features
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 5. RLS ---------------------------------------------------------------------
ALTER TABLE public.feature_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.features        ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS feature_periods_read  ON public.feature_periods;
DROP POLICY IF EXISTS feature_periods_write ON public.feature_periods;

-- Everyone signed in can see every store's features — managers need to see
-- what the chain is running. Writing is limited to your own stores.
CREATE POLICY feature_periods_read ON public.feature_periods
  FOR SELECT TO authenticated USING (true);

CREATE POLICY feature_periods_write ON public.feature_periods
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

DROP POLICY IF EXISTS features_read  ON public.features;
DROP POLICY IF EXISTS features_write ON public.features;

CREATE POLICY features_read ON public.features
  FOR SELECT TO authenticated USING (true);

CREATE POLICY features_write ON public.features
  FOR ALL TO authenticated
  USING (
    public.is_admin() OR EXISTS (
      SELECT 1 FROM public.feature_periods p
       WHERE p.id = features.period_id
         AND p.store_id = ANY (public.my_store_ids())
    )
  )
  WITH CHECK (
    public.is_admin() OR EXISTS (
      SELECT 1 FROM public.feature_periods p
       WHERE p.id = features.period_id
         AND p.store_id = ANY (public.my_store_ids())
    )
  );

-- 6. Verify ------------------------------------------------------------------
-- SELECT p.store_id, p.period, p.status, count(f.id) AS rows,
--        count(f.qty_sold) AS with_sales
--   FROM public.feature_periods p
--   LEFT JOIN public.features f ON f.period_id = p.id
--  GROUP BY p.id ORDER BY p.period DESC, p.store_id;

NOTIFY pgrst, 'reload schema';
