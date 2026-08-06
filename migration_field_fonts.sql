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

-- Per-field breathing room inside its box, as a percentage of the smaller
-- dimension. Stops glyphs sitting flush against the clip edge.
ALTER TABLE public.ad_template_fields
  ADD COLUMN IF NOT EXISTS padding_pct NUMERIC DEFAULT 2;

NOTIFY pgrst, 'reload schema';

-- Affixes render beside the text at their own size, not glued into the string.
ALTER TABLE public.ad_template_fields
  ADD COLUMN IF NOT EXISTS prefix_scale  NUMERIC DEFAULT 55,
  ADD COLUMN IF NOT EXISTS prefix_valign TEXT    DEFAULT 'middle',
  ADD COLUMN IF NOT EXISTS suffix_scale  NUMERIC DEFAULT 35,
  ADD COLUMN IF NOT EXISTS suffix_valign TEXT    DEFAULT 'bottom';

NOTIFY pgrst, 'reload schema';
