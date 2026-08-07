-- ============================================================================
-- Brand website
-- ============================================================================
-- Every ad needs a destination URL, and it was being typed in by hand each
-- time — which is how a campaign ends up pointing at the wrong store, or at
-- nothing. It belongs with the brand, once per store.
-- ============================================================================

ALTER TABLE public.brand_profiles
  ADD COLUMN IF NOT EXISTS website TEXT;

COMMENT ON COLUMN public.brand_profiles.website IS
  'Where ads send people. Prefilled as the destination URL in the ad builder,
   and still editable per campaign.';

NOTIFY pgrst, 'reload schema';
