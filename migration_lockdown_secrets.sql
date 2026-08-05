-- ============================================================================
-- Lock down credential tables
-- ============================================================================
-- Problem: store_tokens and api_keys were readable by EVERY authenticated user:
--
--     CREATE POLICY "auth_all_api_keys" ON public.api_keys USING (true);
--
-- The frontend also SELECTed both tables on page load, so any user who could
-- log in could read the Anthropic key, the OpenAI key, the Meta token, and any
-- Facebook Page tokens straight out of the browser.
--
-- Credentials now live in Supabase Edge Function secrets:
--   PT_{page_id}       — per-page Facebook tokens
--   ANTHROPIC_API_KEY  — used server-side by meta-social `aiWrite` / meta-ads
--
-- Edge functions use the service-role key, which bypasses RLS, so revoking
-- client access here does not affect them.
-- ============================================================================

-- 1. Drop the permissive policies -------------------------------------------
DROP POLICY IF EXISTS "auth_all_store_tokens" ON public.store_tokens;
DROP POLICY IF EXISTS "auth_all_api_keys"     ON public.api_keys;

-- 2. Deny all client access. No policy = no rows for anon/authenticated. -----
--    (RLS is already enabled on both tables.)
REVOKE ALL ON public.store_tokens FROM anon, authenticated;
REVOKE ALL ON public.api_keys     FROM anon, authenticated;

-- 3. Verify nothing is still exposed ----------------------------------------
--    Expect zero rows for both queries below.
--
--    SELECT tablename, policyname, cmd, qual
--      FROM pg_policies
--     WHERE tablename IN ('store_tokens','api_keys');
--
--    SELECT grantee, table_name, privilege_type
--      FROM information_schema.role_table_grants
--     WHERE table_name IN ('store_tokens','api_keys')
--       AND grantee IN ('anon','authenticated');

-- ============================================================================
-- 4. OPTIONAL — purge the stored credential values.
--
--    Run this ONLY after confirming the app works, since it is irreversible.
--    Page tokens are already duplicated into PT_* Edge Function secrets and the
--    Anthropic key into ANTHROPIC_API_KEY, so these rows are dead weight.
--
--    Any key that sat in these tables should be treated as compromised and
--    rotated at the provider (console.anthropic.com, platform.openai.com),
--    because it was readable by every logged-in user for as long as the
--    permissive policy existed.
-- ============================================================================
-- UPDATE public.api_keys     SET key_value  = '';
-- UPDATE public.store_tokens SET page_token = '';
