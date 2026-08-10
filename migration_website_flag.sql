-- ============================================================================
-- Website visibility per feature
-- ============================================================================
-- Managers choose which features appear in the website block. The flag lives
-- on the feature row, so the choice survives re-publishes and re-opens of
-- the push dialog. Default on: the common case is "everything with a photo".
ALTER TABLE public.features
  ADD COLUMN IF NOT EXISTS on_website BOOLEAN NOT NULL DEFAULT true;
NOTIFY pgrst, 'reload schema';
