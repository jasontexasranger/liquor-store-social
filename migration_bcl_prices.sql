-- ============================================================================
-- BCL reference price list
-- ============================================================================
-- The LDB publishes its full product list as open data, roughly quarterly.
-- Held locally so price lookups are instant and put no traffic on anyone's
-- site; the live per-SKU check stays for the moments the reference is stale.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bcl_products (
  sku          TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  category     TEXT,
  subcategory  TEXT,
  class        TEXT,
  country      TEXT,
  upc          TEXT,
  litres       NUMERIC(8,3),
  containers   INT,
  alcohol_pct  NUMERIC(5,2),
  price        NUMERIC(10,2),
  -- Which published list this row came from, e.g. "April 2026". On every row
  -- rather than in a settings table so a partial sync can never lie about
  -- how fresh a given price is.
  list_label   TEXT,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bcl_products_name_idx ON public.bcl_products (name);

ALTER TABLE public.bcl_products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bcl_products_read ON public.bcl_products;
CREATE POLICY bcl_products_read ON public.bcl_products
  FOR SELECT TO authenticated USING (true);

-- Writes come only from the sync in the edge function, which runs as the
-- service role. No user-facing write policy on purpose.

NOTIFY pgrst, 'reload schema';
