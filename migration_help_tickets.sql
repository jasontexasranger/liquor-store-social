-- ============================================================================
-- Support tickets from the platform guide
-- ============================================================================
-- The pinned help bot only knows how to talk about this app — when it can't
-- help (refuses, doesn't know, or the person just wants a human), it offers
-- a "create a ticket" fallback. This is where those land: a plain queue an
-- admin works through under Settings, with the chat transcript attached so
-- nobody has to re-explain themselves.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.help_tickets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  user_email  TEXT,
  -- What the person typed as the ticket's headline, editable before they
  -- send it — usually pre-filled from their last question to the bot.
  question    TEXT NOT NULL,
  -- The chat leading up to it: [{ "role": "user"|"assistant", "content": "" }, ...]
  -- kept so an admin has the context without asking "what were you trying to do".
  transcript  JSONB NOT NULL DEFAULT '[]'::jsonb,
  -- Which page/section they were on when they opened the bot, if known.
  page        TEXT,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  admin_notes TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS help_tickets_status_idx  ON public.help_tickets (status, created_at DESC);
CREATE INDEX IF NOT EXISTS help_tickets_user_idx    ON public.help_tickets (user_id);

ALTER TABLE public.help_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS help_tickets_insert ON public.help_tickets;
DROP POLICY IF EXISTS help_tickets_select ON public.help_tickets;
DROP POLICY IF EXISTS help_tickets_update ON public.help_tickets;

-- Anyone signed in can file a ticket, but only as themselves.
CREATE POLICY help_tickets_insert ON public.help_tickets
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- A person can see their own tickets; admins see (and triage) every ticket.
CREATE POLICY help_tickets_select ON public.help_tickets
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id OR public.is_admin());

-- Only admins resolve / annotate tickets.
CREATE POLICY help_tickets_update ON public.help_tickets
  FOR UPDATE TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT status, count(*) FROM public.help_tickets GROUP BY status;
