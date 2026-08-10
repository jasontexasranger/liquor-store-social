-- Hide a pick without deleting it: prices and notes survive off-season.
ALTER TABLE public.store_picks
  ADD COLUMN IF NOT EXISTS visible BOOLEAN NOT NULL DEFAULT true;
NOTIFY pgrst, 'reload schema';
