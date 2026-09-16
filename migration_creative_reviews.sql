-- ============================================================================
-- Creative approval rounds
-- ============================================================================
-- A month's price graphics get generated in a batch and then have to be signed
-- off by the store before they go on a screen or a shelf. That sign-off was
-- happening over text and email with no record of which version was approved,
-- so this gives each batch a review round: a contact sheet to look at and a
-- link the store can tick through.
--
-- Two design choices worth knowing:
--
-- 1. Item name and URL are copied onto creative_review_items rather than only
--    referenced. A creative can be regenerated or deleted, and a record of
--    what someone approved has to keep showing what they actually saw.
--
-- 2. The store opens the review with a link and no login — most store staff
--    don't have accounts, and requiring one is how a sign-off step gets
--    skipped. The token is a capability: 128 bits of randomness, and anyone
--    holding the link can decide. That's the same trade a DocuSign link makes.
--    Reviews are never listed by anything but the token, and the RPCs below
--    are the only route anon has to these tables.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.creative_reviews (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id    TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'features'
              CHECK (kind IN ('features','edlp')),
  period      DATE,                 -- first of the month for features; NULL for EDLP
  title       TEXT NOT NULL DEFAULT 'Creative approval',

  -- The capability in the link. Long, random, and unique.
  -- pgcrypto lives in the extensions schema on Supabase, so this is
  -- schema-qualified: a bare gen_random_bytes depends on the inserting
  -- session's search_path happening to include it.
  token       TEXT NOT NULL DEFAULT encode(extensions.gen_random_bytes(16), 'hex'),

  status      TEXT NOT NULL DEFAULT 'open'
              CHECK (status IN ('open','submitted','closed')),
  sheet_url   TEXT,                 -- the contact sheet PDF in storage
  reviewer    TEXT,                 -- whoever typed their name on submit
  note        TEXT,                 -- overall note from the store
  submitted_at TIMESTAMPTZ,

  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS creative_reviews_token_key
  ON public.creative_reviews (token);
CREATE INDEX IF NOT EXISTS creative_reviews_store_idx
  ON public.creative_reviews (store_id, created_at DESC);

DROP TRIGGER IF EXISTS creative_reviews_touch ON public.creative_reviews;
CREATE TRIGGER creative_reviews_touch
  BEFORE UPDATE ON public.creative_reviews
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE IF NOT EXISTS public.creative_review_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id   UUID NOT NULL REFERENCES public.creative_reviews(id) ON DELETE CASCADE,
  creative_id UUID REFERENCES public.creatives(id) ON DELETE SET NULL,

  -- Copied, not just referenced — see note 1 above.
  name        TEXT NOT NULL DEFAULT '',
  aspect      TEXT,
  public_url  TEXT NOT NULL,
  sort        INT NOT NULL DEFAULT 0,

  decision    TEXT NOT NULL DEFAULT 'pending'
              CHECK (decision IN ('pending','approved','rejected')),
  note        TEXT,
  decided_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS creative_review_items_review_idx
  ON public.creative_review_items (review_id, sort);

-- RLS ------------------------------------------------------------------------
-- Signed-in staff read every round (a manager benefits from seeing what the
-- chain is running) and write their own store's; anon gets nothing directly
-- and must go through the token RPCs.
ALTER TABLE public.creative_reviews      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creative_review_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS creative_reviews_read   ON public.creative_reviews;
DROP POLICY IF EXISTS creative_reviews_write  ON public.creative_reviews;
DROP POLICY IF EXISTS creative_review_items_read  ON public.creative_review_items;
DROP POLICY IF EXISTS creative_review_items_write ON public.creative_review_items;

CREATE POLICY creative_reviews_read ON public.creative_reviews
  FOR SELECT TO authenticated USING (true);

CREATE POLICY creative_reviews_write ON public.creative_reviews
  FOR ALL TO authenticated
  USING      (public.is_admin() OR store_id = ANY (public.my_store_ids()))
  WITH CHECK (public.is_admin() OR store_id = ANY (public.my_store_ids()));

CREATE POLICY creative_review_items_read ON public.creative_review_items
  FOR SELECT TO authenticated USING (true);

CREATE POLICY creative_review_items_write ON public.creative_review_items
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.creative_reviews r
     WHERE r.id = review_id
       AND (public.is_admin() OR r.store_id = ANY (public.my_store_ids()))))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.creative_reviews r
     WHERE r.id = review_id
       AND (public.is_admin() OR r.store_id = ANY (public.my_store_ids()))));

-- Token RPCs -----------------------------------------------------------------
-- SECURITY DEFINER so the public page never touches the tables directly, with
-- search_path pinned so the definer rights can't be pointed at another schema's
-- objects. Each one takes the token and does nothing at all without a match —
-- there is no "list reviews" path for anon by design.

CREATE OR REPLACE FUNCTION public.review_fetch(p_token TEXT)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'title',  r.title,
    'store',  r.store_id,
    'kind',   r.kind,
    'status', r.status,
    'note',   r.note,
    'reviewer', r.reviewer,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', i.id, 'name', i.name, 'aspect', i.aspect,
               'url', i.public_url, 'decision', i.decision, 'note', i.note)
             ORDER BY i.sort, i.name)
        FROM public.creative_review_items i
       WHERE i.review_id = r.id), '[]'::jsonb)
  )
  FROM public.creative_reviews r
  WHERE r.token = p_token;
$$;

CREATE OR REPLACE FUNCTION public.review_decide(
  p_token TEXT, p_item UUID, p_decision TEXT, p_note TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_review UUID;
BEGIN
  IF p_decision NOT IN ('pending','approved','rejected') THEN
    RAISE EXCEPTION 'bad decision';
  END IF;

  -- A closed round is history; reopening is a staff action, not a link action.
  SELECT id INTO v_review FROM public.creative_reviews
   WHERE token = p_token AND status <> 'closed';
  IF v_review IS NULL THEN RETURN false; END IF;

  UPDATE public.creative_review_items
     SET decision = p_decision,
         note = NULLIF(btrim(COALESCE(p_note, '')), ''),
         decided_at = now()
   WHERE id = p_item AND review_id = v_review;

  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.review_submit(
  p_token TEXT, p_reviewer TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.creative_reviews
     SET status = 'submitted',
         reviewer = NULLIF(btrim(COALESCE(p_reviewer, '')), ''),
         note = NULLIF(btrim(COALESCE(p_note, '')), ''),
         submitted_at = now()
   WHERE token = p_token AND status <> 'closed';
  RETURN FOUND;
END;
$$;

-- anon may call exactly these three and nothing else.
REVOKE ALL ON FUNCTION public.review_fetch(TEXT)                      FROM PUBLIC;
REVOKE ALL ON FUNCTION public.review_decide(TEXT, UUID, TEXT, TEXT)   FROM PUBLIC;
REVOKE ALL ON FUNCTION public.review_submit(TEXT, TEXT, TEXT)         FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_fetch(TEXT)                    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.review_decide(TEXT, UUID, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.review_submit(TEXT, TEXT, TEXT)       TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT r.title, r.store_id, r.status, count(i.id) AS items,
--        count(*) FILTER (WHERE i.decision = 'approved') AS approved,
--        count(*) FILTER (WHERE i.decision = 'rejected') AS rejected
--   FROM public.creative_reviews r
--   LEFT JOIN public.creative_review_items i ON i.review_id = r.id
--  GROUP BY r.id, r.title, r.store_id, r.status
--  ORDER BY r.created_at DESC;
