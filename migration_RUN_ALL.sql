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


-- ============================================================================
-- Tell PostgREST about the new tables.
-- "Could not find the table in the schema cache" means this step was missed.
-- ============================================================================
NOTIFY pgrst, 'reload schema';
