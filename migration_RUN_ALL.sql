-- ============================================================================
-- RUN ALL PENDING MIGRATIONS — in dependency order
-- ============================================================================
-- Paste this whole file into the Supabase SQL editor and run once.
--
-- Order matters: is_admin() and my_store_ids() come from the creative library
-- migration, touch_updated_at() from the global products one, and the ad
-- template migration depends on both. Running them out of order fails.
--
-- Everything here is idempotent — safe to re-run if part of it already applied.
-- ============================================================================


-- ####################################################################
-- Creative library — defines is_admin(), my_store_ids(), campaigns, creatives
-- source: migration_creative_library.sql
-- ####################################################################
-- ============================================================================
-- Creative Library — campaigns + creatives
-- ============================================================================
-- Campaigns are global: one campaign ("Summer Patio 2026") can hold creatives
-- from any store. The store lives on the creative, not the campaign.
--
-- Creatives are stored in Supabase Storage (bucket: creatives) rather than as
-- base64 in a column — 16:9 ad art is far too large for a text column.
-- Only metadata lives here.
--
-- Aspect slots:
--   1:1     square        — posts + ads
--   3:5     portrait      — posts + ads
--   16:9    landscape     — ads only
--   1.91:1  link / feed   — ads only
-- Surface filtering happens in the app; both ratios stay valid data here so a
-- creative can be re-tagged without re-uploading.
-- ============================================================================

-- 1. Campaigns ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaigns (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  notes       TEXT,
  starts_on   DATE,
  ends_on     DATE,
  archived    BOOLEAN NOT NULL DEFAULT false,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS campaigns_name_unique
  ON public.campaigns (lower(name));

-- 2. Creatives ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.creatives (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  campaign_id  UUID REFERENCES public.campaigns(id) ON DELETE SET NULL,
  store_id     TEXT,                       -- NULL = global (all stores)
  aspect       TEXT NOT NULL
               CHECK (aspect IN ('1:1','3:5','16:9','1.91:1')),
  storage_path TEXT NOT NULL,              -- path inside the `creatives` bucket
  public_url   TEXT NOT NULL,
  width        INT,
  height       INT,
  bytes        INT,
  mime         TEXT,
  created_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS creatives_store_idx    ON public.creatives (store_id);
CREATE INDEX IF NOT EXISTS creatives_campaign_idx ON public.creatives (campaign_id);
CREATE INDEX IF NOT EXISTS creatives_aspect_idx   ON public.creatives (aspect);
CREATE INDEX IF NOT EXISTS creatives_created_idx  ON public.creatives (created_at DESC);

-- 3. Row level security ------------------------------------------------------
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creatives ENABLE ROW LEVEL SECURITY;

-- Helper: is the calling user an active admin?
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
     WHERE user_id = auth.uid() AND role = 'admin'
  );
$$;

-- Helper: stores the calling user may touch (admins => all)
CREATE OR REPLACE FUNCTION public.my_store_ids()
RETURNS TEXT[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT store_ids FROM public.user_roles WHERE user_id = auth.uid()),
    ARRAY[]::TEXT[]
  );
$$;

DROP POLICY IF EXISTS campaigns_read  ON public.campaigns;
DROP POLICY IF EXISTS campaigns_write ON public.campaigns;

-- Every signed-in user can see campaigns; only admins may change them.
CREATE POLICY campaigns_read ON public.campaigns
  FOR SELECT TO authenticated USING (true);
CREATE POLICY campaigns_write ON public.campaigns
  FOR ALL TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS creatives_read  ON public.creatives;
DROP POLICY IF EXISTS creatives_write ON public.creatives;

-- Read: global creatives, plus creatives for stores you're assigned to.
CREATE POLICY creatives_read ON public.creatives
  FOR SELECT TO authenticated
  USING (
    store_id IS NULL
    OR public.is_admin()
    OR store_id = ANY (public.my_store_ids())
  );

-- Write: admins anywhere; managers only within their own stores.
CREATE POLICY creatives_write ON public.creatives
  FOR ALL TO authenticated
  USING (
    public.is_admin()
    OR (store_id IS NOT NULL AND store_id = ANY (public.my_store_ids()))
  )
  WITH CHECK (
    public.is_admin()
    OR (store_id IS NOT NULL AND store_id = ANY (public.my_store_ids()))
  );

-- 4. Storage bucket ----------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('creatives', 'creatives', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "creatives read"   ON storage.objects;
DROP POLICY IF EXISTS "creatives write"  ON storage.objects;
DROP POLICY IF EXISTS "creatives delete" ON storage.objects;

CREATE POLICY "creatives read" ON storage.objects
  FOR SELECT USING (bucket_id = 'creatives');

CREATE POLICY "creatives write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'creatives');

CREATE POLICY "creatives delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'creatives');

-- 5. Verify ------------------------------------------------------------------
-- SELECT id, name, archived FROM public.campaigns ORDER BY created_at DESC;
-- SELECT name, store_id, aspect, width, height FROM public.creatives ORDER BY created_at DESC;
-- SELECT id, public FROM storage.buckets WHERE id = 'creatives';


-- ####################################################################
-- Admin RLS fix — redefines is_admin(), needs creatives to exist
-- source: migration_fix_admin_rls.sql
-- ####################################################################
-- ============================================================================
-- Fix: RLS rejects inserts from admins the database doesn't know about
-- ============================================================================
-- "new row violates row-level security policy for table creatives"
--
-- Admin status was only ever asserted in the browser, via a hardcoded
-- ADMIN_EMAILS list in index.html. Those accounts have no row in user_roles,
-- so public.is_admin() returned false and every write was refused — including
-- global creatives (store_id IS NULL), which no non-admin can create.
--
-- Two fixes, belt and braces:
--   1. Backfill user_roles so the admins exist in data.
--   2. Teach is_admin() to also trust the JWT email, so a missing row can
--      never lock an owner out of their own tool again.
-- ============================================================================

-- 1. Backfill user_roles for the known admins --------------------------------
INSERT INTO public.user_roles (user_id, role)
SELECT u.id, 'admin'
  FROM auth.users u
 WHERE lower(u.email) IN (
        'jasontexasranger@gmail.com',
        'jason@vwdevelopments.com',
        'tim@vwdevelopments.com'
      )
   AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = u.id);

UPDATE public.user_roles r
   SET role = 'admin'
  FROM auth.users u
 WHERE r.user_id = u.id
   AND lower(u.email) IN (
        'jasontexasranger@gmail.com',
        'jason@vwdevelopments.com',
        'tim@vwdevelopments.com'
      )
   AND r.role IS DISTINCT FROM 'admin';

