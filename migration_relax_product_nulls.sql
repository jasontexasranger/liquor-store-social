-- ============================================================================
-- Relax NOT NULL on optional product fields
-- ============================================================================
-- brand_images.notes (and possibly size/category) were NOT NULL from when every
-- product was created through the full form, which always wrote '' for blanks.
-- Quick-create from the features grid legitimately has nothing to put there.
--
-- The app now writes '' rather than NULL, so this isn't required — it just
-- stops the schema dictating that a product must carry notes.
-- ============================================================================

ALTER TABLE public.brand_images ALTER COLUMN notes    DROP NOT NULL;
ALTER TABLE public.brand_images ALTER COLUMN size     DROP NOT NULL;
ALTER TABLE public.brand_images ALTER COLUMN category DROP NOT NULL;

NOTIFY pgrst, 'reload schema';
