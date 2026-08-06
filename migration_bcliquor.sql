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
