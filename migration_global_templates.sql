-- ============================================================================
-- Price ad templates can be chain-wide
-- ============================================================================
-- Every template belonged to exactly one store, which is right for the
-- store-branded feature ads but wrong for EDLP: everyday pricing is often the
-- same artwork across all four locations, and rebuilding the identical
-- template four times means four things to keep in sync and four chances to
-- miss one.
--
-- NULL store_id = chain-wide, the same convention campaigns.store_id already
-- uses ('NULL = chain-wide. Otherwise the campaign belongs to that one
-- store.'). Existing templates all keep their store, so nothing moves.
-- ============================================================================

ALTER TABLE public.brand_templates
  ALTER COLUMN store_id DROP NOT NULL;

COMMENT ON COLUMN public.brand_templates.store_id IS
  'NULL = chain-wide, offered to every store. Otherwise the template belongs to that one store.';

-- Globals are read on every store's template list, so they are worth their own
-- partial index rather than being found by scanning the whole table.
CREATE INDEX IF NOT EXISTS brand_templates_global_idx
  ON public.brand_templates (use_for) WHERE store_id IS NULL;

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT COALESCE(store_id,'(chain-wide)') AS scope, name, kind, use_for
--   FROM public.brand_templates ORDER BY store_id NULLS FIRST, name;
--
-- To make an existing template chain-wide without using the UI:
-- UPDATE public.brand_templates SET store_id = NULL WHERE name = 'YOUR TEMPLATE NAME';
