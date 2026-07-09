-- ============================================================
-- Liquor Store Social Media Manager — Supabase Schema
-- Run this in: Supabase Dashboard → SQL Editor → New Query
-- ============================================================

-- 1. Store page access tokens (one row per store)
CREATE TABLE IF NOT EXISTS public.store_tokens (
  store_id    TEXT PRIMARY KEY,          -- e.g. 'hideaway', 'downtown'
  page_token  TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Shared API keys (meta_token, anthropic_key, openai_key)
CREATE TABLE IF NOT EXISTS public.api_keys (
  key_name   TEXT PRIMARY KEY,           -- 'meta_token' | 'anthropic_key' | 'openai_key'
  key_value  TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the three key rows so upserts always hit an existing row
INSERT INTO public.api_keys (key_name, key_value)
VALUES
  ('meta_token',    ''),
  ('anthropic_key', ''),
  ('openai_key',    '')
ON CONFLICT (key_name) DO NOTHING;

-- 3. Per-store brand profiles (voice/tone + visual guidelines + logo)
CREATE TABLE IF NOT EXISTS public.brand_profiles (
  store_id        TEXT PRIMARY KEY,
  -- Voice & tone
  personality     TEXT NOT NULL DEFAULT '',
  tone            TEXT NOT NULL DEFAULT '',
  do_say          TEXT NOT NULL DEFAULT '',
  dont_say        TEXT NOT NULL DEFAULT '',
  audience        TEXT NOT NULL DEFAULT '',
  -- Visual
  primary_color   TEXT NOT NULL DEFAULT '#1e3a5f',
  secondary_color TEXT NOT NULL DEFAULT '#c4a35a',
  accent_color    TEXT NOT NULL DEFAULT '#f8f4ef',
  visual_style    TEXT NOT NULL DEFAULT '',
  mood            TEXT NOT NULL DEFAULT '',
  style_keywords  TEXT NOT NULL DEFAULT '',
  avoid_visually  TEXT NOT NULL DEFAULT '',
  -- Logo stored as base64 data URL (may be large — consider Supabase Storage for prod)
  logo_data       TEXT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Per-user image generation history
CREATE TABLE IF NOT EXISTS public.generation_history (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  store_id       TEXT NOT NULL,
  store_name     TEXT NOT NULL DEFAULT '',
  image_url      TEXT NOT NULL,          -- DALL-E CDN URL (expires ~1 hour)
  revised_prompt TEXT,                   -- DALL-E revised prompt
  brief          TEXT,                   -- User brief
  size_label     TEXT,                   -- e.g. '1024x1024'
  prompt         TEXT,                   -- Full assembled DALL-E prompt
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- Row Level Security
-- ============================================================

ALTER TABLE public.store_tokens       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_keys           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_profiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.generation_history ENABLE ROW LEVEL SECURITY;

-- store_tokens — any authenticated user can read & write
CREATE POLICY "auth_all_store_tokens" ON public.store_tokens
  FOR ALL TO authenticated
  USING (true)
  WITH CHECK (true);

-- api_keys — any authenticated user can read & write
CREATE POLICY "auth_all_api_keys" ON public.api_keys
  FOR ALL TO authenticated
  USING (true)
  WITH CHECK (true);

-- brand_profiles — any authenticated user can read & write
CREATE POLICY "auth_all_brand_profiles" ON public.brand_profiles
  FOR ALL TO authenticated
  USING (true)
  WITH CHECK (true);

-- generation_history — each user sees only their own rows
CREATE POLICY "own_history_select" ON public.generation_history
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "own_history_insert" ON public.generation_history
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "own_history_delete" ON public.generation_history
  FOR DELETE TO authenticated
  USING (auth.uid() = user_id);

-- ============================================================
-- Helpful indexes
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_gen_history_user_created
  ON public.generation_history (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_gen_history_store
  ON public.generation_history (store_id, created_at DESC);
