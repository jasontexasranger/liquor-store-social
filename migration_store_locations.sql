-- ============================================================================
-- Store locations
-- ============================================================================
-- Ad targeting draws a circle around a point. Until now that point came from
-- coordinates hardcoded in the app during scaffolding, which were placeholders
-- pointing at the wrong town, and there was nowhere to correct them.
--
-- Location belongs beside the other per-store Meta settings, so it goes on
-- meta_accounts rather than in a new table.
-- ============================================================================

ALTER TABLE public.meta_accounts
  ADD COLUMN IF NOT EXISTS address      TEXT,
  ADD COLUMN IF NOT EXISTS lat          NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS lng          NUMERIC(9,6),
  -- Radius is per store because a city store and a highway store do not draw
  -- from the same distance. 8 km is a town-sized catchment: it keeps Salmon
  -- Arm's ads out of Sicamous, 25 km away, without cutting the town in half.
  ADD COLUMN IF NOT EXISTS ad_radius_km INT NOT NULL DEFAULT 8;

COMMENT ON COLUMN public.meta_accounts.lat IS
  'Centre of the ad targeting circle. From Google Maps: right-click the store,
   click the coordinates to copy them.';
COMMENT ON COLUMN public.meta_accounts.ad_radius_km IS
  'Targeting radius in kilometres. Meta allows 1 to 80.';

-- Meta rejects anything outside this range, and catching it here is kinder
-- than catching it four API calls into a campaign build.
ALTER TABLE public.meta_accounts DROP CONSTRAINT IF EXISTS meta_accounts_radius_check;
ALTER TABLE public.meta_accounts
  ADD CONSTRAINT meta_accounts_radius_check
  CHECK (ad_radius_km BETWEEN 1 AND 80);

-- Latitude and longitude are meaningless apart, so require both or neither.
ALTER TABLE public.meta_accounts DROP CONSTRAINT IF EXISTS meta_accounts_latlng_check;
ALTER TABLE public.meta_accounts
  ADD CONSTRAINT meta_accounts_latlng_check
  CHECK ((lat IS NULL) = (lng IS NULL));

-- Verify:
-- SELECT store_id, address, lat, lng, ad_radius_km FROM public.meta_accounts ORDER BY store_id;

NOTIFY pgrst, 'reload schema';
