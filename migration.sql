-- =====================================================================
-- LRS Social + Ads Migration
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New query)
-- =====================================================================

-- ── 1. scheduled_posts ───────────────────────────────────────────────
-- Stores posts queued for future publishing via pg_cron + edge function

CREATE TABLE IF NOT EXISTS scheduled_posts (
  id            UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  store_id      TEXT        NOT NULL,
  caption       TEXT        NOT NULL,
  image_url     TEXT,                              -- public Supabase Storage URL
  publish_to    TEXT[]      DEFAULT '{"facebook"}', -- 'facebook', 'instagram'
  scheduled_at  TIMESTAMPTZ NOT NULL,
  status        TEXT        DEFAULT 'pending',     -- pending | publishing | published | failed
  fb_post_id    TEXT,
  ig_post_id    TEXT,
  error_msg     TEXT,
  created_by    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE scheduled_posts ENABLE ROW LEVEL SECURITY;

-- Users can see their own; admins see all
CREATE POLICY "sp_select" ON scheduled_posts FOR SELECT USING (
  created_by = auth.uid()
  OR EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);
-- Any authenticated user can insert their own rows
CREATE POLICY "sp_insert" ON scheduled_posts FOR INSERT WITH CHECK (
  created_by = auth.uid()
);
-- Owner or admin can update (scheduler uses service-role, so it bypasses RLS)
CREATE POLICY "sp_update" ON scheduled_posts FOR UPDATE USING (
  created_by = auth.uid()
  OR EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);
-- Owner or admin can delete (cancel)
CREATE POLICY "sp_delete" ON scheduled_posts FOR DELETE USING (
  created_by = auth.uid()
  OR EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- ── 2. meta_accounts ─────────────────────────────────────────────────
-- Per-store Meta account metadata (IG account ID, ad account ID, etc.)
-- Populated once by admin; updated when a page's IG account changes.

CREATE TABLE IF NOT EXISTS meta_accounts (
  id              UUID  DEFAULT gen_random_uuid() PRIMARY KEY,
  store_id        TEXT  NOT NULL UNIQUE,
  fb_page_id      TEXT  NOT NULL,
  ig_account_id   TEXT,          -- Instagram Business Account ID for this page
  ad_account_id   TEXT,          -- e.g. act_813974741538881
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE meta_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ma_admin_all" ON meta_accounts
  USING (EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- Seed from existing STORES constants (update ig_account_id manually after discovery)
INSERT INTO meta_accounts (store_id, fb_page_id, ad_account_id) VALUES
  ('hideaway',    '470483222987070',  'act_813974741538881'),
  ('downtown',    '1240518919373546', 'act_813974741538881'),
  ('cobblestone', '195479573844075',  'act_813974741538881'),
  ('brothers',    '58258641073',      'act_813974741538881')
ON CONFLICT (store_id) DO NOTHING;

-- ── 3. ad_analyses ───────────────────────────────────────────────────
-- Stores AI analysis output for campaigns (so it can be retrieved later)

CREATE TABLE IF NOT EXISTS ad_analyses (
  id            UUID  DEFAULT gen_random_uuid() PRIMARY KEY,
  campaign_id   TEXT  NOT NULL,
  store_id      TEXT,
  insights      JSONB,
  ai_analysis   TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE ad_analyses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "aa_admin_all" ON ad_analyses
  USING (EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 4. Storage bucket: post-images ───────────────────────────────────
-- Public bucket for post images uploaded before sending to Meta.
-- Supabase Dashboard → Storage → New bucket "post-images" (public).
-- Or run the lines below (requires Storage extension to be enabled).

INSERT INTO storage.buckets (id, name, public)
VALUES ('post-images', 'post-images', true)
ON CONFLICT (id) DO NOTHING;

-- Public read
CREATE POLICY "post_images_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'post-images');

-- Authenticated users can upload
CREATE POLICY "post_images_auth_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'post-images' AND auth.role() = 'authenticated'
  );

-- Admin or owner can delete
CREATE POLICY "post_images_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'post-images'
    AND (
      (storage.foldername(name))[1] = auth.uid()::text
      OR EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
    )
  );

-- ── 5. updated_at triggers ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_scheduled_posts_updated_at ON scheduled_posts;
CREATE TRIGGER trg_scheduled_posts_updated_at
  BEFORE UPDATE ON scheduled_posts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_meta_accounts_updated_at ON meta_accounts;
CREATE TRIGGER trg_meta_accounts_updated_at
  BEFORE UPDATE ON meta_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── 6. pg_cron — publish scheduled posts every minute ────────────────
-- Requirements:
--   • pg_cron and pg_net extensions must be enabled in Supabase Dashboard
--     (Database → Extensions → enable pg_cron and pg_net)
--   • Set CRON_SECRET in edge function secrets (Dashboard → Edge Functions → Secrets)
--     use any strong random string, e.g.:  openssl rand -hex 32
--   • Replace YOUR_CRON_SECRET_BELOW with that same value

SELECT cron.schedule(
  'lrs-publish-scheduled-posts',
  '* * * * *',
  $$
  SELECT net.http_post(
    url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/social-scheduler',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-cron-secret', 'YOUR_CRON_SECRET_BELOW'
    ),
    body    := '{}'::jsonb
  );
  $$
);
-- After setting the real secret above, run the SELECT above once to register the job.
-- View jobs: SELECT * FROM cron.job;
-- Remove job: SELECT cron.unschedule('lrs-publish-scheduled-posts');
