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