-- 2. is_admin() also trusts the verified JWT email ---------------------------
-- auth.jwt() is signed by Supabase, so the email claim cannot be forged by a
-- client the way a browser-side constant can.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.user_roles
       WHERE user_id = auth.uid() AND role = 'admin'
    )
    OR lower(COALESCE(auth.jwt() ->> 'email','')) IN (
      'jasontexasranger@gmail.com',
      'jason@vwdevelopments.com',
      'tim@vwdevelopments.com'
    );
$$;

-- 3. Let managers create global creatives too --------------------------------
-- Original policy required store_id IS NOT NULL for non-admins, so a manager
-- picking "Global — all stores" hit the same violation. Allow it: a creative
-- is shared art, not a credential.
DROP POLICY IF EXISTS creatives_write ON public.creatives;

CREATE POLICY creatives_write ON public.creatives
  FOR ALL TO authenticated
  USING (
    public.is_admin()
    OR store_id IS NULL
    OR store_id = ANY (public.my_store_ids())
  )
  WITH CHECK (
    public.is_admin()
    OR store_id IS NULL
    OR store_id = ANY (public.my_store_ids())
  );

-- 4. Verify ------------------------------------------------------------------
-- Run while signed in as yourself; should return true:
--   SELECT public.is_admin();
--
-- Confirm the backfill landed:
--   SELECT u.email, r.role
--     FROM public.user_roles r JOIN auth.users u ON u.id = r.user_id
--    ORDER BY r.role;


-- ####################################################################
-- Global product library — defines touch_updated_at()
-- source: migration_global_products.sql
-- ####################################################################
-- ============================================================================
-- Make the product library global + support editing
-- ============================================================================
-- Products (bottles, cans, packaging shots) are the same items regardless of
-- which store is selling them, so scoping them per store just meant the same
-- bottle got uploaded four times.
--
-- store_id becomes nullable and every existing row is set to NULL = global.
-- The column is kept rather than dropped so nothing that still references it
-- breaks, and so a future "store exclusive" product is still expressible.
-- ============================================================================

-- 1. brand_images — the main Product Library --------------------------------
ALTER TABLE public.brand_images  ALTER COLUMN store_id DROP NOT NULL;
ALTER TABLE public.brand_images  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;

UPDATE public.brand_images  SET store_id = NULL WHERE store_id IS NOT NULL;

-- 2. product_images — the quick-save library in the ad generator -------------
ALTER TABLE public.product_images ALTER COLUMN store_id DROP NOT NULL;
UPDATE public.product_images SET store_id = NULL WHERE store_id IS NOT NULL;

-- 3. Keep updated_at honest --------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS brand_images_touch ON public.brand_images;
CREATE TRIGGER brand_images_touch
  BEFORE UPDATE ON public.brand_images
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 4. Optional cleanup --------------------------------------------------------
-- Flattening per-store products to global can surface duplicates — the same
-- bottle uploaded separately by two stores. Review before deleting anything:
--
--   SELECT lower(product_name) AS product, size, count(*)
--     FROM public.brand_images
--    GROUP BY 1,2 HAVING count(*) > 1
--    ORDER BY count(*) DESC;
--
-- To keep only the newest of each name+size pair:
--
--   DELETE FROM public.brand_images a
--    USING public.brand_images b
--    WHERE lower(a.product_name) = lower(b.product_name)
--      AND a.size IS NOT DISTINCT FROM b.size
--      AND a.created_at < b.created_at;

-- 5. Verify ------------------------------------------------------------------
-- SELECT count(*) FILTER (WHERE store_id IS NULL) AS global,
--        count(*) FILTER (WHERE store_id IS NOT NULL) AS scoped
--   FROM public.brand_images;


-- ####################################################################
-- Ad template fields — needs is_admin() and touch_updated_at()
-- source: migration_ad_templates.sql
-- ####################################################################
-- ============================================================================
-- Template-driven price ads
-- ============================================================================
-- The price ad renderer currently draws its own navy panels and yellow badges
-- in code. That fights against artwork like the Hideaway template, where those
-- shapes are already baked into the image.
--
-- This makes ad templates work the same way shelf talkers already do: upload a
-- blank, place labelled boxes on it visually, and the renderer only fills those
-- boxes. Field geometry is stored in percentages so one layout survives being
-- rendered at 1080, 1242 or any other size.
-- ============================================================================

-- 1. Extend brand_templates --------------------------------------------------
ALTER TABLE public.brand_templates
  ADD COLUMN IF NOT EXISTS kind        TEXT NOT NULL DEFAULT 'plain',
  ADD COLUMN IF NOT EXISTS canvas_w    INT,
  ADD COLUMN IF NOT EXISTS canvas_h    INT,
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ;

COMMENT ON COLUMN public.brand_templates.kind IS
  'plain = background only; price_ad = has positioned fields in ad_template_fields';

