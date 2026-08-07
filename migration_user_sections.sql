-- ============================================================================
-- Per-user section access
-- ============================================================================
-- Which parts of the app a person sees. NULL means "whatever the role
-- implies" — the existing behaviour — so nobody's access changes until
-- someone deliberately narrows it.
--
-- This governs navigation, not data. Row level security still decides what
-- each person can read and write, and the admin-only edge functions still
-- check the role themselves. Hiding a section stops it cluttering the screen;
-- it is not the thing standing between a store user and another store's rows.
-- ============================================================================

ALTER TABLE public.user_roles
  ADD COLUMN IF NOT EXISTS sections TEXT[];

COMMENT ON COLUMN public.user_roles.sections IS
  'Nav sections this user may open, e.g. {social,features,creatives}.
   NULL = the role default. Not a security boundary — see RLS for that.';

-- Users need to read their own row to know what to show; admins read all.
DROP POLICY IF EXISTS user_roles_self_read ON public.user_roles;
CREATE POLICY user_roles_self_read ON public.user_roles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Verify:
-- SELECT user_id, role, store_ids, sections FROM public.user_roles;

NOTIFY pgrst, 'reload schema';
