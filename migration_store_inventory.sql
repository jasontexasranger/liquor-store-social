-- ============================================================================
-- Store inventory
-- ============================================================================
-- What each store actually carries, imported from the POS item master. Item
-- IDs in that export are LDB/BCL SKUs, so rows join straight onto
-- bcl_products for prices. No quantities or prices live here — the export is
-- an item master, "what we carry", not "what we have".
--
-- Consumers: the Price Check "carried at this store" filter, and "not in
-- store stock list" warnings on monthly feature rows.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.store_inventory (
  store_id    TEXT NOT NULL,
  sku         TEXT NOT NULL,
  description TEXT,
  unit        TEXT,
  dept        TEXT,
  vendor      TEXT,
  case_qty    INT,
  imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, sku)
);

CREATE INDEX IF NOT EXISTS store_inventory_sku_idx ON public.store_inventory (sku);
CREATE INDEX IF NOT EXISTS store_inventory_desc_idx ON public.store_inventory (description);

ALTER TABLE public.store_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_inventory_read ON public.store_inventory;
CREATE POLICY store_inventory_read ON public.store_inventory
  FOR SELECT TO authenticated USING (true);

-- Imports happen in the browser (like the features import), so signed-in
-- users can write. Store scoping is enforced in the app.
DROP POLICY IF EXISTS store_inventory_write ON public.store_inventory;
CREATE POLICY store_inventory_write ON public.store_inventory
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
