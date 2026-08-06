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
