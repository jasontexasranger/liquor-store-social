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
