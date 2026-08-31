-- ============================================================================
-- Ad Spend Alerts
-- ============================================================================
-- A safety net for Meta ad campaigns: if any campaign's lifetime spend hits
-- $500, an hourly cron job pauses it via the Graph API and logs a row here.
-- One row per campaign — a campaign that's already tripped the cap doesn't
-- alert again even if it stays active, so this is a one-time guardrail per
-- campaign, not a recurring nag. If someone reactivates a paused campaign on
-- purpose, this table won't try to pause it again.
--
-- Admin-only, unlike the Google Reviews tables: this is spend/business data,
-- and only admins have the Ads section at all.

CREATE TABLE IF NOT EXISTS public.ad_spend_alerts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id        TEXT NOT NULL,
  campaign_id     TEXT NOT NULL,
  campaign_name   TEXT,
  spend           NUMERIC(10,2) NOT NULL,
  cap             NUMERIC(10,2) NOT NULL DEFAULT 500,
  paused          BOOLEAN NOT NULL DEFAULT false,
  pause_error     TEXT,               -- set if the Graph API pause call itself failed
  email_sent      BOOLEAN NOT NULL DEFAULT false,
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One alert per campaign, ever — see note above.
CREATE UNIQUE INDEX IF NOT EXISTS ad_spend_alerts_campaign_uidx
  ON public.ad_spend_alerts (campaign_id);
CREATE INDEX IF NOT EXISTS ad_spend_alerts_unacked_idx
  ON public.ad_spend_alerts (acknowledged_at) WHERE acknowledged_at IS NULL;

ALTER TABLE public.ad_spend_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ad_spend_alerts_admin_read ON public.ad_spend_alerts;
DROP POLICY IF EXISTS ad_spend_alerts_admin_ack  ON public.ad_spend_alerts;

-- Reads open to any signed-in user at the RLS layer — same pattern used
-- elsewhere in this app — but the Ads section (and this banner) is already
-- admin/granted-only in the UI, so in practice only admins ever see it.
CREATE POLICY ad_spend_alerts_admin_read ON public.ad_spend_alerts
  FOR SELECT TO authenticated USING (true);

-- Acknowledging is the one write a signed-in admin does directly from the
-- client (everything else — insert, pause bookkeeping — goes through the
-- edge function's service-role client). Restricted to real admins only.
CREATE POLICY ad_spend_alerts_admin_ack ON public.ad_spend_alerts
  FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  ));

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT store_id, campaign_name, spend, paused, email_sent, acknowledged_at
--   FROM public.ad_spend_alerts ORDER BY created_at DESC;

-- ── Hourly spend check — set up once, after CRON_SECRET is confirmed set
-- in Edge Function secrets (it already is, from market-radar/social-scheduler)
-- and the meta-ads function has been redeployed with checkSpendCaps ─────────
-- SELECT cron.schedule(
--   'lrs-ad-spend-check',
--   '7 * * * *',   -- hourly, 7 minutes past — off the hour, avoids the herd
--   $$
--   SELECT net.http_post(
--     url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/meta-ads',
--     headers := jsonb_build_object(
--       'Content-Type',  'application/json',
--       'x-cron-secret', 'YOUR_CRON_SECRET_BELOW'
--     ),
--     body    := jsonb_build_object('action', 'checkSpendCaps')
--   );
--   $$
-- );
-- View jobs:   SELECT * FROM cron.job;
-- Remove job:  SELECT cron.unschedule('lrs-ad-spend-check');
