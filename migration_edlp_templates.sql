-- ============================================================================
-- Price ad templates get a purpose: Features, EDLP, or both
-- ============================================================================
-- Features and EDLP draw price ads from the same template system, but a
-- month's feature ad and a standing everyday-low-price ad usually want to look
-- different — different headline treatment, different badge, often different
-- branding entirely.
--
-- The default is 'features' on purpose: every template that exists today was
-- designed for the monthly features batch, so this leaves them exactly where
-- they were rather than quietly offering feature-branded artwork to EDLP. The
-- EDLP generator starts with nothing and says so, pointing at the setting.
-- ============================================================================

ALTER TABLE public.brand_templates
  ADD COLUMN IF NOT EXISTS use_for TEXT NOT NULL DEFAULT 'features';

-- Added separately from the column so re-running doesn't fail on an existing
-- constraint; every current row is 'features', so it validates cleanly.
DO $$
BEGIN
  ALTER TABLE public.brand_templates
    ADD CONSTRAINT brand_templates_use_for_check
    CHECK (use_for IN ('features','edlp','both'));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN public.brand_templates.use_for IS
  'Which price ad generator offers this template: features | edlp | both.';

CREATE INDEX IF NOT EXISTS brand_templates_use_for_idx
  ON public.brand_templates (store_id, use_for);

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT store_id, name, kind, use_for FROM public.brand_templates ORDER BY store_id, name;
--
-- To move one template over to EDLP without using the UI:
-- UPDATE public.brand_templates SET use_for = 'edlp' WHERE name = 'YOUR TEMPLATE NAME';
