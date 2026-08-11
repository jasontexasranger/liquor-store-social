-- ============================================================================
-- One-time login links
-- ============================================================================
-- An admin picks an email, a role (admin or store), and how many hours the
-- link stays valid, and gets back a single-use URL to send however they
-- like (text, email, whatever). Opening it signs the person straight in —
-- creating their account first if this is the first time — with that role
-- already applied. The link stops working the moment it's used, or once its
-- own clock runs out, whichever comes first.
--
-- Redemption always goes through the meta-social edge function's service
-- role (a visitor with no session yet can't be gated by RLS), so the only
-- direct table access this needs is for admins managing the list.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.login_links (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Two gen_random_uuid() calls concatenated give 64 hex characters —
  -- unguessable without needing a separate crypto extension.
  token       TEXT UNIQUE NOT NULL
                DEFAULT (replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')),
  email       TEXT NOT NULL,
  role        TEXT NOT NULL CHECK (role IN ('admin','store')),
  store_ids   TEXT[] NOT NULL DEFAULT '{}',
  sections    TEXT[],
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL,
  redeemed_at TIMESTAMPTZ,
  revoked     BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS login_links_active_idx ON public.login_links (expires_at) WHERE redeemed_at IS NULL AND NOT revoked;

ALTER TABLE public.login_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS login_links_admin ON public.login_links;

-- Only admins ever touch this table directly (viewing/revoking the list).
-- Redemption is done by the edge function's service-role client, which
-- bypasses RLS entirely — a logged-out visitor has no session to check.
CREATE POLICY login_links_admin ON public.login_links
  FOR ALL TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT email, role, expires_at, redeemed_at, revoked FROM public.login_links ORDER BY created_at DESC;
