-- ============================================================================
-- Fix: RLS rejects inserts from admins the database doesn't know about
-- ============================================================================
-- "new row violates row-level security policy for table creatives"
--
-- Admin status was only ever asserted in the browser, via a hardcoded
-- ADMIN_EMAILS list in index.html. Those accounts have no row in user_roles,
-- so public.is_admin() returned false and every write was refused — including
-- global creatives (store_id IS NULL), which no non-admin can create.
--
-- Two fixes, belt and braces:
--   1. Backfill user_roles so the admins exist in data.
--   2. Teach is_admin() to also trust the JWT email, so a missing row can
--      never lock an owner out of their own tool again.
-- ============================================================================

-- 1. Backfill user_roles for the known admins --------------------------------
INSERT INTO public.user_roles (user_id, role)
SELECT u.id, 'admin'
  FROM auth.users u
 WHERE lower(u.email) IN (
        'jasontexasranger@gmail.com',
        'jason@vwdevelopments.com',
        'tim@vwdevelopments.com'
      )
   AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = u.id);

UPDATE public.user_roles r
   SET role = 'admin'
  FROM auth.users u
 WHERE r.user_id = u.id
   AND lower(u.email) IN (
        'jasontexasranger@gmail.com',
        'jason@vwdevelopments.com',
        'tim@vwdevelopments.com'
      )
   AND r.role IS DISTINCT FROM 'admin';

-- 2. is_admin() also trusts the verified JWT email ---------------------------
-- auth.jwt() is signed by Supabase, so the email claim cannot be forged by a
-- client the way a browser-side constant can.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.user_roles
       WHERE user_id = auth.uid() AND role = 'admin'
    )
    OR lower(COALESCE(auth.jwt() ->> 'email','')) IN (
      'jasontexasranger@gmail.com',
      'jason@vwdevelopments.com',
      'tim@vwdevelopments.com'
    );
$$;

-- 3. Let managers create global creatives too --------------------------------
-- Original policy required store_id IS NOT NULL for non-admins, so a manager
-- picking "Global — all stores" hit the same violation. Allow it: a creative
-- is shared art, not a credential.
DROP POLICY IF EXISTS creatives_write ON public.creatives;

CREATE POLICY creatives_write ON public.creatives
  FOR ALL TO authenticated
  USING (
    public.is_admin()
    OR store_id IS NULL
    OR store_id = ANY (public.my_store_ids())
  )
  WITH CHECK (
    public.is_admin()
    OR store_id IS NULL
    OR store_id = ANY (public.my_store_ids())
  );

-- 4. Verify ------------------------------------------------------------------
-- Run while signed in as yourself; should return true:
--   SELECT public.is_admin();
--
-- Confirm the backfill landed:
--   SELECT u.email, r.role
--     FROM public.user_roles r JOIN auth.users u ON u.id = r.user_id
--    ORDER BY r.role;
