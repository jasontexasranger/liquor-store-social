-- ============================================================================
-- Per-product background handling
-- ============================================================================
-- The cutout is a flood fill seeded from the edges of the photo: it walks
-- inward punching out anything close to the backdrop colour. That works for a
-- dark bottle on white, and fails badly for a bottle with a WHITE LABEL on
-- white — the label reaches the bottle's outline, so the fill crosses from the
-- background straight into the label and eats it. The Black Cellar reds came
-- out as gold caps and dark shoulders with a hole where the label should be.
--
-- No fill can tell that case apart from a genuine gap, like the carry handle
-- on a six-pack: both are backdrop-coloured regions touching the outside.
-- Same pixels, opposite intent. So the choice belongs to whoever is looking
-- at the product, once, per product:
--
--   auto    — flood fill from the edges (what every product does today)
--   keep    — leave the photo alone; right for artwork already on the
--             backdrop it will sit on, or anything the fill mangles
--   protect — fill, then restore anything vertically enclosed by the product,
--             which puts a white label back while still cutting the corners
-- ============================================================================

ALTER TABLE public.brand_images
  ADD COLUMN IF NOT EXISTS bg_mode TEXT NOT NULL DEFAULT 'auto';

DO $$
BEGIN
  ALTER TABLE public.brand_images
    ADD CONSTRAINT brand_images_bg_mode_check
    CHECK (bg_mode IN ('auto','keep','protect'));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN public.brand_images.bg_mode IS
  'How the price ad renderer cuts this photo out: auto | keep | protect.';

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT product_name, bg_mode FROM public.brand_images ORDER BY bg_mode, product_name;
--
-- To fix a known offender without using the UI:
-- UPDATE public.brand_images SET bg_mode = 'protect' WHERE product_name ILIKE '%black cellar%';
