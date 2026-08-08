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