-- 2. Field layout ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ad_template_fields (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id   UUID NOT NULL REFERENCES public.brand_templates(id) ON DELETE CASCADE,
  field_order   INT  NOT NULL DEFAULT 0,

  -- what this box is for
  field_key     TEXT NOT NULL,          -- product_name | pack_size | price | save | product_image | custom
  field_type    TEXT NOT NULL DEFAULT 'text'
                CHECK (field_type IN ('text','product_image')),
  label         TEXT NOT NULL DEFAULT 'Field',

  -- geometry, percentage of canvas so it scales to any output size
  x_pct         NUMERIC NOT NULL,
  y_pct         NUMERIC NOT NULL,
  w_pct         NUMERIC NOT NULL,
  h_pct         NUMERIC NOT NULL,

  -- text rendering
  align         TEXT    DEFAULT 'left',
  valign        TEXT    DEFAULT 'top',
  color         TEXT    DEFAULT '#000000',
  bold          BOOLEAN DEFAULT false,
  uppercase     BOOLEAN DEFAULT false,
  wrap          BOOLEAN DEFAULT true,
  max_lines     INT     DEFAULT 2,
  min_font_size INT     DEFAULT 8,
  max_font_size INT     DEFAULT 200,
  line_spacing  NUMERIC DEFAULT 1.15,
  prefix        TEXT    DEFAULT '',
  suffix        TEXT    DEFAULT '',

  -- product_image rendering
  fit_mode      TEXT    DEFAULT 'contain' CHECK (fit_mode IN ('contain','cover')),
  remove_bg     BOOLEAN DEFAULT true,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ad_template_fields_tpl_idx
  ON public.ad_template_fields (template_id, field_order);

-- 3. RLS ---------------------------------------------------------------------
ALTER TABLE public.ad_template_fields ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ad_template_fields_read  ON public.ad_template_fields;
DROP POLICY IF EXISTS ad_template_fields_write ON public.ad_template_fields;

CREATE POLICY ad_template_fields_read ON public.ad_template_fields
  FOR SELECT TO authenticated USING (true);

CREATE POLICY ad_template_fields_write ON public.ad_template_fields
  FOR ALL TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- 4. Keep updated_at honest --------------------------------------------------
DROP TRIGGER IF EXISTS brand_templates_touch ON public.brand_templates;
CREATE TRIGGER brand_templates_touch
  BEFORE UPDATE ON public.brand_templates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 5. Verify ------------------------------------------------------------------
-- SELECT t.id, t.label, t.kind, count(f.id) AS fields
--   FROM public.brand_templates t
--   LEFT JOIN public.ad_template_fields f ON f.template_id = t.id
--  GROUP BY t.id, t.label, t.kind
--  ORDER BY t.created_at DESC;


-- ####################################################################
-- Per-store ad account mapping (independent)
-- source: migration_fix_ad_accounts.sql
-- ####################################################################
-- ============================================================================
-- Fix per-store ad account mapping
-- ============================================================================
-- Every store was pointed at a single hardcoded ad account, act_813974741538881,
-- which does not correspond to any ad account in The Sueño Company portfolio.
-- Verified real IDs from Business Settings → Accounts → Ad accounts:
--
--   Downtown Liquor Store   799684473068233
--   Brothers                871838465348844
--   Hideaway Liquor Store   1877479216980622
--   Cobblestone             (no ad account of its own)
--
-- The code no longer falls back to any default: a store with a NULL
-- ad_account_id now fails loudly instead of spending against a guessed account.
-- ============================================================================

UPDATE public.meta_accounts SET ad_account_id = 'act_799684473068233'  WHERE store_id = 'downtown';
UPDATE public.meta_accounts SET ad_account_id = 'act_871838465348844'  WHERE store_id = 'brothers';
UPDATE public.meta_accounts SET ad_account_id = 'act_1877479216980622' WHERE store_id = 'hideaway';

-- ---------------------------------------------------------------------------
-- Cobblestone has no ad account of its own. Per your decision it borrows
-- another store's account.
--
-- NOTE: spend and reporting for Cobblestone will be commingled with whichever
-- store is chosen below — the two cannot be separated afterwards in Ads
-- Manager. Uncomment exactly ONE line.
-- ---------------------------------------------------------------------------
-- UPDATE public.meta_accounts SET ad_account_id = 'act_1877479216980622' WHERE store_id = 'cobblestone';  -- share Hideaway's
-- UPDATE public.meta_accounts SET ad_account_id = 'act_799684473068233'  WHERE store_id = 'cobblestone';  -- share Downtown's
-- UPDATE public.meta_accounts SET ad_account_id = 'act_871838465348844'  WHERE store_id = 'cobblestone';  -- share Brothers'

-- Verify ---------------------------------------------------------------------
-- SELECT store_id, fb_page_id, ad_account_id FROM public.meta_accounts ORDER BY store_id;


-- ####################################################################
-- Revoke client access to credential tables (independent)
-- source: migration_lockdown_secrets.sql
-- ####################################################################
-- ============================================================================
-- Lock down credential tables
-- ============================================================================
-- Problem: store_tokens and api_keys were readable by EVERY authenticated user:
--
--     CREATE POLICY "auth_all_api_keys" ON public.api_keys USING (true);
--
-- The frontend also SELECTed both tables on page load, so any user who could
-- log in could read the Anthropic key, the OpenAI key, the Meta token, and any
-- Facebook Page tokens straight out of the browser.
--
-- Credentials now live in Supabase Edge Function secrets:
--   PT_{page_id}       — per-page Facebook tokens
--   ANTHROPIC_API_KEY  — used server-side by meta-social `aiWrite` / meta-ads
--
-- Edge functions use the service-role key, which bypasses RLS, so revoking
-- client access here does not affect them.
-- ============================================================================

-- 1. Drop the permissive policies -------------------------------------------
DROP POLICY IF EXISTS "auth_all_store_tokens" ON public.store_tokens;
DROP POLICY IF EXISTS "auth_all_api_keys"     ON public.api_keys;

-- 2. Deny all client access. No policy = no rows for anon/authenticated. -----
--    (RLS is already enabled on both tables.)
REVOKE ALL ON public.store_tokens FROM anon, authenticated;
REVOKE ALL ON public.api_keys     FROM anon, authenticated;

-- 3. Verify nothing is still exposed ----------------------------------------
--    Expect zero rows for both queries below.
--
--    SELECT tablename, policyname, cmd, qual
--      FROM pg_policies
--     WHERE tablename IN ('store_tokens','api_keys');
--
--    SELECT grantee, table_name, privilege_type
--      FROM information_schema.role_table_grants
--     WHERE table_name IN ('store_tokens','api_keys')
--       AND grantee IN ('anon','authenticated');

-- ============================================================================
-- 4. OPTIONAL — purge the stored credential values.
--
--    Run this ONLY after confirming the app works, since it is irreversible.
--    Page tokens are already duplicated into PT_* Edge Function secrets and the
--    Anthropic key into ANTHROPIC_API_KEY, so these rows are dead weight.
--
--    Any key that sat in these tables should be treated as compromised and
--    rotated at the provider (console.anthropic.com, platform.openai.com),
--    because it was readable by every logged-in user for as long as the
--    permissive policy existed.
-- ============================================================================
-- UPDATE public.api_keys     SET key_value  = '';
-- UPDATE public.store_tokens SET page_token = '';


-- ####################################################################
-- BCLIQUOR import — needs is_admin(); adds rate_limits, audit_log, bucket
-- source: migration_bcliquor.sql
-- ####################################################################
-- ============================================================================
-- BCLIQUOR product import
-- ============================================================================
-- Products are searched against the BC Liquor Stores catalogue, then the
-- selected image is copied into our own Storage bucket. BCLIQUOR images are
-- never hotlinked and product pages are never scraped — only the public
-- catalogue search endpoint is called, server-side.
-- ============================================================================

-- 1. Product provenance ------------------------------------------------------
ALTER TABLE public.brand_images
  ADD COLUMN IF NOT EXISTS bcliquor_sku TEXT,
  ADD COLUMN IF NOT EXISTS image_url    TEXT,
  ADD COLUMN IF NOT EXISTS image_alt    TEXT;

-- An imported product's bytes live in Storage, so `data` (base64) is empty for
-- those rows. It was NOT NULL from when every product was uploaded manually.
ALTER TABLE public.brand_images ALTER COLUMN data DROP NOT NULL;

-- Same reasoning for the quick-save library, if it has the same constraint.
ALTER TABLE public.product_images ALTER COLUMN data DROP NOT NULL;

-- Match on SKU first when syncing; name+size is the fallback.
CREATE INDEX IF NOT EXISTS brand_images_sku_idx
  ON public.brand_images (bcliquor_sku) WHERE bcliquor_sku IS NOT NULL;

CREATE INDEX IF NOT EXISTS brand_images_name_size_idx
  ON public.brand_images (lower(product_name), size);

-- 2. Rate limiting -----------------------------------------------------------
-- Edge functions are stateless, so the window is counted in the database.
CREATE TABLE IF NOT EXISTS public.rate_limits (
  id         BIGSERIAL PRIMARY KEY,
  user_id    UUID NOT NULL,
  action     TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS rate_limits_lookup_idx
  ON public.rate_limits (user_id, action, created_at DESC);

ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;
-- No policies: only the service role (edge functions) touches this.
REVOKE ALL ON public.rate_limits FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.check_rate_limit(
  p_user UUID, p_action TEXT, p_limit INT, p_window_seconds INT
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE used INT;
BEGIN
  DELETE FROM public.rate_limits
   WHERE created_at < now() - (p_window_seconds || ' seconds')::interval;

  SELECT count(*) INTO used
    FROM public.rate_limits
   WHERE user_id = p_user AND action = p_action
     AND created_at >= now() - (p_window_seconds || ' seconds')::interval;

  IF used >= p_limit THEN
    RETURN false;
  END IF;

  INSERT INTO public.rate_limits (user_id, action) VALUES (p_user, p_action);
  RETURN true;
END $$;

-- 3. Audit log ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_log (
  id             BIGSERIAL PRIMARY KEY,
  user_id        UUID,
  action         TEXT NOT NULL,
  entity_type    TEXT,
  entity_id      TEXT,
  changed_fields TEXT[],
  safe_metadata  JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_created_idx ON public.audit_log (created_at DESC);

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_read ON public.audit_log;
CREATE POLICY audit_log_read ON public.audit_log
  FOR SELECT TO authenticated USING (public.is_admin());
-- Writes come from the service role only.

-- 4. Storage bucket for imported product images ------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('product-media', 'product-media', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "product-media read" ON storage.objects;
CREATE POLICY "product-media read" ON storage.objects
  FOR SELECT USING (bucket_id = 'product-media');

-- 5. Verify ------------------------------------------------------------------
-- SELECT product_name, bcliquor_sku, image_url FROM public.brand_images
--  WHERE bcliquor_sku IS NOT NULL ORDER BY created_at DESC;
-- SELECT action, safe_metadata, created_at FROM public.audit_log
--  ORDER BY created_at DESC LIMIT 20;

NOTIFY pgrst, 'reload schema';


-- ####################################################################
-- Per-field fonts — needs ad_template_fields to exist
-- source: migration_field_fonts.sql
-- ####################################################################
-- ============================================================================
-- Per-field font selection for ad templates
-- ============================================================================
-- The renderer previously hardcoded Arial. Fields now carry their own face and
-- weight so a price can be set in Anton while the pack size sits in Oswald.
--
-- Faces are loaded from Google Fonts in the page head — canvas silently falls
-- back if a face isn't loaded, which is why the renderer awaits document.fonts.
-- ============================================================================

ALTER TABLE public.ad_template_fields
  ADD COLUMN IF NOT EXISTS font_family TEXT DEFAULT 'Anton',
  ADD COLUMN IF NOT EXISTS font_weight INT  DEFAULT 400;

-- Existing fields keep working; NULL falls back to Arial in the renderer.
UPDATE public.ad_template_fields
   SET font_family = COALESCE(font_family, 'Anton'),
       font_weight = COALESCE(font_weight, 400);

NOTIFY pgrst, 'reload schema';

ALTER TABLE public.ad_template_fields
  ADD COLUMN IF NOT EXISTS padding_pct NUMERIC DEFAULT 2;

ALTER TABLE public.ad_template_fields
  ADD COLUMN IF NOT EXISTS prefix_scale  NUMERIC DEFAULT 55,
  ADD COLUMN IF NOT EXISTS prefix_valign TEXT    DEFAULT 'middle',
  ADD COLUMN IF NOT EXISTS suffix_scale  NUMERIC DEFAULT 35,
  ADD COLUMN IF NOT EXISTS suffix_valign TEXT    DEFAULT 'bottom';

ALTER TABLE public.ad_template_fields
  ADD COLUMN IF NOT EXISTS bg_tolerance NUMERIC DEFAULT 42;


-- ####################################################################
-- Multiple images per post
-- source: migration_multi_image.sql
-- ####################################################################
-- ============================================================================
-- Multiple images per post
-- ============================================================================
-- Facebook takes multi-photo posts (upload unpublished, attach by media_fbid);
-- Instagram takes carousels of 2–10. Both need an ordered list, so image_url
-- alone is no longer enough.
--
-- image_url is kept and always mirrors image_urls[1], so anything still
-- reading the single column keeps working.
-- ============================================================================

ALTER TABLE public.scheduled_posts
  ADD COLUMN IF NOT EXISTS image_urls TEXT[] DEFAULT '{}';

-- Backfill existing rows from the single column.
UPDATE public.scheduled_posts
   SET image_urls = ARRAY[image_url]
 WHERE image_url IS NOT NULL
   AND (image_urls IS NULL OR cardinality(image_urls) = 0);

NOTIFY pgrst, 'reload schema';


-- ####################################################################
-- Monthly features — needs is_admin(), my_store_ids(), touch_updated_at()
-- source: migration_features.sql
-- ####################################################################
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



-- ==== migration_feature_creatives.sql ====
-- ============================================================================
-- Monthly feature creatives
-- ============================================================================
-- Price ads generated in bulk from a month's features need to be findable
-- later by the month they belong to, not just by when someone happened to
-- press the button. created_at is close to that in practice but wrong the
-- moment you regenerate August in September, or backfill an earlier month.
--
-- feature_id and template_id are what make regeneration safe: rerunning a
-- month replaces the images it produced last time instead of piling up
-- duplicates.
-- ============================================================================

ALTER TABLE public.creatives
  ADD COLUMN IF NOT EXISTS period      DATE,
  ADD COLUMN IF NOT EXISTS feature_id  UUID REFERENCES public.features(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS template_id UUID,
  ADD COLUMN IF NOT EXISTS source      TEXT NOT NULL DEFAULT 'upload';

COMMENT ON COLUMN public.creatives.period IS
  'First of the month this creative belongs to. NULL for ad-hoc uploads.';
COMMENT ON COLUMN public.creatives.source IS
  'upload = added by hand. feature_batch = generated from a monthly feature.';

-- template_id is deliberately not a foreign key: deleting a template should
-- not cascade into, or block, creatives that were already produced from it.

CREATE INDEX IF NOT EXISTS creatives_period_idx
  ON public.creatives (period DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS creatives_feature_idx
  ON public.creatives (feature_id) WHERE feature_id IS NOT NULL;

-- One image per feature per template. A rerun deletes and reinserts rather
-- than upserting — the storage object changes too — so this is a guard
-- against double-clicks and overlapping sessions, not the normal path.
CREATE UNIQUE INDEX IF NOT EXISTS creatives_feature_template_unique
  ON public.creatives (feature_id, template_id)
  WHERE feature_id IS NOT NULL AND template_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';



-- ==== migration_post_plans.sql ====
-- ============================================================================
-- Auto-generated post plans with an approval gate
-- ============================================================================
-- Nothing generated by the app may publish on its own. A planned post is
-- created as 'needs_approval'; only a human moving it to 'pending' puts it in
-- front of the scheduler, which has always picked up 'pending' and nothing
-- else. That means the publishing path itself is unchanged — the gate sits in
-- front of it rather than inside it.
--
-- Statuses now in use:
--   needs_approval → waiting on a person
--   pending        → approved, scheduler will publish at scheduled_at
--   publishing     → claimed by the scheduler
--   published      → done
--   failed         → the API rejected it
--   missed         → its time came and went without approval
-- ============================================================================

-- 1. Approval and provenance columns -----------------------------------------
ALTER TABLE public.scheduled_posts
  ADD COLUMN IF NOT EXISTS approved_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS approved_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS plan_id        UUID,
  ADD COLUMN IF NOT EXISTS assigned_to    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS feature_ids    UUID[],
  ADD COLUMN IF NOT EXISTS auto_generated BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.scheduled_posts.auto_generated IS
  'True for posts the planner created. These must be approved before they can
   reach ''pending''; posts composed by hand are already a deliberate act.';

CREATE INDEX IF NOT EXISTS scheduled_posts_status_time_idx
  ON public.scheduled_posts (status, scheduled_at);

CREATE INDEX IF NOT EXISTS scheduled_posts_plan_idx
  ON public.scheduled_posts (plan_id) WHERE plan_id IS NOT NULL;

-- 2. The plan a batch of posts came from --------------------------------------
CREATE TABLE IF NOT EXISTS public.post_plans (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id    TEXT NOT NULL,
  period      DATE NOT NULL,
  cadence     TEXT NOT NULL,              -- '1x' | '2x' | '3x' | 'custom'
  per_week    INT  NOT NULL DEFAULT 1,
  grouping    TEXT NOT NULL DEFAULT 'product',   -- 'product' | 'category'
  publish_to  TEXT[] NOT NULL DEFAULT '{facebook}',
  time_source TEXT NOT NULL DEFAULT 'manual',    -- 'meta' | 'manual'
  notes       TEXT,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS post_plans_store_period_idx
  ON public.post_plans (store_id, period DESC);

-- 3. Who may see and approve --------------------------------------------------
-- The original policies scoped everything to the row's creator, which breaks
-- the moment approval is someone else's job: a store manager could not see a
-- post the planner created under an admin's account. Store membership is the
-- right unit now.
DROP POLICY IF EXISTS "sp_select" ON public.scheduled_posts;
CREATE POLICY "sp_select" ON public.scheduled_posts FOR SELECT USING (
  created_by = auth.uid()
  OR public.is_admin()
  OR store_id = ANY (public.my_store_ids())
);

DROP POLICY IF EXISTS "sp_update" ON public.scheduled_posts;
CREATE POLICY "sp_update" ON public.scheduled_posts FOR UPDATE USING (
  created_by = auth.uid()
  OR public.is_admin()
  OR store_id = ANY (public.my_store_ids())
);

DROP POLICY IF EXISTS "sp_delete" ON public.scheduled_posts;
CREATE POLICY "sp_delete" ON public.scheduled_posts FOR DELETE USING (
  created_by = auth.uid()
  OR public.is_admin()
  OR store_id = ANY (public.my_store_ids())
);

ALTER TABLE public.post_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS post_plans_read  ON public.post_plans;
DROP POLICY IF EXISTS post_plans_write ON public.post_plans;

CREATE POLICY post_plans_read ON public.post_plans
  FOR SELECT TO authenticated USING (true);

CREATE POLICY post_plans_write ON public.post_plans
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

-- 4. The gate itself ----------------------------------------------------------
-- Enforced in the database, not the browser. RLS lets a store member update
-- their store's rows, and without this they could simply PATCH status to
-- 'pending' and skip the review. The trigger is also what stamps who approved
-- and when, so those two columns can't be back-dated or attributed to someone
-- else by whoever sent the request.
CREATE OR REPLACE FUNCTION public.enforce_post_approval()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- The scheduler runs as the service role and must stay unencumbered: it
  -- moves rows pending → publishing → published without approving anything.
  IF current_setting('request.jwt.claims', true) IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.auto_generated
     AND NEW.status = 'pending'
     AND OLD.status = 'needs_approval' THEN
    NEW.approved_by := auth.uid();
    NEW.approved_at := now();
  END IF;

  IF NEW.auto_generated
     AND NEW.status = 'pending'
     AND NEW.approved_at IS NULL THEN
    RAISE EXCEPTION 'This post has to be approved before it can be scheduled';
  END IF;

  -- Editing an approved post sends it back for review. Approving a caption and
  -- then quietly rewriting it would make the sign-off meaningless.
  IF NEW.auto_generated
     AND OLD.status = 'pending'
     AND NEW.status = 'pending'
     AND (NEW.caption IS DISTINCT FROM OLD.caption
          OR NEW.image_url IS DISTINCT FROM OLD.image_url
          OR NEW.image_urls IS DISTINCT FROM OLD.image_urls) THEN
    NEW.status      := 'needs_approval';
    NEW.approved_by := NULL;
    NEW.approved_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS scheduled_posts_approval ON public.scheduled_posts;
CREATE TRIGGER scheduled_posts_approval
  BEFORE UPDATE ON public.scheduled_posts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_post_approval();

-- An insert can't arrive pre-approved either.
CREATE OR REPLACE FUNCTION public.enforce_post_approval_insert()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF current_setting('request.jwt.claims', true) IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.auto_generated AND NEW.status <> 'needs_approval' THEN
    NEW.status := 'needs_approval';
    NEW.approved_by := NULL;
    NEW.approved_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS scheduled_posts_approval_insert ON public.scheduled_posts;
CREATE TRIGGER scheduled_posts_approval_insert
  BEFORE INSERT ON public.scheduled_posts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_post_approval_insert();

-- 5. Verify -------------------------------------------------------------------
-- SELECT status, count(*) FROM public.scheduled_posts GROUP BY status;

NOTIFY pgrst, 'reload schema';



-- ==== migration_recipes.sql ====
-- ============================================================================
-- Cocktail recipe library
-- ============================================================================
-- A recipe is written once and reused: the same Bacardi mojito card serves
-- every summer it goes on feature. So recipes are stored, not generated on the
-- way past, and they keep a link back to the product and the feature that
-- prompted them.
--
-- Card artwork is composed on canvas from the product shot, not generated by an
-- image model — the look has to stay consistent across a set, and a photo model
-- gives a different drink every time you press the button.
-- ============================================================================

-- 1. Recipes ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.recipes (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  -- NULL means it belongs to the whole chain. A recipe built around a product
  -- only one store carries can be scoped to that store.
  store_id     TEXT,
  product_id   UUID REFERENCES public.brand_images(id) ON DELETE SET NULL,
  feature_id   UUID REFERENCES public.features(id)     ON DELETE SET NULL,

  glass        TEXT,
  -- [{ "amount": "2 oz", "item": "white rum" }, ...] — kept as an array rather
  -- than a blob of text so the caption and the card can lay it out differently.
  ingredients  JSONB NOT NULL DEFAULT '[]'::jsonb,
  method       TEXT[] NOT NULL DEFAULT '{}',
  garnish      TEXT,
  notes        TEXT,

  -- The rendered card, once one has been built.
  image_url    TEXT,
  creative_id  UUID REFERENCES public.creatives(id) ON DELETE SET NULL,

  created_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS recipes_store_idx   ON public.recipes (store_id);
CREATE INDEX IF NOT EXISTS recipes_product_idx ON public.recipes (product_id);
CREATE INDEX IF NOT EXISTS recipes_name_idx    ON public.recipes (lower(name));

DROP TRIGGER IF EXISTS recipes_touch ON public.recipes;
CREATE TRIGGER recipes_touch
  BEFORE UPDATE ON public.recipes
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 2. Card styling -------------------------------------------------------------
-- One row per store, plus a chain-wide default (store_id NULL). Held as JSONB
-- because this is a look, not a schema: adding a corner treatment shouldn't
-- cost a migration, and unknown keys are merged over defaults in the app.
CREATE TABLE IF NOT EXISTS public.recipe_styles (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   TEXT UNIQUE,
  tokens     JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ
);

-- One NULL store_id only — Postgres treats NULLs as distinct in a UNIQUE
-- constraint, so the chain-wide row needs its own guard.
CREATE UNIQUE INDEX IF NOT EXISTS recipe_styles_default_unique
  ON public.recipe_styles ((1)) WHERE store_id IS NULL;

DROP TRIGGER IF EXISTS recipe_styles_touch ON public.recipe_styles;
CREATE TRIGGER recipe_styles_touch
  BEFORE UPDATE ON public.recipe_styles
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 3. 4:5 is a real size now ---------------------------------------------------
-- 1080×1350 is Instagram's tallest feed size and the one recipe cards want.
-- The creatives table only allowed the four sizes that existed when it was
-- written.
ALTER TABLE public.creatives DROP CONSTRAINT IF EXISTS creatives_aspect_check;
ALTER TABLE public.creatives
  ADD CONSTRAINT creatives_aspect_check
  CHECK (aspect IN ('1:1','4:5','3:5','16:9','1.91:1'));

-- 4. RLS ----------------------------------------------------------------------
ALTER TABLE public.recipes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_styles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS recipes_read  ON public.recipes;
DROP POLICY IF EXISTS recipes_write ON public.recipes;

-- Recipes are shared knowledge — every store can read every recipe.
CREATE POLICY recipes_read ON public.recipes
  FOR SELECT TO authenticated USING (true);

CREATE POLICY recipes_write ON public.recipes
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id IS NULL OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id IS NULL OR store_id = ANY (public.my_store_ids()));

DROP POLICY IF EXISTS recipe_styles_read  ON public.recipe_styles;
DROP POLICY IF EXISTS recipe_styles_write ON public.recipe_styles;

CREATE POLICY recipe_styles_read ON public.recipe_styles
  FOR SELECT TO authenticated USING (true);

-- The chain-wide look is an admin decision; a store may set its own.
CREATE POLICY recipe_styles_write ON public.recipe_styles
  FOR ALL TO authenticated
  USING      (public.is_admin() OR (store_id IS NOT NULL AND store_id = ANY (public.my_store_ids())))
  WITH CHECK (public.is_admin() OR (store_id IS NOT NULL AND store_id = ANY (public.my_store_ids())));

-- 5. Verify -------------------------------------------------------------------
-- SELECT count(*) FROM public.recipes;
-- SELECT store_id, tokens FROM public.recipe_styles;

NOTIFY pgrst, 'reload schema';



-- ==== migration_recipe_photo.sql ====
-- ============================================================================
-- Keep the generated cocktail photo
-- ============================================================================
-- The card is a photo of the drink with its name over it. Those two things
-- have very different costs: the photo is a paid generation that takes about
-- fifteen seconds, the name is instant canvas text.
--
-- Storing the photo separately from the finished card means restyling — a
-- different font, the name moved, a heavier scrim — costs nothing and gives the
-- same drink back. Without this column, changing the look would mean paying for
-- a new photo and getting a different glass and garnish with it.
-- ============================================================================

ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS photo_url  TEXT,
  ADD COLUMN IF NOT EXISTS photo_hint TEXT;

COMMENT ON COLUMN public.recipes.photo_url IS
  'The generated lifestyle photo, before the drink name is drawn over it.';
COMMENT ON COLUMN public.recipes.photo_hint IS
  'Optional extra direction for the photo, e.g. "beach at sunset".';

NOTIFY pgrst, 'reload schema';



-- ==== migration_cocktail_stamp.sql ====
-- ============================================================================
-- Cocktail stamp
-- ============================================================================
-- A transparent PNG each store can drop into a corner of its recipe cards —
-- a seal, a "serve it up" badge, a signature mark. Held beside the logo on the
-- brand profile because it belongs to the brand, not to any one recipe.
--
-- Stored as base64 rather than in Storage, matching how logo_data already
-- works: these are small marks fetched with the profile that's being read
-- anyway, and a second round trip per card render buys nothing.
-- ============================================================================

ALTER TABLE public.brand_profiles
  ADD COLUMN IF NOT EXISTS stamp_data TEXT;

COMMENT ON COLUMN public.brand_profiles.stamp_data IS
  'Transparent PNG overlaid on recipe cards. Position, size and opacity are
   held in recipe_styles.tokens, since those are part of the card look.';

NOTIFY pgrst, 'reload schema';



-- ==== migration_rejected_status.sql ====
-- ============================================================================
-- Rejected is its own status
-- ============================================================================
-- Rejecting a post used to mark it 'missed', which is also what happens when a
-- post's time passes without anyone approving it. Those are not the same event:
-- one is a decision, the other is a lapse you want to see and fix. Sharing a
-- status meant the calendar could not hide deliberate rejections while still
-- showing the ones that slipped.
--
-- No CHECK constraint on scheduled_posts.status, so this is a data change only.
-- ============================================================================

UPDATE public.scheduled_posts
   SET status = 'rejected'
 WHERE status = 'missed'
   AND error_msg ILIKE 'Rejected%';

-- Verify:
-- SELECT status, error_msg, count(*)
--   FROM public.scheduled_posts GROUP BY status, error_msg ORDER BY status;

NOTIFY pgrst, 'reload schema';



-- ==== migration_store_locations.sql ====
-- ============================================================================
-- Store locations
-- ============================================================================
-- Ad targeting draws a circle around a point. Until now that point came from
-- coordinates hardcoded in the app during scaffolding, which were placeholders
-- pointing at the wrong town, and there was nowhere to correct them.
--
-- Location belongs beside the other per-store Meta settings, so it goes on
-- meta_accounts rather than in a new table.
-- ============================================================================

ALTER TABLE public.meta_accounts
  ADD COLUMN IF NOT EXISTS address      TEXT,
  ADD COLUMN IF NOT EXISTS lat          NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS lng          NUMERIC(9,6),
  -- Radius is per store because a city store and a highway store do not draw
  -- from the same distance.
  ADD COLUMN IF NOT EXISTS ad_radius_km INT NOT NULL DEFAULT 15;

COMMENT ON COLUMN public.meta_accounts.lat IS
  'Centre of the ad targeting circle. From Google Maps: right-click the store,
   click the coordinates to copy them.';
COMMENT ON COLUMN public.meta_accounts.ad_radius_km IS
  'Targeting radius in kilometres. Meta allows 1 to 80.';

-- Meta rejects anything outside this range, and catching it here is kinder
-- than catching it four API calls into a campaign build.
ALTER TABLE public.meta_accounts DROP CONSTRAINT IF EXISTS meta_accounts_radius_check;
ALTER TABLE public.meta_accounts
  ADD CONSTRAINT meta_accounts_radius_check
  CHECK (ad_radius_km BETWEEN 1 AND 80);

-- Latitude and longitude are meaningless apart, so require both or neither.
ALTER TABLE public.meta_accounts DROP CONSTRAINT IF EXISTS meta_accounts_latlng_check;
ALTER TABLE public.meta_accounts
  ADD CONSTRAINT meta_accounts_latlng_check
  CHECK ((lat IS NULL) = (lng IS NULL));

-- Verify:
-- SELECT store_id, address, lat, lng, ad_radius_km FROM public.meta_accounts ORDER BY store_id;

NOTIFY pgrst, 'reload schema';



-- ==== migration_brand_website.sql ====
-- ============================================================================
-- Brand website
-- ============================================================================
-- Every ad needs a destination URL, and it was being typed in by hand each
-- time — which is how a campaign ends up pointing at the wrong store, or at
-- nothing. It belongs with the brand, once per store.
-- ============================================================================

ALTER TABLE public.brand_profiles
  ADD COLUMN IF NOT EXISTS website TEXT;

COMMENT ON COLUMN public.brand_profiles.website IS
  'Where ads send people. Prefilled as the destination URL in the ad builder,
   and still editable per campaign.';

NOTIFY pgrst, 'reload schema';



-- ==== migration_user_sections.sql ====
-- ============================================================================
-- Per-user section access
-- ============================================================================
-- Which parts of the app a person sees. NULL means "whatever the role
-- implies" — the existing behaviour — so nobody's access changes until
-- someone deliberately narrows it.
--
-- This governs navigation, not data. Row level security still decides what
-- each person can read and write, and the admin-only edge functions still
-- check the role themselves. Hiding a section stops it cluttering the screen;
-- it is not the thing standing between a store user and another store's rows.
-- ============================================================================

ALTER TABLE public.user_roles
  ADD COLUMN IF NOT EXISTS sections TEXT[];

COMMENT ON COLUMN public.user_roles.sections IS
  'Nav sections this user may open, e.g. {social,features,creatives}.
   NULL = the role default. Not a security boundary — see RLS for that.';

-- Users need to read their own row to know what to show; admins read all.
DROP POLICY IF EXISTS user_roles_self_read ON public.user_roles;
CREATE POLICY user_roles_self_read ON public.user_roles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Verify:
-- SELECT user_id, role, store_ids, sections FROM public.user_roles;

NOTIFY pgrst, 'reload schema';



-- ==== migration_bcl_prices.sql ====
-- ============================================================================
-- BCL reference price list
-- ============================================================================
-- The LDB publishes its full product list as open data, roughly quarterly.
-- Held locally so price lookups are instant and put no traffic on anyone's
-- site; the live per-SKU check stays for the moments the reference is stale.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bcl_products (
  sku          TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  category     TEXT,
  subcategory  TEXT,
  class        TEXT,
  country      TEXT,
  upc          TEXT,
  litres       NUMERIC(8,3),
  containers   INT,
  alcohol_pct  NUMERIC(5,2),
  price        NUMERIC(10,2),
  -- Which published list this row came from, e.g. "April 2026". On every row
  -- rather than in a settings table so a partial sync can never lie about
  -- how fresh a given price is.
  list_label   TEXT,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bcl_products_name_idx ON public.bcl_products (name);

ALTER TABLE public.bcl_products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bcl_products_read ON public.bcl_products;
CREATE POLICY bcl_products_read ON public.bcl_products
  FOR SELECT TO authenticated USING (true);

-- Writes come only from the sync in the edge function, which runs as the
-- service role. No user-facing write policy on purpose.

NOTIFY pgrst, 'reload schema';



-- ==== migration_signage.sql ====
-- ============================================================================
-- Signage mapping
-- ============================================================================
-- Which OptiSigns screens belong to which store, and which account key to
-- use. The OptiSigns account has twenty screens across pubs, offices and a
-- paint shop, so store-to-screen is an explicit choice — a push that guessed
-- from names could put beer prices on the paint centre's sign.
-- ============================================================================

ALTER TABLE public.meta_accounts
  ADD COLUMN IF NOT EXISTS optisigns_screen_ids TEXT[] NOT NULL DEFAULT '{}',
  -- Cobblestone lives on a separate OptiSigns account. The value names which
  -- edge-function secret holds that store's key; the default secret covers
  -- everyone else. The key itself never touches the database.
  ADD COLUMN IF NOT EXISTS optisigns_key_secret TEXT NOT NULL DEFAULT 'OPTISIGNS_API_KEY';

COMMENT ON COLUMN public.meta_accounts.optisigns_screen_ids IS
  'OptiSigns device _ids this store''s pushes go to.';

NOTIFY pgrst, 'reload schema';



-- ==== migration_feature_dates.sql ====
-- ============================================================================
-- Feature run dates
-- ============================================================================
-- A feature month has always implicitly run the calendar month. Making the
-- range explicit lets it deviate — a promo that starts mid-month, or runs
-- six weeks — and gives every consumer one source of truth: the post
-- planner's scheduling window, ad campaign dates, and whatever comes next.
--
-- NULL means "the calendar month of `period`", so nothing changes for any
-- existing row until someone deliberately sets a range.
-- ============================================================================

ALTER TABLE public.feature_periods
  ADD COLUMN IF NOT EXISTS starts_on DATE,
  ADD COLUMN IF NOT EXISTS ends_on   DATE;

COMMENT ON COLUMN public.feature_periods.starts_on IS
  'First day the features run. NULL = first of the period month.';
COMMENT ON COLUMN public.feature_periods.ends_on IS
  'Last day the features run. NULL = last of the period month.';

ALTER TABLE public.feature_periods DROP CONSTRAINT IF EXISTS feature_periods_dates_check;
ALTER TABLE public.feature_periods
  ADD CONSTRAINT feature_periods_dates_check
  CHECK (starts_on IS NULL OR ends_on IS NULL OR ends_on >= starts_on);

NOTIFY pgrst, 'reload schema';



-- ==== migration_signage_item_dates.sql ====
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



-- ==== migration_store_inventory.sql ====
-- ============================================================================
-- Store inventory
-- ============================================================================
-- What each store actually carries, imported from the POS item master. Item
-- IDs in that export are LDB/BCL SKUs, so rows join straight onto
-- bcl_products for prices. No quantities or prices live here — the export is
-- an item master, "what we carry", not "what we have".
--
-- Consumers: the Price Check "carried at this store" filter, and "not in
-- store stock list" warnings on monthly feature rows.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.store_inventory (
  store_id    TEXT NOT NULL,
  sku         TEXT NOT NULL,
  description TEXT,
  unit        TEXT,
  dept        TEXT,
  vendor      TEXT,
  case_qty    INT,
  imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, sku)
);

CREATE INDEX IF NOT EXISTS store_inventory_sku_idx ON public.store_inventory (sku);
CREATE INDEX IF NOT EXISTS store_inventory_desc_idx ON public.store_inventory (description);

ALTER TABLE public.store_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_inventory_read ON public.store_inventory;
CREATE POLICY store_inventory_read ON public.store_inventory
  FOR SELECT TO authenticated USING (true);

-- Imports happen in the browser (like the features import), so signed-in
-- users can write. Store scoping is enforced in the app.
DROP POLICY IF EXISTS store_inventory_write ON public.store_inventory;
CREATE POLICY store_inventory_write ON public.store_inventory
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';



-- ==== migration_website_flag.sql ====
-- ============================================================================
-- Website visibility per feature
-- ============================================================================
-- Managers choose which features appear in the website block. The flag lives
-- on the feature row, so the choice survives re-publishes and re-opens of
-- the push dialog. Default on: the common case is "everything with a photo".
ALTER TABLE public.features
  ADD COLUMN IF NOT EXISTS on_website BOOLEAN NOT NULL DEFAULT true;
NOTIFY pgrst, 'reload schema';



-- ==== migration_store_picks.sql ====
-- ============================================================================
-- Store picks — a manager-curated shelf for the website
-- ============================================================================
-- Separate from monthly features: no period, no import, just "things we want
-- on the site right now". Price is optional — a pick can be pure showcase.
-- Every change republishes the store's picks snapshot, and the website block
-- hides itself entirely when the list is empty.

CREATE TABLE IF NOT EXISTS public.store_picks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id    TEXT NOT NULL,
  product_id  UUID NOT NULL REFERENCES public.brand_images(id) ON DELETE CASCADE,
  price       NUMERIC(8,2),          -- optional: current/sale price
  reg_price   NUMERIC(8,2),          -- optional: crossed-out reference
  note        TEXT,                  -- optional one-liner ("Staff pick", "New!")
  sort        INT NOT NULL DEFAULT 0,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (store_id, product_id)
);

ALTER TABLE public.store_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_picks_read  ON public.store_picks;
DROP POLICY IF EXISTS store_picks_write ON public.store_picks;

CREATE POLICY store_picks_read ON public.store_picks
  FOR SELECT TO authenticated USING (true);

-- Same rule as features: admins everywhere, managers on their own stores.
CREATE POLICY store_picks_write ON public.store_picks
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

NOTIFY pgrst, 'reload schema';



-- ==== migration_picks_visible.sql ====
-- Hide a pick without deleting it: prices and notes survive off-season.
ALTER TABLE public.store_picks
  ADD COLUMN IF NOT EXISTS visible BOOLEAN NOT NULL DEFAULT true;
NOTIFY pgrst, 'reload schema';


-- ==== migration_picks_recipe.sql ====
-- Store picks can flip to a recipe card too, same as monthly features.
ALTER TABLE public.store_picks
  ADD COLUMN IF NOT EXISTS recipe_on BOOLEAN NOT NULL DEFAULT true;
NOTIFY pgrst, 'reload schema';


-- ==== migration_help_tickets.sql ====
-- Support tickets from the platform guide help bot.
CREATE TABLE IF NOT EXISTS public.help_tickets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  user_email  TEXT,
  question    TEXT NOT NULL,
  transcript  JSONB NOT NULL DEFAULT '[]'::jsonb,
  page        TEXT,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  admin_notes TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS help_tickets_status_idx ON public.help_tickets (status, created_at DESC);
CREATE INDEX IF NOT EXISTS help_tickets_user_idx   ON public.help_tickets (user_id);
ALTER TABLE public.help_tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS help_tickets_insert ON public.help_tickets;
DROP POLICY IF EXISTS help_tickets_select ON public.help_tickets;
DROP POLICY IF EXISTS help_tickets_update ON public.help_tickets;
CREATE POLICY help_tickets_insert ON public.help_tickets
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY help_tickets_select ON public.help_tickets
  FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY help_tickets_update ON public.help_tickets
  FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
NOTIFY pgrst, 'reload schema';


-- ============================================================================
-- Tell PostgREST about the new tables.
-- "Could not find the table in the schema cache" means this step was missed.
-- ============================================================================
NOTIFY pgrst, 'reload schema';
