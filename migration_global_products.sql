-- ============================================================================
-- Make the product library global + support editing
-- ============================================================================
-- Products (bottles, cans, packaging shots) are the same items regardless of
-- which store is selling them, so scoping them per store just meant the same
-- bottle got uploaded four times.
--
-- store_id becomes nullable and every existing row is set to NULL = global.
-- The column is kept rather than dropped so nothing that still references it
-- breaks, and so a future "store exclusive" product is still expressible.
-- ============================================================================

-- 1. brand_images — the main Product Library --------------------------------
ALTER TABLE public.brand_images  ALTER COLUMN store_id DROP NOT NULL;
ALTER TABLE public.brand_images  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;

UPDATE public.brand_images  SET store_id = NULL WHERE store_id IS NOT NULL;

-- 2. product_images — the quick-save library in the ad generator -------------
ALTER TABLE public.product_images ALTER COLUMN store_id DROP NOT NULL;
UPDATE public.product_images SET store_id = NULL WHERE store_id IS NOT NULL;

-- 3. Keep updated_at honest --------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS brand_images_touch ON public.brand_images;
CREATE TRIGGER brand_images_touch
  BEFORE UPDATE ON public.brand_images
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 4. Optional cleanup --------------------------------------------------------
-- Flattening per-store products to global can surface duplicates — the same
-- bottle uploaded separately by two stores. Review before deleting anything:
--
--   SELECT lower(product_name) AS product, size, count(*)
--     FROM public.brand_images
--    GROUP BY 1,2 HAVING count(*) > 1
--    ORDER BY count(*) DESC;
--
-- To keep only the newest of each name+size pair:
--
--   DELETE FROM public.brand_images a
--    USING public.brand_images b
--    WHERE lower(a.product_name) = lower(b.product_name)
--      AND a.size IS NOT DISTINCT FROM b.size
--      AND a.created_at < b.created_at;

-- 5. Verify ------------------------------------------------------------------
-- SELECT count(*) FILTER (WHERE store_id IS NULL) AS global,
--        count(*) FILTER (WHERE store_id IS NOT NULL) AS scoped
--   FROM public.brand_images;
