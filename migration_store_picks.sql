-- ============================================================================
-- Store picks — a manager-curated shelf for the website
-- ============================================================================
-- Separate from monthly features: no period, no import, just "things we want
-- on the site right now". Price is optional — a pick can be pure showcase.
-- Every change republishes the store's picks snapshot, and the website block
-- hides itself entirely when the list is empty.

CREATE TABLE IF NOT EXISTS public.store_picks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id    TEXT NOT NULL,
  product_id  UUID NOT NULL REFERENCES public.brand_images(id) ON DELETE CASCADE,
  price       NUMERIC(8,2),          -- optional: current/sale price
  reg_price   NUMERIC(8,2),          -- optional: crossed-out reference
  note        TEXT,                  -- optional one-liner ("Staff pick", "New!")
  sort        INT NOT NULL DEFAULT 0,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (store_id, product_id)
);

ALTER TABLE public.store_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_picks_read  ON public.store_picks;
DROP POLICY IF EXISTS store_picks_write ON public.store_picks;

CREATE POLICY store_picks_read ON public.store_picks
  FOR SELECT TO authenticated USING (true);

-- Same rule as features: admins everywhere, managers on their own stores.
CREATE POLICY store_picks_write ON public.store_picks
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

NOTIFY pgrst, 'reload schema';
