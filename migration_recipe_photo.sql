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
