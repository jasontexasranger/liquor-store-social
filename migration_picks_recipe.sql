-- ============================================================================
-- Store picks can flip to a recipe card too, same as monthly features.
-- ============================================================================
-- A recipe attaches automatically whenever one exists for the pick's product
-- (matched by product_id, same as everywhere else recipes attach). This flag
-- lets a manager turn that flip off for a specific pick without deleting the
-- recipe itself.
-- ============================================================================

ALTER TABLE public.store_picks
  ADD COLUMN IF NOT EXISTS recipe_on BOOLEAN NOT NULL DEFAULT true;

NOTIFY pgrst, 'reload schema';
