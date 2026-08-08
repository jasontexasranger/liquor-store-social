-- ============================================================================
-- Feature run dates
-- ============================================================================
-- A feature month has always implicitly run the calendar month. Making the
-- range explicit lets it deviate — a promo that starts mid-month, or runs
-- six weeks — and gives every consumer one source of truth: the post
-- planner's scheduling window, ad campaign dates, and whatever comes next.
--
-- NULL means "the calendar month of `period`", so nothing changes for any
-- existing row until someone deliberately sets a range.
-- ============================================================================

ALTER TABLE public.feature_periods
  ADD COLUMN IF NOT EXISTS starts_on DATE,
  ADD COLUMN IF NOT EXISTS ends_on   DATE;

COMMENT ON COLUMN public.feature_periods.starts_on IS
  'First day the features run. NULL = first of the period month.';
COMMENT ON COLUMN public.feature_periods.ends_on IS
  'Last day the features run. NULL = last of the period month.';

ALTER TABLE public.feature_periods DROP CONSTRAINT IF EXISTS feature_periods_dates_check;
ALTER TABLE public.feature_periods
  ADD CONSTRAINT feature_periods_dates_check
  CHECK (starts_on IS NULL OR ends_on IS NULL OR ends_on >= starts_on);

NOTIFY pgrst, 'reload schema';
