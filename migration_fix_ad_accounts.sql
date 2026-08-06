-- ============================================================================
-- Fix per-store ad account mapping
-- ============================================================================
-- Every store was pointed at a single hardcoded ad account, act_813974741538881,
-- which does not correspond to any ad account in The Sueño Company portfolio.
-- Verified real IDs from Business Settings → Accounts → Ad accounts:
--
--   Downtown Liquor Store   799684473068233
--   Brothers                871838465348844
--   Hideaway Liquor Store   1877479216980622
--   Cobblestone             (no ad account of its own)
--
-- The code no longer falls back to any default: a store with a NULL
-- ad_account_id now fails loudly instead of spending against a guessed account.
-- ============================================================================

UPDATE public.meta_accounts SET ad_account_id = 'act_799684473068233'  WHERE store_id = 'downtown';
UPDATE public.meta_accounts SET ad_account_id = 'act_871838465348844'  WHERE store_id = 'brothers';
UPDATE public.meta_accounts SET ad_account_id = 'act_1877479216980622' WHERE store_id = 'hideaway';

-- ---------------------------------------------------------------------------
-- Cobblestone has no ad account of its own. Per your decision it borrows
-- another store's account.
--
-- NOTE: spend and reporting for Cobblestone will be commingled with whichever
-- store is chosen below — the two cannot be separated afterwards in Ads
-- Manager. Uncomment exactly ONE line.
-- ---------------------------------------------------------------------------
-- UPDATE public.meta_accounts SET ad_account_id = 'act_1877479216980622' WHERE store_id = 'cobblestone';  -- share Hideaway's
-- UPDATE public.meta_accounts SET ad_account_id = 'act_799684473068233'  WHERE store_id = 'cobblestone';  -- share Downtown's
-- UPDATE public.meta_accounts SET ad_account_id = 'act_871838465348844'  WHERE store_id = 'cobblestone';  -- share Brothers'

-- Verify ---------------------------------------------------------------------
-- SELECT store_id, fb_page_id, ad_account_id FROM public.meta_accounts ORDER BY store_id;
